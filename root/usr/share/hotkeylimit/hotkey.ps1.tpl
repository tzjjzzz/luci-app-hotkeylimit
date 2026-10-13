# Hotkey Limit - global hotkeys for Windows. Uses built-in Windows PowerShell 5.1, nothing to install.
# Limits (device / upload / download) and THIS PC's hotkeys are set on the router web page (open it from this PC).
# This script only listens for those hotkeys and toggles the limit. Page changes are picked up automatically.
# It uses a low-level keyboard hook, so it still works when another program already uses the same hotkey.
# Run hidden at logon (Win+R -> shell:startup -> new shortcut with this target):
#   powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\path\hotkey.ps1"
param([switch]$Child)
# Relaunch once in a hidden window so no console window / taskbar button is ever shown (tray icon only).
if (-not $Child) {
    Start-Process -FilePath powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'), '-Child')
    exit
}
# Only one instance at a time (two instances would toggle twice and cancel each other out).
$script:once = New-Object System.Threading.Mutex($false, 'Local\HotkeyLimitPS')
if (-not $script:once.WaitOne(0)) { exit }
# Fallback: also hide the console window if it exists (e.g. started with -Child by hand).
Add-Type -Name Win -Namespace Native -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);'
[void][Native.Win]::ShowWindow([Native.Win]::GetConsoleWindow(), 0)

$script:Router = 'http://__HOST__'
# $false = the key still reaches other programs too (both react).  $true = this script swallows the key (exclusive).
$script:Swallow = $false
$script:alive = $false
$script:map = @{}
$script:st = @{}
$script:sig = ''

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
    Dictionary<uint, int> map = new Dictionary<uint, int>();
    Dictionary<uint, int> lastDown = new Dictionary<uint, int>();
    HookProc proc;
    IntPtr hook = IntPtr.Zero;
    public HotkeyWindow() {
        CreateHandle(new CreateParams());
        proc = Callback;
        hook = SetWindowsHookEx(13, proc, GetModuleHandle(Process.GetCurrentProcess().MainModule.ModuleName), 0);
        HookOk = hook != IntPtr.Zero;
    }
    // runs inside the hook: only filter and post a message, never do slow work here
    IntPtr Callback(int code, IntPtr w, IntPtr l) {
        if (code >= 0) {
            uint vk = (uint)Marshal.ReadInt32(l);
            int id;
            if (map.TryGetValue(vk, out id)) {
                int msg = w.ToInt32();
                if (msg == 0x100 || msg == 0x104) {
                    int t = Environment.TickCount, prev;
                    bool repeat = lastDown.TryGetValue(vk, out prev) && unchecked(t - prev) < 1500;
                    lastDown[vk] = t;
                    if (!repeat) PostMessage(Handle, 0x8001, (IntPtr)id, IntPtr.Zero);
                } else {
                    lastDown.Remove(vk);
                }
                if (Swallow) return (IntPtr)1;
            }
        }
        return CallNextHookEx(hook, code, w, l);
    }
    public bool Register(int id, uint vk) { map[vk] = id; return HookOk; }
    public void Unregister(int id) {
        List<uint> rm = new List<uint>();
        foreach (KeyValuePair<uint, int> kv in map) if (kv.Value == id) rm.Add(kv.Key);
        foreach (uint k in rm) map.Remove(k);
    }
    public void Close() { if (hook != IntPtr.Zero) { UnhookWindowsHookEx(hook); hook = IntPtr.Zero; } }
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

# one reusable HTTP client: no proxy auto-detection, short timeout (Invoke-RestMethod was the main source of delay)
$handler = New-Object System.Net.Http.HttpClientHandler
$handler.UseProxy = $false
$script:http = New-Object System.Net.Http.HttpClient($handler)
$script:http.Timeout = [TimeSpan]::FromSeconds(3)
$script:http.DefaultRequestHeaders.ConnectionClose = $true

function Api([string]$op, [bool]$post, [string]$body = '{}') {
    $u = "$($script:Router)/cgi-bin/api?op=$op"
    if ($post) {
        $c = New-Object System.Net.Http.StringContent($body, [System.Text.Encoding]::UTF8, 'application/json')
        $s = $script:http.PostAsync($u, $c).Result.Content.ReadAsStringAsync().Result
    } else {
        $s = $script:http.GetStringAsync($u).Result
    }
    $s | ConvertFrom-Json
}
function V($n) { if ($n -lt 0) { 'blocked' } elseif ($n -eq 0) { 'unlimited' } else { "$n KB/s" } }
function Notify([string]$msg, [bool]$bad = $false) { $script:toast.Say($msg, $bad) }
function Update-State($l) {
    $script:st = @{}
    foreach ($d in $l) { $script:st[[string]$d.ip] = [bool]$d.on }
}
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

# (re)register hotkeys whenever this PC's key mapping on the router changes
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

$script:tray = New-Object System.Windows.Forms.NotifyIcon
$script:tray.Icon = [System.Drawing.SystemIcons]::Shield
$script:tray.Text = 'Hotkey Limit (right-click: Exit)'
$menu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('Exit', $null, { [System.Windows.Forms.Application]::Exit() })
$script:tray.ContextMenuStrip = $menu
$script:tray.Visible = $true
$script:toast = New-Object Toast

$script:hkw = New-Object HotkeyWindow
$script:hkw.Swallow = $script:Swallow
if (-not $script:hkw.HookOk) {
    [void][System.Windows.Forms.MessageBox]::Show('Cannot install keyboard hook (blocked by security software?)')
    $script:tray.Dispose()
    exit 1
}
$script:hkw.add_Pressed({
    $ip = $script:map[[int]$script:hkw.LastId]
    if (-not $ip) { return }
    # instant feedback from the last known state, corrected below when the router answers
    if ($script:st[$ip]) { Notify "$ip  OFF ..." } else { Notify "$ip  ON ..." }
    try {
        $r = Api 'toggle' $true "{`"ip`":`"$ip`"}"
        if ($r.error) { Notify ([string]$r.error) $true; return }
        $l = @($r.list)
        Update-State $l
        $script:alive = [bool]($l | Where-Object { $_.on })
        $d = $l | Where-Object { $_.ip -eq $ip } | Select-Object -First 1
        if ($d.on) { Notify "$ip  ON   up: $(V $d.up)   down: $(V $d.down)" } else { Notify "$ip  OFF" }
    } catch {
        Notify 'Cannot reach router' $true
    }
})

# poll the router: refresh hotkey mapping; send heartbeats only while a limit started from here is active
$script:t = New-Object System.Windows.Forms.Timer
$script:t.Interval = 5000
$script:t.add_Tick({
    try {
        $op = if ($script:alive) { 'beat' } else { 'list' }
        $r = Api $op $false
        $l = @($r.list)
        Update-State $l
        if ($script:alive) { $script:alive = [bool]($l | Where-Object { $_.on }) }
        Sync $l
    } catch { }
    $script:t.Interval = if ($script:alive) { 5000 } else { 15000 }
})
try {
    $r0 = Api 'list' $false
    Update-State @($r0.list)
    Sync @($r0.list)
    Notify 'Hotkey Limit running'
} catch { Notify 'Router not reachable yet, will keep trying' $true }
$script:t.Start()

[System.Windows.Forms.Application]::Run()
$script:hkw.Close()
$script:tray.Visible = $false
$script:tray.Dispose()
