# Hotkey Limit - global hotkeys for Windows. Uses built-in Windows PowerShell 5.1, nothing to install.
# Limits (device / upload / download) and THIS PC's hotkeys are set on the router web page (open it from this PC).
# This script listens for those hotkeys and toggles the limit. Page changes are picked up automatically.
# It uses a low-level keyboard hook, so it still works when another program already uses the same hotkey.
# Run hidden at logon (Win+R -> shell:startup -> new shortcut with this target):
#   powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\path\hotkey.ps1"

# Only one instance at a time (two instances would toggle twice and cancel each other out).
$script:once = New-Object System.Threading.Mutex($false, 'Local\HotkeyLimitPS')
if (-not $script:once.WaitOne(0)) { exit }
# Hide this script's own console window (no extra process is started).
Add-Type -Name Win -Namespace Native -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);'
[void][Native.Win]::ShowWindow([Native.Win]::GetConsoleWindow(), 0)

# ============================== CONFIG ==============================
$script:Router = 'http://__HOST__'
# $false = a hotkey still reaches other programs too (both react).  $true = this script swallows the key (exclusive).
$script:Swallow = $false

# --- Optional: timed keys ---------------------------------------------------------------------
# Press the Key  -> the limit turns ON and turns OFF by itself after Seconds.
# Press it again before the time is up -> OFF immediately.
# Target = the WEB hotkey (set on the router page) of the device to control, e.g. 'F9'.
#          Leave '' when only one web hotkey is set on this PC; with several web hotkeys it must be filled in.
# The web hotkey itself keeps working as a normal on/off toggle.
# Example:  $script:Timed = @( @{ Key = 'G'; Target = 'F'; Seconds = 5 } )
$script:Timed = @()

# --- Optional: cancel keys --------------------------------------------------------------------
# Pressing any of these turns the limit OFF (it never turns it ON). The key/button still works normally.
# Mouse: LButton RButton MButton XButton1 XButton2.  Keyboard: F1-F24, A-Z, 0-9, Pause, ScrollLock, Insert, Home, End, PageUp, PageDown
# Example:  $script:CancelKeys = @('LButton', 'RButton')
$script:CancelKeys = @()
# 'all'   = cancel every limit that is currently ON for the devices bound to this PC's web hotkeys
# 'timed' = only cancel limits started by a timed key
$script:CancelScope = 'all'
# ====================================================================

$script:alive = $false
$script:map = @{}
$script:st = @{}
$script:last = @()
$script:sig = ''
$script:deadlines = @{}
$script:pending = New-Object System.Collections.ArrayList

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net.Http
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class HotkeyWindow : NativeWindow {
    delegate IntPtr HookProc(int code, IntPtr w, IntPtr l);
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetWindowsHookEx(int id, HookProc cb, IntPtr mod, uint tid);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int code, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);
    public event EventHandler Pressed;
    public int LastId;
    public bool Swallow;
    public bool HookOk;
    public bool CancelArmed;   // ids 1000..1999 (cancel keys / mouse) only fire while a limit may be active
    public int MouseMask;      // 1=left 2=right 4=middle 8=X1 16=X2
    Dictionary<uint, int> map = new Dictionary<uint, int>();
    Dictionary<uint, bool> pass = new Dictionary<uint, bool>();
    Dictionary<uint, int> lastDown = new Dictionary<uint, int>();
    HookProc proc, mproc;
    IntPtr hook = IntPtr.Zero, mhook = IntPtr.Zero;
    public HotkeyWindow() {
        CreateHandle(new CreateParams());
        proc = Callback;
        mproc = MouseCallback;
        hook = SetWindowsHookEx(13, proc, GetModuleHandle(Process.GetCurrentProcess().MainModule.ModuleName), 0);
        HookOk = hook != IntPtr.Zero;
    }
    // hook callbacks only filter and post a message; slow work must never happen inside a hook
    IntPtr Callback(int code, IntPtr w, IntPtr l) {
        if (code >= 0) {
            uint vk = (uint)Marshal.ReadInt32(l);
            int id;
            if (map.TryGetValue(vk, out id)) {
                bool cancel = id >= 1000 && id < 2000;
                if (!(cancel && !CancelArmed)) {
                    int msg = w.ToInt32();
                    if (msg == 0x100 || msg == 0x104) {
                        int t = Environment.TickCount, prev;
                        bool repeat = lastDown.TryGetValue(vk, out prev) && unchecked(t - prev) < 1500;
                        lastDown[vk] = t;
                        if (!repeat) PostMessage(Handle, 0x8001, (IntPtr)id, IntPtr.Zero);
                    } else {
                        lastDown.Remove(vk);
                    }
                    if (Swallow && !pass.ContainsKey(vk)) return (IntPtr)1;
                }
            }
        }
        return CallNextHookEx(hook, code, w, l);
    }
    // mouse buttons are never swallowed
    IntPtr MouseCallback(int code, IntPtr w, IntPtr l) {
        if (code >= 0 && CancelArmed && MouseMask != 0) {
            int msg = w.ToInt32();
            int bit = 0;
            if (msg == 0x201) bit = 1;
            else if (msg == 0x204) bit = 2;
            else if (msg == 0x207) bit = 4;
            else if (msg == 0x20B) {
                int x = (Marshal.ReadInt32(l, 8) >> 16) & 0xFFFF;
                bit = x == 1 ? 8 : (x == 2 ? 16 : 0);
            }
            if ((bit & MouseMask) != 0) PostMessage(Handle, 0x8001, (IntPtr)1900, IntPtr.Zero);
        }
        return CallNextHookEx(mhook, code, w, l);
    }
    public bool Register(int id, uint vk) { return Register(id, vk, false); }
    public bool Register(int id, uint vk, bool passThrough) {
        map[vk] = id;
        if (passThrough) pass[vk] = true;
        return HookOk;
    }
    public void Unregister(int id) {
        List<uint> rm = new List<uint>();
        foreach (KeyValuePair<uint, int> kv in map) if (kv.Value == id) rm.Add(kv.Key);
        foreach (uint k in rm) { map.Remove(k); pass.Remove(k); }
    }
    public bool SetMouse(int mask) {
        MouseMask = mask;
        if (mask != 0 && mhook == IntPtr.Zero)
            mhook = SetWindowsHookEx(14, mproc, GetModuleHandle(Process.GetCurrentProcess().MainModule.ModuleName), 0);
        return mask == 0 || mhook != IntPtr.Zero;
    }
    public void Close() {
        if (hook != IntPtr.Zero) { UnhookWindowsHookEx(hook); hook = IntPtr.Zero; }
        if (mhook != IntPtr.Zero) { UnhookWindowsHookEx(mhook); mhook = IntPtr.Zero; }
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x8001) { LastId = m.WParam.ToInt32(); if (Pressed != null) Pressed(this, EventArgs.Empty); }
        base.WndProc(ref m);
    }
}

// small overlay shown instantly; each new message replaces the previous one (no queue, no Windows toast)
public class Toast : Form {
    Label lbl = new Label();
    System.Windows.Forms.Timer tm = new System.Windows.Forms.Timer();
    public Toast() {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        Opacity = 0.92;
        lbl.AutoSize = true;
        lbl.ForeColor = Color.White;
        lbl.Font = new Font("Segoe UI", 12f);
        lbl.Padding = new Padding(14, 10, 14, 10);
        lbl.Location = new Point(0, 0);
        Controls.Add(lbl);
        tm.Interval = 1500;
        tm.Tick += delegate { tm.Stop(); Hide(); };
    }
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get { CreateParams p = base.CreateParams; p.ExStyle |= 0x08000088; return p; } // NOACTIVATE | TOOLWINDOW | TOPMOST
    }
    public void Say(string text, bool bad) {
        BackColor = bad ? Color.FromArgb(150, 40, 40) : Color.FromArgb(30, 30, 30);
        lbl.BackColor = BackColor;
        lbl.Text = text;
        ClientSize = lbl.GetPreferredSize(Size.Empty);
        Rectangle wa = Screen.PrimaryScreen.WorkingArea;
        Location = new Point(wa.Right - Width - 20, wa.Bottom - Height - 20);
        if (!Visible) Show();
        tm.Stop();
        tm.Start();
    }
}
'@

# ---------- networking: always asynchronous, so the keyboard/mouse hooks are never blocked ----------
$handler = New-Object System.Net.Http.HttpClientHandler
$handler.UseProxy = $false
$script:http = New-Object System.Net.Http.HttpClient($handler)
$script:http.Timeout = [TimeSpan]::FromSeconds(3)
$script:http.DefaultRequestHeaders.ConnectionClose = $true

$script:netTimer = New-Object System.Windows.Forms.Timer
$script:netTimer.Interval = 25
$script:netTimer.add_Tick({ Pump-Net })

function Send-Api([string]$op, [bool]$post, [string]$body, [string]$onOk, $ctx, [string]$onFail) {
    $u = "$($script:Router)/cgi-bin/api?op=$op"
    if ($post) {
        $c = New-Object System.Net.Http.StringContent($body, [System.Text.Encoding]::UTF8, 'application/json')
        $t = $script:http.PostAsync($u, $c)
    } else {
        $t = $script:http.GetAsync($u)
    }
    [void]$script:pending.Add(@{ t = $t; ok = $onOk; ctx = $ctx; fail = $onFail })
    $script:netTimer.Start()
}
function Pump-Net {
    $done = @($script:pending | Where-Object { $_.t.IsCompleted })
    foreach ($p in $done) { $script:pending.Remove($p) }
    foreach ($p in $done) {
        $r = $null
        try {
            if ($p.t.IsFaulted -or $p.t.IsCanceled) { throw 'net' }
            $s = $p.t.Result.Content.ReadAsStringAsync().Result
            $r = $s | ConvertFrom-Json
        } catch {
            if ($p.fail) { & $p.fail $p.ctx }
            continue
        }
        if ($p.ok) { & $p.ok $r $p.ctx }
    }
    if ($script:pending.Count -eq 0) { $script:netTimer.Stop() }
}

# ---------- helpers ----------
function V($n) { if ($n -lt 0) { 'blocked' } elseif ($n -eq 0) { 'unlimited' } else { "$n KB/s" } }
function Notify([string]$msg, [bool]$bad = $false) { $script:toast.Say($msg, $bad) }
function Get-VK([string]$k) {
    $k = $k.Trim().ToUpper()
    if ($k -match '^F(\d{1,2})$') {
        $n = [int]$Matches[1]
        if ($n -ge 1 -and $n -le 24) { return [uint32](0x6F + $n) }
        return $null
    }
    if ($k -match '^[A-Z0-9]$') { return [uint32][char]$k }
    switch ($k) {
        'PAUSE'      { return [uint32]0x13 }
        'SCROLLLOCK' { return [uint32]0x91 }
        'INSERT'     { return [uint32]0x2D }
        'HOME'       { return [uint32]0x24 }
        'END'        { return [uint32]0x23 }
        'PAGEUP'     { return [uint32]0x21 }
        'PAGEDOWN'   { return [uint32]0x22 }
    }
    return $null
}
function Update-Armed {
    if ($script:CancelScope -eq 'timed') { $a = ($script:deadlines.Count -gt 0) }
    else { $a = ($script:st.Values -contains $true) }
    $script:hkw.CancelArmed = [bool]$a
}
function Update-State($l) {
    $script:last = @($l)
    $script:st = @{}
    foreach ($d in $l) { $script:st[[string]$d.ip] = [bool]$d.on }
    $script:alive = [bool](@($l) | Where-Object { $_.on })
    if ($script:alive -and $script:t.Interval -gt 5000) { $script:t.Interval = 5000 }
    Update-Armed
}
# (re)register this PC's web hotkeys whenever the mapping on the router changes
function Sync($list) {
    $want = @($list | Where-Object { $_.key -and $_.key -ne '-' })
    $sig = ($want | ForEach-Object { "$($_.ip)=$($_.key)" }) -join ','
    if ($sig -eq $script:sig) { return }
    foreach ($id in @($script:map.Keys)) { $script:hkw.Unregister([int]$id) }
    $script:map = @{}
    $failed = @()
    $id = 1
    foreach ($d in $want) {
        $vk = Get-VK $d.key
        if ($null -ne $vk -and $script:hkw.Register($id, [uint32]$vk)) { $script:map[$id] = $d.ip }
        else { $failed += [string]$d.key }
        $id++
    }
    $script:sig = $sig
    if ($failed.Count -gt 0) { Notify ("Unsupported hotkey: " + ($failed -join ', ') + " (use F1-F24, A-Z, 0-9, Pause, ScrollLock, Insert, Home, End, PageUp, PageDown)") $true }
}
# the web hotkey (e.g. 'F') a timed key points at -> device ip
function Resolve-Target([string]$t) {
    $bound = @($script:last | Where-Object { $_.key -and $_.key -ne '-' })
    if ($t) {
        $m = $bound | Where-Object { $_.key -ieq $t } | Select-Object -First 1
        if ($m) { return [string]$m.ip }
        Notify "No device has web hotkey '$t' on this PC" $true
        return $null
    }
    if ($bound.Count -eq 1) { return [string]$bound[0].ip }
    if ($bound.Count -eq 0) { Notify 'No web hotkey is set on this PC' $true; return $null }
    Notify 'Several web hotkeys exist: set Target for the timed key' $true
    return $null
}

# ---------- reply handlers (called from Pump-Net on the UI thread) ----------
function H-Fail($ctx) { Notify 'Cannot reach router' $true }
function H-Quiet($ctx) { }
function H-Tick($r, $ctx) { $l = @($r.list); Update-State $l; Sync $l }
function H-Start($r, $ctx) { $l = @($r.list); Update-State $l; Sync $l; Notify 'Hotkey Limit running' }
function H-StartFail($ctx) { Notify 'Router not reachable yet, will keep trying' $true }
function H-Result($r, $ctx) {
    $ip = [string]$ctx.ip
    if ($r.error) { $script:deadlines.Remove($ip); Update-Armed; Notify ([string]$r.error) $true; return }
    $l = @($r.list)
    Update-State $l
    $d = $l | Where-Object { $_.ip -eq $ip } | Select-Object -First 1
    if ($d -and $d.on) {
        $extra = ''
        if ($script:deadlines.ContainsKey($ip)) {
            $left = [int][math]::Ceiling(($script:deadlines[$ip] - (Get-Date)).TotalSeconds)
            if ($left -gt 0) { $extra = "   (auto OFF in ${left}s)" }
        }
        Notify "$ip  ON   up: $(V $d.up)   down: $(V $d.down)$extra"
    } else {
        Notify "$ip  OFF"
    }
}

# ---------- actions ----------
function Do-Toggle([string]$ip) {
    $script:deadlines.Remove($ip)      # manual use takes over from a running timer
    if ($script:st[$ip]) { Notify "$ip  OFF ..." } else { Notify "$ip  ON ..." }
    Send-Api 'toggle&src=ps' $true "{`"ip`":`"$ip`"}" 'H-Result' @{ ip = $ip } 'H-Fail'
}
function Do-On([string]$ip, [double]$secs) {
    Notify "$ip  ON ..."
    if ($secs -gt 0) {
        $script:deadlines[$ip] = (Get-Date).AddSeconds($secs)   # counted from the key press
        $script:dlTimer.Start()
        Update-Armed
    }
    Send-Api 'on&src=ps' $true "{`"ip`":`"$ip`"}" 'H-Result' @{ ip = $ip } 'H-Fail'
}
function Do-Off([string]$ip, [string]$why) {
    $script:deadlines.Remove($ip)
    if ($why) { Notify "$ip  OFF ($why) ..." } else { Notify "$ip  OFF ..." }
    Send-Api 'off&src=ps' $true "{`"ip`":`"$ip`"}" 'H-Result' @{ ip = $ip } 'H-Fail'
}
function Do-Timed([int]$i) {
    $e = @($script:Timed)[$i]
    $ip = Resolve-Target ([string]$e.Target)
    if (-not $ip) { return }
    if ($script:deadlines.ContainsKey($ip)) { Do-Off $ip 'timed key' }   # pressed again inside the time window
    else { Do-On $ip ([double]$e.Seconds) }
}
function Do-Cancel {
    if ($script:CancelScope -eq 'timed') {
        $ips = @($script:deadlines.Keys)
    } else {
        $bound = @($script:last | Where-Object { $_.key -and $_.key -ne '-' } | ForEach-Object { [string]$_.ip })
        $ips = @($bound | Where-Object { $script:st[$_] })
    }
    foreach ($ip in $ips) { Do-Off $ip 'cancel key' }
}

# ---------- UI objects ----------
$script:tray = New-Object System.Windows.Forms.NotifyIcon
$script:tray.Icon = [System.Drawing.SystemIcons]::Shield
$script:tray.Text = 'Hotkey Limit (right-click: Exit)'
$menu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('Exit', $null, { [System.Windows.Forms.Application]::Exit() })
$script:tray.ContextMenuStrip = $menu
$script:tray.Visible = $true
$script:toast = New-Object Toast

# polls the router: refreshes the hotkey mapping; sends heartbeats while any limit is on
# (the router only counts them for limits this script turned on)
$script:t = New-Object System.Windows.Forms.Timer
$script:t.Interval = 5000
$script:t.add_Tick({
    $op = if ($script:alive) { 'beat&src=ps' } else { 'list' }
    Send-Api $op $false '' 'H-Tick' @{} 'H-Quiet'
    $script:t.Interval = if ($script:alive) { 5000 } else { 15000 }
})
# ends timed limits
$script:dlTimer = New-Object System.Windows.Forms.Timer
$script:dlTimer.Interval = 100
$script:dlTimer.add_Tick({
    $now = Get-Date
    foreach ($ip in @($script:deadlines.Keys)) {
        if ($now -ge $script:deadlines[$ip]) { Do-Off $ip 'time up' }
    }
    if ($script:deadlines.Count -eq 0) { $script:dlTimer.Stop() }
    Update-Armed
})

$script:hkw = New-Object HotkeyWindow
$script:hkw.Swallow = $script:Swallow
if (-not $script:hkw.HookOk) {
    [void][System.Windows.Forms.MessageBox]::Show('Cannot install keyboard hook (blocked by security software?)')
    $script:tray.Dispose()
    exit 1
}
$script:hkw.add_Pressed({
    $id = [int]$script:hkw.LastId
    if ($id -ge 2000) { Do-Timed ($id - 2000) }
    elseif ($id -ge 1000) { Do-Cancel }
    else {
        $ip = $script:map[$id]
        if ($ip) { Do-Toggle ([string]$ip) }
    }
})

# timed keys (ids 2000+) and cancel keys (ids 1000+, never swallowed)
$bad = @()
$i = 0
foreach ($e in @($script:Timed)) {
    $vk = Get-VK ([string]$e.Key)
    if ($null -eq $vk -or -not ($e.Seconds -gt 0)) { $bad += "timed:$($e.Key)" }
    else { [void]$script:hkw.Register(2000 + $i, [uint32]$vk) }
    $i++
}
$mask = 0
$k = 0
foreach ($n in @($script:CancelKeys)) {
    switch (([string]$n).ToUpper()) {
        'LBUTTON'  { $mask = $mask -bor 1 }
        'RBUTTON'  { $mask = $mask -bor 2 }
        'MBUTTON'  { $mask = $mask -bor 4 }
        'XBUTTON1' { $mask = $mask -bor 8 }
        'XBUTTON2' { $mask = $mask -bor 16 }
        default {
            $vk = Get-VK ([string]$n)
            if ($null -eq $vk) { $bad += "cancel:$n" }
            else { [void]$script:hkw.Register(1000 + $k, [uint32]$vk, $true); $k++ }
        }
    }
}
if (-not $script:hkw.SetMouse($mask)) { $bad += 'mouse hook' }
Update-Armed

Send-Api 'list' $false '' 'H-Start' @{} 'H-StartFail'
if ($bad.Count -gt 0) { Notify ("Invalid config: " + ($bad -join ', ')) $true }
$script:t.Start()

[System.Windows.Forms.Application]::Run()
$script:hkw.Close()
$script:tray.Visible = $false
$script:tray.Dispose()
