# idle-dim-tray.ps1 - tray-resident idle display dimmer with settings GUI
# - tray icon (system notification area) + context menu
# - settings dialog: idle minutes / dim level / poll interval (persisted to JSON)
# - same DDC/CI logic as the old watcher; replaces it
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = 'Stop'
$script:LogPath = "$env:USERPROFILE\bin\idle-dim.log"
$script:CfgPath = "$env:USERPROFILE\bin\idle-dim-config.json"

function Log([string]$msg) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" | Out-File -FilePath $script:LogPath -Append -Encoding utf8
}

# --- crash logging: any unhandled UI/domain exception lands in the log instead of dying silently ---
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException, $true)
$uiExHandler = [System.Threading.ThreadExceptionEventHandler]{ param($s, $e) Log ("UI-EXCEPTION: " + $e.Exception.ToString()) }
[System.Windows.Forms.Application]::add_ThreadException($uiExHandler)
$domainExHandler = [System.UnhandledExceptionEventHandler]{ param($s, $e) Log ("DOMAIN-EXCEPTION: " + $e.ExceptionObject.ToString()) }
[System.AppDomain]::CurrentDomain.add_UnhandledException($domainExHandler)

# --- single instance guard (process enumeration; mutex proved unreliable under PS New-Object) ---
$others = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'idle-dim-tray' }
if ($others) { Log "duplicate tray launch detected -> exit"; exit 0 }

# --- config ---
function Get-Config {
    if (Test-Path $script:CfgPath) {
        try { return Get-Content $script:CfgPath -Raw | ConvertFrom-Json } catch { }
    }
    $def = [pscustomobject]@{ IdleMinutes = 3; DimLevel = 30; PollSec = 1; Language = 'ja' }
    $def | ConvertTo-Json | Set-Content $script:CfgPath -Encoding utf8
    return $def
}
$cfg = Get-Config
$script:IdleMinutes = [int]$cfg.IdleMinutes
$script:DimLevel    = [int]$cfg.DimLevel
$script:PollSec     = [int]$cfg.PollSec
$script:Lang        = [string]$cfg.Language
if (@('ja','en','zh') -notcontains $script:Lang) { $script:Lang = 'ja' }

# --- DDC/CI helpers ---
$code = @'
using System;
using System.Runtime.InteropServices;
public class Ddc {
    [DllImport("user32.dll")]
    public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("dxva2.dll")]
    public static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, ref uint count);
    [DllImport("dxva2.dll", CharSet=CharSet.Unicode)]
    public static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, uint size, [Out] PHYSICAL_MONITOR[] arr);
    [DllImport("dxva2.dll")]
    public static extern bool GetMonitorBrightness(IntPtr h, ref uint min, ref uint cur, ref uint max);
    [DllImport("dxva2.dll")]
    public static extern bool SetMonitorBrightness(IntPtr h, uint level);
    [DllImport("dxva2.dll")]
    public static extern bool DestroyPhysicalMonitor(IntPtr h);
    [DllImport("user32.dll")]
    public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, EnumProc cb, IntPtr data);
    public delegate bool EnumProc(IntPtr hMon, IntPtr hdc, ref RECT rect, IntPtr data);
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct PHYSICAL_MONITOR {
        public IntPtr hPhysicalMonitor;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)]
        public string szPhysicalMonitorDescription;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int left, top, right, bottom; }

    static uint sMin, sCur, sMax;
    static bool sGot, sProbe;
    static uint sNewLevel;

    public static uint IdleSeconds() {
        LASTINPUTINFO lii = new LASTINPUTINFO();
        lii.cbSize = (uint)Marshal.SizeOf(lii);
        if (!GetLastInputInfo(ref lii)) return 0;
        return ((uint)Environment.TickCount - lii.dwTime) / 1000;
    }
    static bool Callback(IntPtr hMon, IntPtr hdc, ref RECT rect, IntPtr data) {
        uint count = 0;
        if (GetNumberOfPhysicalMonitorsFromHMONITOR(hMon, ref count) && count > 0) {
            PHYSICAL_MONITOR[] mons = new PHYSICAL_MONITOR[count];
            if (GetPhysicalMonitorsFromHMONITOR(hMon, count, mons)) {
                foreach (PHYSICAL_MONITOR m in mons) {
                    uint min = 0, cur = 0, max = 0;
                    if (GetMonitorBrightness(m.hPhysicalMonitor, ref min, ref cur, ref max)) {
                        if (sProbe) { sMin = min; sCur = cur; sMax = max; sGot = true; }
                        else if (cur != sNewLevel) { SetMonitorBrightness(m.hPhysicalMonitor, sNewLevel); }
                    }
                    DestroyPhysicalMonitor(m.hPhysicalMonitor);
                }
            }
        }
        return true;
    }
    public static string Probe() {
        sProbe = true; sGot = false;
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, Callback, IntPtr.Zero);
        sProbe = false;
        return sGot ? (sMin + "|" + sCur + "|" + sMax) : "";
    }
    public static void SetLevel(uint level) {
        sProbe = false; sNewLevel = level;
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, Callback, IntPtr.Zero);
    }
}
'@
Add-Type -TypeDefinition $code

# --- state ---
$script:dimmed = $false
$script:origLevel = -1
$script:lastRestore = [DateTime]::MinValue
$script:paused = $false
$script:restoreTries = 0
$script:lastGoodLevel = -1

# --- tray icon drawing ---
function New-TrayIcon([string]$mode) {
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $color = switch ($mode) {
        'active' { [System.Drawing.Color]::Gold }      # watching (sun)
        'dim'    { [System.Drawing.Color]::DarkOrange }# dimmed
        'paused' { [System.Drawing.Color]::Gray }      # paused
    }
    $brush = New-Object System.Drawing.SolidBrush $color
    $g.FillEllipse($brush, 2, 2, 12, 12)
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(60,60,60)), 1
    $g.DrawEllipse($pen, 2, 2, 12, 12)
    if ($mode -eq 'dim') {
        # half-moon overlay to signal dimmed state
        $dark = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(120,40,40,40))
        $g.FillPie($dark, 2, 2, 12, 12, 90, 180)
    }
    $g.Dispose()
    $ico = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    return $ico
}

function Update-Tray {
    $mode = if ($script:paused) { 'paused' } elseif ($script:dimmed) { 'dim' } else { 'active' }
    $script:notify.Icon = New-TrayIcon $mode
    $state = if ($script:paused) { T 'paused' } elseif ($script:dimmed) { T 'dimmed' } else { T 'watching' }
    $script:notify.Text = "idle-dim: $state (${script:IdleMinutes}min→${script:DimLevel}%)"
}

# --- localization ---
$script:LOC = @{
    ja = @{
        title='idle-dim 設定'; idle='暗転までの無操作時間(分)'; dim='暗転時の輝度(%)'; poll='チェック間隔(秒)'
        slider='現在の輝度(即時適用)'; save='保存して適用'; cancel='閉じる'
        settings='設定を開く(&O)'; test='今すぐ暗転テスト'; restore='100%に戻す'; pause='一時停止'; exit='終了(&X)'
        watching='監視中'; dimmed='暗転中'; paused='一時停止中'
        applied='輝度を適用中: {0}%'; infoDdc='モニター: DDC/CI対応 / 無操作: {0} 秒'; infoNoDdc='モニター: DDC/CI非応答'
        lang='Language / 言語'
    }
    en = @{
        title='idle-dim Settings'; idle='Idle minutes before dim'; dim='Dimmed brightness (%)'; poll='Check interval (seconds)'
        slider='Current brightness (live)'; save='Save and Apply'; cancel='Close'
        settings='&Settings...'; test='Dim test now'; restore='Restore to 100%'; pause='Pause'; exit='E&xit'
        watching='Watching'; dimmed='Dimmed'; paused='Paused'
        applied='Brightness applied: {0}%'; infoDdc='Monitor: DDC/CI OK / idle: {0} s'; infoNoDdc='Monitor: no DDC/CI response'
        lang='Language'
    }
    zh = @{
        title='idle-dim 设置'; idle='空闲多少分钟后变暗(分)'; dim='变暗时的亮度(%)'; poll='检查间隔(秒)'
        slider='当前亮度(即时应用)'; save='保存并应用'; cancel='关闭'
        settings='打开设置(&O)'; test='立即测试变暗'; restore='恢复到100%'; pause='暂停'; exit='退出(&X)'
        watching='监控中'; dimmed='已变暗'; paused='已暂停'
        applied='已应用亮度: {0}%'; infoDdc='显示器: DDC/CI 正常 / 空闲: {0} 秒'; infoNoDdc='显示器: 无 DDC/CI 响应'
        lang='语言'
    }
}
function T([string]$key) { return $script:LOC[$script:Lang][$key] }

function Update-MenuTexts {
    if (-not $script:miSettings) { return }
    $script:miSettings.Text = T 'settings'
    $script:miTest.Text     = T 'test'
    $script:miRestore.Text  = T 'restore'
    $script:miPause.Text    = T 'pause'
    $script:miExit.Text     = T 'exit'
}

# --- settings dialog ---
function Show-Settings {
    $script:dlgForm = New-Object System.Windows.Forms.Form
    $script:dlgForm.Text = T 'title'
    $script:dlgForm.Size = New-Object System.Drawing.Size(360, 380)
    $script:dlgForm.FormBorderStyle = 'FixedDialog'
    $script:dlgForm.StartPosition = 'CenterScreen'
    $script:dlgForm.TopMost = $true
    $script:dlgForm.MaximizeBox = $false

    $script:dlgRowLabels = @{}
    function Add-Row([int]$y, [string]$text) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $text; $lbl.Location = New-Object System.Drawing.Point(12, ($y + 3))
        $lbl.Size = New-Object System.Drawing.Size(210, 20)
        $script:dlgForm.Controls.Add($lbl)
        $script:dlgRowLabels[[string]$y] = $lbl
        $num = New-Object System.Windows.Forms.NumericUpDown
        $num.Location = New-Object System.Drawing.Point(240, $y)
        $num.Size = New-Object System.Drawing.Size(90, 24)
        $script:dlgForm.Controls.Add($num)
        return $num
    }
    $script:dlgNumIdle = Add-Row 15 (T 'idle')
    $script:dlgNumIdle.Minimum = 0; $script:dlgNumIdle.Maximum = 180; $script:dlgNumIdle.Value = $script:IdleMinutes
    $script:dlgNumDim = Add-Row 55 (T 'dim')
    $script:dlgNumDim.Minimum = 1; $script:dlgNumDim.Maximum = 100; $script:dlgNumDim.Value = $script:DimLevel
    $script:dlgNumPoll = Add-Row 95 (T 'poll')
    $script:dlgNumPoll.Minimum = 1; $script:dlgNumPoll.Maximum = 120; $script:dlgNumPoll.Value = $script:PollSec

    # --- live brightness slider (applies via DDC immediately) ---
    $script:dlgLblSlider = New-Object System.Windows.Forms.Label
    $script:dlgLblSlider.Text = T 'slider'
    $script:dlgLblSlider.Location = New-Object System.Drawing.Point(12, 135)
    $script:dlgLblSlider.Size = New-Object System.Drawing.Size(210, 20)
    $script:dlgForm.Controls.Add($script:dlgLblSlider)

    $script:dlgTrack = New-Object System.Windows.Forms.TrackBar
    $script:dlgTrack.Minimum = 0
    $script:dlgTrack.Maximum = 100
    $script:dlgTrack.TickFrequency = 10
    $script:dlgTrack.SmallChange = 1
    $script:dlgTrack.LargeChange = 10
    $script:dlgTrack.Location = New-Object System.Drawing.Point(12, 155)
    $script:dlgTrack.Size = New-Object System.Drawing.Size(320, 45)
    $probe = [Ddc]::Probe()
    if ($probe -ne "") {
        $p = $probe.Split('|')
        $script:dlgTrack.Value = [Math]::Min([Math]::Max([int]$p[1], 0), 100)
    } else {
        $script:dlgTrack.Value = $script:DimLevel
    }
    $script:dlgForm.Controls.Add($script:dlgTrack)

    $script:dlgLblInfo = New-Object System.Windows.Forms.Label
    $script:dlgProbeOk = $false
    if ($probe -ne "") {
        $script:dlgProbeOk = $true
        $idle = [Ddc]::IdleSeconds()
        $script:dlgLblInfo.Text = T 'infoDdc' -f $idle
    } else {
        $script:dlgLblInfo.Text = T 'infoNoDdc'
    }
    $script:dlgLblInfo.Location = New-Object System.Drawing.Point(12, 208)
    $script:dlgLblInfo.Size = New-Object System.Drawing.Size(320, 20)
    $script:dlgForm.Controls.Add($script:dlgLblInfo)

    # --- language group (applies to the dialog immediately, persisted on save) ---
    $script:dlgGrpLang = New-Object System.Windows.Forms.GroupBox
    $script:dlgGrpLang.Text = T 'lang'
    $script:dlgGrpLang.Location = New-Object System.Drawing.Point(12, 232)
    $script:dlgGrpLang.Size = New-Object System.Drawing.Size(320, 54)
    $script:dlgForm.Controls.Add($script:dlgGrpLang)

    $script:dlgRadioJa = New-Object System.Windows.Forms.RadioButton
    $script:dlgRadioJa.Text = '日本語'; $script:dlgRadioJa.Size = New-Object System.Drawing.Size(90, 20); $script:dlgRadioJa.Location = New-Object System.Drawing.Point(10, 24)
    $script:dlgRadioEn = New-Object System.Windows.Forms.RadioButton
    $script:dlgRadioEn.Text = 'English'; $script:dlgRadioEn.Size = New-Object System.Drawing.Size(90, 20); $script:dlgRadioEn.Location = New-Object System.Drawing.Point(110, 24)
    $script:dlgRadioZh = New-Object System.Windows.Forms.RadioButton
    $script:dlgRadioZh.Text = '中文'; $script:dlgRadioZh.Size = New-Object System.Drawing.Size(90, 20); $script:dlgRadioZh.Location = New-Object System.Drawing.Point(210, 24)
    $script:dlgRadioJa.Checked = ($script:Lang -eq 'ja')
    $script:dlgRadioEn.Checked = ($script:Lang -eq 'en')
    $script:dlgRadioZh.Checked = ($script:Lang -eq 'zh')
    $script:dlgGrpLang.Controls.Add($script:dlgRadioJa)
    $script:dlgGrpLang.Controls.Add($script:dlgRadioEn)
    $script:dlgGrpLang.Controls.Add($script:dlgRadioZh)

    function Apply-DialogLanguage {
        $script:dlgForm.Text = T 'title'
        $script:dlgRowLabels['15'].Text = T 'idle'
        $script:dlgRowLabels['55'].Text = T 'dim'
        $script:dlgRowLabels['95'].Text = T 'poll'
        $script:dlgLblSlider.Text = T 'slider'
        $script:dlgGrpLang.Text = T 'lang'
        $script:dlgBtnSave.Text = T 'save'
        $script:dlgBtnCancel.Text = T 'cancel'
        if ($script:dlgProbeOk) {
            $script:dlgLblInfo.Text = ((T 'infoDdc') -f [Ddc]::IdleSeconds())
        } else {
            $script:dlgLblInfo.Text = T 'infoNoDdc'
        }
    }
    $script:dlgRadioJa.Add_CheckedChanged({ if ($script:dlgRadioJa.Checked) { $script:Lang = 'ja'; Apply-DialogLanguage; Update-MenuTexts; Update-Tray } })
    $script:dlgRadioEn.Add_CheckedChanged({ if ($script:dlgRadioEn.Checked) { $script:Lang = 'en'; Apply-DialogLanguage; Update-MenuTexts; Update-Tray } })
    $script:dlgRadioZh.Add_CheckedChanged({ if ($script:dlgRadioZh.Checked) { $script:Lang = 'zh'; Apply-DialogLanguage; Update-MenuTexts; Update-Tray } })

    $script:dlgBtnSave = New-Object System.Windows.Forms.Button
    $script:dlgBtnSave.Text = T 'save'
    $script:dlgBtnSave.Location = New-Object System.Drawing.Point(12, 298)
    $script:dlgBtnSave.Size = New-Object System.Drawing.Size(160, 32)
    $script:dlgForm.Controls.Add($script:dlgBtnSave)

    $script:dlgBtnCancel = New-Object System.Windows.Forms.Button
    $script:dlgBtnCancel.Text = T 'cancel'
    $script:dlgBtnCancel.Location = New-Object System.Drawing.Point(184, 298)
    $script:dlgBtnCancel.Size = New-Object System.Drawing.Size(146, 32)
    $script:dlgBtnCancel.DialogResult = 'Cancel'
    $script:dlgForm.Controls.Add($script:dlgBtnCancel)

    # slider -> apply brightness immediately
    $script:syncing = $false
    $script:dlgTrack.Add_ValueChanged({
        if ($script:syncing) { return }
        $v = [int]$script:dlgTrack.Value
        [void][Ddc]::SetLevel([uint32]$v)
        $script:origLevel = $v
        $script:lastGoodLevel = $v
        $script:dimmed = $false
        $script:lastRestore = Get-Date
        $script:dlgLblInfo.Text = ((T 'applied') -f $v)
        Log ("slider: brightness -> {0}%" -f $v)
    })

    $script:dlgBtnSave.Add_Click({
        $script:IdleMinutes = [int]$script:dlgNumIdle.Value
        $script:DimLevel    = [int]$script:dlgNumDim.Value
        $script:PollSec     = [int]$script:dlgNumPoll.Value
        [pscustomobject]@{ IdleMinutes = $script:IdleMinutes; DimLevel = $script:DimLevel; PollSec = $script:PollSec; Language = $script:Lang } |
            ConvertTo-Json | Set-Content $script:CfgPath -Encoding utf8
        $script:timer.Stop()
        $script:timer.Interval = $script:PollSec * 1000
        $script:timer.Start()
        if ($script:dimmed) { [void][Ddc]::SetLevel([uint32]$script:DimLevel) }
        Log ("config saved: idle={0}min dim={1}% poll={2}s lang={3}" -f $script:IdleMinutes, $script:DimLevel, $script:PollSec, $script:Lang)
        Update-MenuTexts
        Update-Tray
        $script:dlgForm.Close()
    })

    [void]$script:dlgForm.ShowDialog()
}

# --- timer: dim/restore loop ---
# ticks every PollSec (1s recommended): restore is checked cheaply every tick via
# GetLastInputInfo only; DDC communication happens just once, at dim time.
$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = $script:PollSec * 1000
$script:timer.Add_Tick({
    if ($script:paused) { return }
    $idle = [Ddc]::IdleSeconds()
    $threshold = $script:IdleMinutes * 60
    if ($script:dimmed -and $idle -lt 10) {
        # fast path: fresh input -> restore immediately
        if ($script:origLevel -ge 0) { [void][Ddc]::SetLevel([uint32]$script:origLevel) }
        # verify the write stuck (DDC writes can be lost, e.g. after display standby)
        $probe = [Ddc]::Probe()
        $ok = $true
        if ($probe -ne "") {
            $curNow = [uint32]($probe.Split('|')[1])
            $ok = ($curNow -eq [uint32]$script:origLevel)
        }
        if ($ok -or $script:restoreTries -ge 10) {
            $script:dimmed = $false
            $script:lastRestore = Get-Date
            $script:restoreTries = 0
            if ($script:origLevel -ge 0) { $script:lastGoodLevel = $script:origLevel }
            Log ("restore: input detected -> {0}%{1}" -f $script:origLevel, $(if ($ok) { " (verified)" } else { " (unverified, giving up)" }))
            Update-Tray
        } else {
            $script:restoreTries++
            Log ("restore retry {0}: target {1}% not stuck yet" -f $script:restoreTries, $script:origLevel)
        }
        return
    }
    if (-not $script:dimmed -and $idle -ge $threshold -and ((Get-Date) - $script:lastRestore).TotalSeconds -gt 30) {
        $probe = [Ddc]::Probe()
        if ($probe -eq "") { return }
        $p = $probe.Split('|')
        $min = [uint32]$p[0]; $cur = [uint32]$p[1]
        if ($cur -le $script:DimLevel -and $script:lastGoodLevel -ge 0) {
            # screen is still at/below dim level: the previous restore likely failed -
            # do NOT adopt the dim level as the restore point, keep the last known good level
            $script:origLevel = [uint32]$script:lastGoodLevel
            Log ("dim: probe read {0}% (<= dim level) -> keeping restore point {1}%" -f $cur, $script:origLevel)
        } else {
            $script:origLevel = $cur
            $script:lastGoodLevel = $cur
        }
        [void][Ddc]::SetLevel([Math]::Max($script:DimLevel, $min))
        $script:dimmed = $true
        Log ("dim: idle {0}s -> {1}% (restore={2}%)" -f $idle, $script:DimLevel, $script:origLevel)
        Update-Tray
    }
})

# --- tray icon + menu ---
$script:notify = New-Object System.Windows.Forms.NotifyIcon
$script:notify.Visible = $true
$script:notify.Add_DoubleClick({ Show-Settings })

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$txt = T 'settings'
$script:miSettings = $menu.Items.Add($txt)
$script:miSettings.Add_Click({ Show-Settings })
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$txt = T 'test'
$script:miTest = $menu.Items.Add($txt)
$script:miTest.Add_Click({
    $probe = [Ddc]::Probe()
    if ($probe -ne "") {
        $p = $probe.Split('|')
        $script:origLevel = [uint32]$p[1]
        [void][Ddc]::SetLevel([uint32]$script:DimLevel)
        Log ("manual dim test -> {0}% (restore={1}%)" -f $script:DimLevel, $script:origLevel)
        $script:dimmed = $true
        Update-Tray
    }
})
$txt = T 'restore'
$script:miRestore = $menu.Items.Add($txt)
$script:miRestore.Add_Click({
    [void][Ddc]::SetLevel(100)
    $script:dimmed = $false
    $script:lastRestore = Get-Date
    Log 'manual restore -> 100%'
    Update-Tray
})
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$txt = T 'pause'
$script:miPause = $menu.Items.Add($txt)
$script:miPause.CheckOnClick = $true
$script:miPause.Add_Click({
    $script:paused = $script:miPause.Checked
    if ($script:paused -and $script:dimmed) {
        if ($script:origLevel -ge 0) { [void][Ddc]::SetLevel([uint32]$script:origLevel) }
        $script:dimmed = $false
    }
    Log ("paused: " + $script:paused)
    Update-Tray
})
$txt = T 'exit'
$script:miExit = $menu.Items.Add($txt)
$script:miExit.Add_Click({
    if ($script:dimmed -and $script:origLevel -ge 0) { [void][Ddc]::SetLevel([uint32]$script:origLevel) }
    $script:timer.Stop()
    $script:notify.Visible = $false
    Log 'tray exited'
    [System.Windows.Forms.Application]::Exit()
})
$script:notify.ContextMenuStrip = $menu

Update-Tray
Log ("tray started: idle={0}min dim={1}% poll={2}s" -f $script:IdleMinutes, $script:DimLevel, $script:PollSec)
$script:timer.Start()
[System.Windows.Forms.Application]::Run((New-Object System.Windows.Forms.ApplicationContext))
