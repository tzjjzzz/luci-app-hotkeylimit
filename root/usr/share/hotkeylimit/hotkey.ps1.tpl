# Hotkey Limit - global hotkey for Windows. Uses built-in Windows PowerShell 5.1, nothing to install.
# Run hidden at logon (Win+R -> shell:startup -> new shortcut with this target):
#   powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\path\hotkey.ps1"
$script:Router = 'http://__HOST__'
$Key = '__KEY__'
$script:on = $false

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public class HotkeyWindow : NativeWindow {
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mod, uint vk);
    public event EventHandler Pressed;
    public bool Ok;
    public HotkeyWindow(uint vk) {
        CreateHandle(new CreateParams());
        Ok = RegisterHotKey(Handle, 1, 0x4000, vk); // MOD_NOREPEAT, no modifier keys
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x312 && Pressed != null) Pressed(this, EventArgs.Empty);
        base.WndProc(ref m);
    }
}
'@

function Api([string]$op, [bool]$post) {
    $u = "$($script:Router)/cgi-bin/api?op=$op"
    if ($post) { Invoke-RestMethod -Uri $u -Method Post -ContentType 'application/json' -Body '{}' -TimeoutSec 5 }
    else { Invoke-RestMethod -Uri $u -TimeoutSec 5 }
}
function V($n) { if ($n -lt 0) { 'blocked' } elseif ($n -eq 0) { 'unlimited' } else { "$n KB/s" } }

$script:tray = New-Object System.Windows.Forms.NotifyIcon
$script:tray.Icon = [System.Drawing.SystemIcons]::Shield
$script:tray.Text = 'Hotkey Limit'
$menu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('Exit', $null, { [System.Windows.Forms.Application]::Exit() })
$script:tray.ContextMenuStrip = $menu
$script:tray.Visible = $true

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
$vk = Get-VK $Key
if ($null -eq $vk) {
    [void][System.Windows.Forms.MessageBox]::Show("Unsupported key '$Key'. Use F1-F24, A-Z, 0-9, Pause, ScrollLock, Insert, Home, End, PageUp or PageDown.")
    $script:tray.Dispose()
    exit 1
}
$script:hk = New-Object HotkeyWindow -ArgumentList ([uint32]$vk)
if (-not $script:hk.Ok) {
    [void][System.Windows.Forms.MessageBox]::Show("Cannot register hotkey $Key (already in use by another program?)")
    $script:tray.Dispose()
    exit 1
}
$script:hk.add_Pressed({
    try {
        $r = Api 'toggle' $true
        if ($r.error) {
            $script:tray.ShowBalloonTip(2000, 'Hotkey Limit', [string]$r.error, [System.Windows.Forms.ToolTipIcon]::Error)
        } else {
            $script:on = [bool]$r.on
            $msg = if ($script:on) { "Limit ON   up: $(V $r.up)   down: $(V $r.down)" } else { 'Limit OFF' }
            $script:tray.ShowBalloonTip(1500, 'Hotkey Limit', $msg, [System.Windows.Forms.ToolTipIcon]::Info)
        }
    } catch {
        $script:tray.ShowBalloonTip(2000, 'Hotkey Limit', 'Cannot reach router', [System.Windows.Forms.ToolTipIcon]::Error)
    }
})

# heartbeat while a limit is on; the router removes the limit if heartbeats stop
$t = New-Object System.Windows.Forms.Timer
$t.Interval = 5000
$t.add_Tick({
    if ($script:on) { try { $r = Api 'beat' $false; $script:on = [bool]$r.on } catch { } }
})
$t.Start()

[System.Windows.Forms.Application]::Run()
$script:tray.Visible = $false
$script:tray.Dispose()
