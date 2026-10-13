# Hotkey Limit - global hotkeys for Windows. Uses built-in Windows PowerShell 5.1, nothing to install.
# Limits (device / upload / download) and each device's hotkey are set on the router web page.
# This script only listens for those hotkeys and toggles the limit. Changes made on the page are picked up automatically.
# It uses a low-level keyboard hook, so it still works when another program has already registered the same hotkey.
# Run hidden at logon (Win+R -> shell:startup -> new shortcut with this target):
#   powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\path\hotkey.ps1"
$script:Router = 'http://__HOST__'
# $false = the key still reaches other programs too (both react).  $true = this script swallows the key (exclusive).
$script:Swallow = $false
$script:alive = $false
$script:map = @{}
$script:sig = ''

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
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
'@

function Api([string]$op, [bool]$post, [string]$body = '{}') {
    $u = "$($script:Router)/cgi-bin/api?op=$op"
    if ($post) { Invoke-RestMethod -Uri $u -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 5 }
    else { Invoke-RestMethod -Uri $u -TimeoutSec 5 }
}
function V($n) { if ($n -lt 0) { 'blocked' } elseif ($n -eq 0) { 'unlimited' } else { "$n KB/s" } }
function Notify([string]$msg, [string]$icon = 'Info') {
    $script:tray.ShowBalloonTip(2000, 'Hotkey Limit', $msg, [System.Windows.Forms.ToolTipIcon]$icon)
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

# (re)register hotkeys whenever the key mapping on the router changes
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
    if ($failed.Count -gt 0) { Notify ("Unsupported hotkey: " + ($failed -join ', ') + " (use F1-F24, A-Z, 0-9, Pause, ScrollLock, Insert, Home, End, PageUp, PageDown)") 'Error' }
}

$script:tray = New-Object System.Windows.Forms.NotifyIcon
$script:tray.Icon = [System.Drawing.SystemIcons]::Shield
$script:tray.Text = 'Hotkey Limit'
$menu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('Exit', $null, { [System.Windows.Forms.Application]::Exit() })
$script:tray.ContextMenuStrip = $menu
$script:tray.Visible = $true

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
    try {
        $r = Api 'toggle' $true "{`"ip`":`"$ip`"}"
        if ($r.error) { Notify ([string]$r.error) 'Error'; return }
        $l = @($r.list)
        $script:alive = [bool]($l | Where-Object { $_.on })
        $d = $l | Where-Object { $_.ip -eq $ip } | Select-Object -First 1
        if ($d.on) { Notify "$ip  limit ON   up: $(V $d.up)   down: $(V $d.down)" }
        else { Notify "$ip  limit OFF" }
    } catch {
        Notify 'Cannot reach router' 'Error'
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
        if ($script:alive) { $script:alive = [bool]($l | Where-Object { $_.on }) }
        Sync $l
    } catch { }
    $script:t.Interval = if ($script:alive) { 5000 } else { 15000 }
})
try { Sync @((Api 'list' $false).list) } catch { }
$script:t.Start()

[System.Windows.Forms.Application]::Run()
$script:hkw.Close()
$script:tray.Visible = $false
$script:tray.Dispose()
