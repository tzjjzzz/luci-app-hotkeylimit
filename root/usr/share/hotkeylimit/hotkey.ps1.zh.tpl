# Hotkey Limit - Windows 全局热键脚本。使用系统自带的 Windows PowerShell 5.1，无需安装任何软件。
# 限速的设备、上传、下载值，以及本机的热键，都在路由器网页上设置（请在本机上打开该网页）。
# 本脚本负责监听这些热键并开关限速；网页上的修改会自动同步到脚本。
# 使用底层键盘钩子，所以即使其他程序已经占用了同一个热键，这里仍然能收到按键。
# 开机自动隐藏运行：按 Win+R 输入 shell:startup，新建快捷方式，目标填写：
#   powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\path\hotkey.ps1"

# 只允许运行一个实例（两个实例会各切换一次，互相抵消）。
$script:once = New-Object System.Threading.Mutex($false, 'Local\HotkeyLimitPS')
if (-not $script:once.WaitOne(0)) { exit }
# 隐藏本脚本自己的控制台窗口（不会额外启动新进程）。
Add-Type -Name Win -Namespace Native -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);'
[void][Native.Win]::ShowWindow([Native.Win]::GetConsoleWindow(), 0)

# ============================== 配置区 ==============================
$script:Router = 'http://__HOST__'
# $false = 热键同时也会传给其他程序（两边都会响应）；$true = 本脚本吞掉该按键（独占）。
$script:Swallow = $false

# --- 可选：定时键 -----------------------------------------------------------------------------
# 按下 Key  -> 开启限速，经过 Seconds 秒后自动关闭。
# 在时间到之前再按一次 -> 立即关闭。
# Target = 要控制的设备在网页上设置的热键，例如 'F9'。
#          这台电脑在网页上只设了一个热键时可以留空 ''；有多个热键时必须填写。
# Cooldown（可选）= 自动关闭之后的冷却秒数，冷却期间这个定时键不能再次开启限速。
#          整个冷却期间屏幕上会一直显示红色倒计时。没有设置 Cooldown 的定时键没有冷却。
# 网页上设的热键本身仍然是普通的开关键，不受冷却影响。
# 示例：  $script:Timed = @( @{ Key = 'G'; Target = 'F'; Seconds = 5; Cooldown = 10 } )
$script:Timed = @()
# CooldownAlways（总是冷却）：
#   $false（默认）= 只有“时间到自动关闭”才会进入冷却。
#   $true         = 无论定时限速怎样结束都会进入冷却：自动关闭、再按一次定时键、
#                   按取消键（鼠标等）、按网页热键关闭，或者在网页 / 其他设备上被关闭。
$script:CooldownAlways = $false

# --- 可选：取消键 -----------------------------------------------------------------------------
# 按下其中任意一个都会关闭限速（只会关闭，不会开启）；该按键本身仍然正常工作。
# 鼠标：LButton RButton MButton XButton1 XButton2。键盘：F1-F24、A-Z、0-9、Pause、ScrollLock、Insert、Home、End、PageUp、PageDown
# 示例：  $script:CancelKeys = @('LButton', 'RButton')
$script:CancelKeys = @()
# 'all'   = 取消这台电脑已绑定网页热键的所有设备中，当前正在进行的全部限速（包括普通热键开启的）
# 'timed' = 只取消由定时键开启的限速
$script:CancelScope = 'all'
# ===========================================================================

$script:alive = $false
$script:map = @{}
$script:st = @{}
$script:last = @()
$script:sig = ''
$script:deadlines = @{}     # ip -> 定时限速的结束时间
$script:cool = @{}          # ip -> 冷却的结束时间
$script:coolFor = @{}       # ip -> 开启它的定时键所设的冷却秒数
$script:stickyIp = $null    # 屏幕上正在显示倒计时的设备
$script:flashUntil = [datetime]::MinValue
$script:timedOk = @{}       # ip -> 路由器确认定时限速已开启的时间（用来发现它被别处关闭）
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
    public bool CancelArmed;   // 编号 1000..1999（取消键 / 鼠标）只在可能有限速时才触发
    public int MouseMask;      // 1=左键 2=右键 4=中键 8=侧键1 16=侧键2
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
    // 钩子回调里只做过滤并投递消息，绝不能在钩子里做耗时操作
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
    // 鼠标按键永远不会被吞掉
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

// 屏幕底部居中的小提示框；新消息直接替换旧消息（不排队，不使用 Windows 系统通知）
// kind：0=绿色（开启），1=红色（关闭 / 错误），2=白色（提示）。sticky=一直显示，直到调用 Clear()。
public class Toast : Form {
    Label lbl = new Label();
    System.Windows.Forms.Timer tm = new System.Windows.Forms.Timer();
    public Toast() {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        Opacity = 0.92;
        BackColor = Color.FromArgb(30, 30, 30);
        lbl.BackColor = BackColor;
        lbl.AutoSize = true;
        lbl.Font = new Font("Consolas", 14f, FontStyle.Bold);
        lbl.Padding = new Padding(18, 10, 18, 10);
        lbl.Location = new Point(0, 0);
        Controls.Add(lbl);
        tm.Interval = 1500;
        tm.Tick += delegate { tm.Stop(); Hide(); };
    }
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get { CreateParams p = base.CreateParams; p.ExStyle |= 0x08000088; return p; } // 不抢焦点 | 工具窗口（不在任务栏）| 置顶
    }
    public void Say(string text, int kind, bool sticky) {
        lbl.ForeColor = kind == 0 ? Color.FromArgb(90, 230, 110) : (kind == 1 ? Color.FromArgb(255, 95, 95) : Color.White);
        lbl.Text = text;
        ClientSize = lbl.GetPreferredSize(Size.Empty);
        Rectangle wa = Screen.PrimaryScreen.WorkingArea;
        Location = new Point(wa.Left + (wa.Width - Width) / 2, wa.Bottom - Height - 80);
        if (!Visible) Show();
        tm.Stop();
        if (!sticky) tm.Start();
    }
    public void Clear() { tm.Stop(); Hide(); }
}
'@

# ---------- 网络：全部异步，这样键盘 / 鼠标钩子永远不会被卡住 ----------
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

# ---------- 辅助函数 ----------
function V($n) { if ($n -lt 0) { 'blocked' } elseif ($n -eq 0) { 'unlimited' } else { "$n KB/s" } }
# kind：'on'（绿）| 'off'（红）| 'err'（红）| 'info'（白）。显示约 1.5 秒，之后正在进行的倒计时会重新出现。
function Notify([string]$msg, [string]$kind = 'info') {
    if ($kind -eq 'on') { $c = 0 } elseif ($kind -eq 'off' -or $kind -eq 'err') { $c = 1 } else { $c = 2 }
    $script:flashUntil = (Get-Date).AddMilliseconds(1450)
    $script:toast.Say($msg, $c, $false)
}
function Fmt([double]$sec) {
    if ($sec -lt 0) { $sec = 0 }
    return $sec.ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture)
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
function Update-Armed {
    if ($script:CancelScope -eq 'timed') { $a = ($script:deadlines.Count -gt 0) }
    else { $a = ($script:st.Values -contains $true) }
    $script:hkw.CancelArmed = [bool]$a
}
function Update-State($l) {
    $script:last = @($l)
    $script:st = @{}
    foreach ($d in $l) { $script:st[[string]$d.ip] = [bool]$d.on }
    # 定时限速之前已确认开启、现在却显示关闭，说明它被别处关闭了（网页、手机等）
    # （留 3 秒保护，避免把还在路上的旧回复误判成被关闭）
    foreach ($tip in @($script:timedOk.Keys)) {
        if (-not $script:deadlines.ContainsKey($tip)) { $script:timedOk.Remove($tip); continue }
        if (-not $script:st[$tip] -and ((Get-Date) - $script:timedOk[$tip]).TotalSeconds -gt 3) {
            Clear-Timed $tip
            if ($script:CooldownAlways) { [void](Start-Cool $tip) }
        }
    }
    $script:alive = [bool](@($l) | Where-Object { $_.on })
    if ($script:alive -and $script:t.Interval -gt 5000) { $script:t.Interval = 5000 }
    Update-Armed
}
# 路由器上的热键映射变化时，重新注册本机的网页热键
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
    if ($failed.Count -gt 0) { Notify ("Unsupported hotkey: " + ($failed -join ', ') + " (use F1-F24, A-Z, 0-9, Pause, ScrollLock, Insert, Home, End, PageUp, PageDown)") 'err' }
}
# 定时键指向的网页热键（例如 'F'）-> 对应设备的 IP
function Resolve-Target([string]$t) {
    $bound = @($script:last | Where-Object { $_.key -and $_.key -ne '-' })
    if ($t) {
        $m = $bound | Where-Object { $_.key -ieq $t } | Select-Object -First 1
        if ($m) { return [string]$m.ip }
        Notify "No device has web hotkey '$t' on this PC" 'err'
        return $null
    }
    if ($bound.Count -eq 1) { return [string]$bound[0].ip }
    if ($bound.Count -eq 0) { Notify 'No web hotkey is set on this PC' 'err'; return $null }
    Notify 'Several web hotkeys exist: set Target for the timed key' 'err'
    return $null
}

# ---------- 计时器 / 冷却的记录 ----------
function Clear-Timed([string]$ip) { $script:deadlines.Remove($ip); $script:timedOk.Remove($ip) }
# 开始控制该设备的定时键的冷却；该定时键没有设置 Cooldown 时返回 $false
function Start-Cool([string]$ip) {
    $cd = [double]$script:coolFor[$ip]
    if ($cd -le 0) { return $false }
    $script:cool[$ip] = (Get-Date).AddSeconds($cd)
    $script:stickyIp = $ip
    $script:flashUntil = [datetime]::MinValue
    $script:dlTimer.Start()
    return $true
}

# ---------- 回复处理（由 Pump-Net 在界面线程中调用）----------
function H-Fail($ctx) {
    if ($ctx.ip) { Clear-Timed ([string]$ctx.ip); Update-Armed }
    Notify 'Cannot reach router' 'err'
}
function H-Quiet($ctx) { }
function H-Tick($r, $ctx) { $l = @($r.list); Update-State $l; Sync $l }
function H-Start($r, $ctx) { $l = @($r.list); Update-State $l; Sync $l; Notify 'Hotkey Limit running' 'info' }
function H-StartFail($ctx) { Notify 'Router not reachable yet, will keep trying' 'err' }
function H-Result($r, $ctx) {
    $ip = [string]$ctx.ip
    if ($r.error) { Clear-Timed $ip; Update-Armed; Notify ([string]$r.error) 'err'; return }
    $l = @($r.list)
    Update-State $l
    $d = $l | Where-Object { $_.ip -eq $ip } | Select-Object -First 1
    if ($d -and $d.on -and $script:deadlines.ContainsKey($ip) -and -not $script:timedOk.ContainsKey($ip)) { $script:timedOk[$ip] = Get-Date }
    # 正在进行的定时限速已经由绿色倒计时显示；静默回复（会进入冷却的停止操作）
    # 不能在红色倒计时上闪一下 OFF
    if ($script:deadlines.ContainsKey($ip) -or $ctx.quiet) { return }
    if ($d -and $d.on) { Notify "$ip  ON   up: $(V $d.up)   down: $(V $d.down)" 'on' }
    else { Notify "$ip  OFF" 'off' }
}

# ---------- 屏幕倒计时 ----------
# 定时限速运行时显示绿色 ON x.xs，冷却期间显示红色 OFF cooldown x.xs
function Show-Sticky {
    $ip = $script:stickyIp
    if (-not $ip) { return }
    $now = Get-Date
    if ($script:deadlines.ContainsKey($ip)) {
        $text = "$ip  ON   " + (Fmt (($script:deadlines[$ip] - $now).TotalSeconds)) + 's'; $kind = 0
    } elseif ($script:cool.ContainsKey($ip)) {
        $text = "$ip  OFF   cooldown " + (Fmt (($script:cool[$ip] - $now).TotalSeconds)) + 's'; $kind = 1
    } else {
        $script:stickyIp = $null
        if ($now -ge $script:flashUntil) { $script:toast.Clear() }
        return
    }
    if ($now -ge $script:flashUntil) { $script:toast.Say($text, $kind, $true) }
}
function Expire-Timers {
    $now = Get-Date
    foreach ($ip in @($script:deadlines.Keys)) {
        if ($now -ge $script:deadlines[$ip]) {
            # 时间到：如果有冷却，立刻显示红色倒计时，中间不闪 OFF
            if (Start-Cool $ip) { Do-Off $ip 'time up' $true } else { Do-Off $ip 'time up' $false }
        }
    }
    foreach ($ip in @($script:cool.Keys)) {
        if ($now -ge $script:cool[$ip]) { $script:cool.Remove($ip) }
    }
}

# ---------- 动作 ----------
function Do-Toggle([string]$ip) {
    $quiet = $false
    # 用 F 手动关闭正在运行的定时限速：开启 CooldownAlways 时同样会进入冷却
    if ($script:CooldownAlways -and $script:deadlines.ContainsKey($ip) -and (Start-Cool $ip)) { $quiet = $true }
    Clear-Timed $ip                    # 手动操作接管正在运行的计时
    if (-not $quiet) {
        if ($script:st[$ip]) { Notify "$ip  OFF ..." 'off' } else { Notify "$ip  ON ..." 'on' }
    }
    Send-Api 'toggle&src=ps' $true "{`"ip`":`"$ip`"}" 'H-Result' @{ ip = $ip; quiet = $quiet } 'H-Fail'
}
function Do-On([string]$ip, [double]$secs, [double]$cool) {
    if ($secs -gt 0) {
        $script:timedOk.Remove($ip)
        $script:deadlines[$ip] = (Get-Date).AddSeconds($secs)   # 从按下按键的那一刻开始计时
        $script:coolFor[$ip] = $cool
        $script:stickyIp = $ip
        $script:flashUntil = [datetime]::MinValue
        $script:dlTimer.Start()
        Update-Armed
        Show-Sticky
    } else {
        Notify "$ip  ON ..." 'on'
    }
    Send-Api 'on&src=ps' $true "{`"ip`":`"$ip`"}" 'H-Result' @{ ip = $ip } 'H-Fail'
}
function Do-Off([string]$ip, [string]$why, [bool]$quiet = $false) {
    Clear-Timed $ip
    if (-not $quiet) {
        if ($why) { Notify "$ip  OFF ($why) ..." 'off' } else { Notify "$ip  OFF ..." 'off' }
    }
    Send-Api 'off&src=ps' $true "{`"ip`":`"$ip`"}" 'H-Result' @{ ip = $ip; quiet = $quiet } 'H-Fail'
}
# 手动停止（再按定时键 / 取消键）：只有开启 CooldownAlways 才会进入冷却
function Do-Stop([string]$ip, [string]$why) {
    $quiet = $false
    if ($script:CooldownAlways -and $script:deadlines.ContainsKey($ip) -and (Start-Cool $ip)) { $quiet = $true }
    Do-Off $ip $why $quiet
}
function Do-Timed([int]$i) {
    $e = @($script:Timed)[$i]
    $ip = Resolve-Target ([string]$e.Target)
    if (-not $ip) { return }
    $now = Get-Date
    if ($script:cool.ContainsKey($ip) -and $now -lt $script:cool[$ip]) {
        # 仍在冷却中：不允许开启，重新显示红色倒计时
        $script:stickyIp = $ip
        $script:flashUntil = [datetime]::MinValue
        $script:dlTimer.Start()
        Show-Sticky
        return
    }
    if ($script:deadlines.ContainsKey($ip)) { Do-Stop $ip 'timed key' }   # 在计时时间内再次按下
    else { Do-On $ip ([double]$e.Seconds) ([double]$e.Cooldown) }
}
function Do-Cancel {
    if ($script:CancelScope -eq 'timed') {
        $ips = @($script:deadlines.Keys)
    } else {
        $bound = @($script:last | Where-Object { $_.key -and $_.key -ne '-' } | ForEach-Object { [string]$_.ip })
        $ips = @($bound | Where-Object { $script:st[$_] })
    }
    foreach ($ip in $ips) { Do-Stop $ip 'cancel key' }
}

# ---------- 界面对象 ----------
$script:tray = New-Object System.Windows.Forms.NotifyIcon
$script:tray.Icon = [System.Drawing.SystemIcons]::Shield
$script:tray.Text = 'Hotkey Limit (right-click: Exit)'
$menu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('Exit', $null, { [System.Windows.Forms.Application]::Exit() })
$script:tray.ContextMenuStrip = $menu
$script:tray.Visible = $true
$script:toast = New-Object Toast

# 轮询路由器：刷新热键映射；只要有限速开着就发送心跳
# （路由器只把这些心跳算在本脚本开启的限速上）
$script:t = New-Object System.Windows.Forms.Timer
$script:t.Interval = 5000
$script:t.add_Tick({
    $op = if ($script:alive) { 'beat&src=ps' } else { 'list' }
    Send-Api $op $false '' 'H-Tick' @{} 'H-Quiet'
    $script:t.Interval = if ($script:alive) { 5000 } else { 15000 }
})
# 结束定时限速、推进冷却、刷新屏幕上的倒计时
$script:dlTimer = New-Object System.Windows.Forms.Timer
$script:dlTimer.Interval = 100
$script:dlTimer.add_Tick({
    Expire-Timers
    Show-Sticky
    if ($script:deadlines.Count -eq 0 -and $script:cool.Count -eq 0) { $script:dlTimer.Stop() }
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

# 定时键（编号 2000+）和取消键（编号 1000+，永远不会被吞掉）
$bad = @()
$i = 0
foreach ($e in @($script:Timed)) {
    $vk = Get-VK ([string]$e.Key)
    if ($null -eq $vk -or -not ($e.Seconds -gt 0) -or ($e.Cooldown -and -not ($e.Cooldown -ge 0))) { $bad += "timed:$($e.Key)" }
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
if ($bad.Count -gt 0) { Notify ("Invalid config: " + ($bad -join ', ')) 'err' }
$script:t.Start()

[System.Windows.Forms.Application]::Run()
$script:hkw.Close()
$script:tray.Visible = $false
$script:tray.Dispose()
