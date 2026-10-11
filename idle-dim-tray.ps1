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

# --- single instance guard (process enumeration; mutex proved unreliable under PS New-Object) ---
$others = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'idle-dim-tray' }
if ($others) { Log "duplicate tray launch detected -> exit"; exit 0 }

# --- config ---
function Get-Config {
    if (Test-Path $script:CfgPath) {
        try { return Get-Content $script:CfgPath -Raw | ConvertFrom-Json } catch { }
    }
    $def = [pscustomobject]@{ IdleMinutes = 3; DimLevel = 30; PollSec = 15 }
    $def | ConvertTo-Json | Set-Content $script:CfgPath -Encoding utf8
    return $def
}
$cfg = Get-Config
$script:IdleMinutes = [int]$cfg.IdleMinutes
$script:DimLevel    = [int]$cfg.DimLevel
$script:PollSec     = [int]$cfg.PollSec

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
    $state = if ($script:paused) { '一時停止中' } elseif ($script:dimmed) { '暗転中' } else { '監視中' }
    $script:notify.Text = "idle-dim: $state (${script:IdleMinutes}分→${script:DimLevel}%)"
}

# --- settings dialog ---
function Show-Settings {
    $script:dlgForm = New-Object System.Windows.Forms.Form
    $script:dlgForm.Text = 'idle-dim 設定'
    $script:dlgForm.Size = New-Object System.Drawing.Size(360, 330)
    $script:dlgForm.FormBorderStyle = 'FixedDialog'
    $script:dlgForm.StartPosition = 'CenterScreen'
    $script:dlgForm.TopMost = $true
    $script:dlgForm.MaximizeBox = $false

    function Add-Row([int]$y, [string]$text) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $text; $lbl.Location = New-Object System.Drawing.Point(12, ($y + 3))
        $lbl.Size = New-Object System.Drawing.Size(210, 20)
        $script:dlgForm.Controls.Add($lbl)
        $num = New-Object System.Windows.Forms.NumericUpDown
        $num.Location = New-Object System.Drawing.Point(240, $y)
        $num.Size = New-Object System.Drawing.Size(90, 24)
        $script:dlgForm.Controls.Add($num)
        return $num
    }
    $script:dlgNumIdle = Add-Row 15 '暗転までの無操作時間(分)'
    $script:dlgNumIdle.Minimum = 0; $script:dlgNumIdle.Maximum = 180; $script:dlgNumIdle.Value = $script:IdleMinutes
    $script:dlgNumDim = Add-Row 55 '暗転時の輝度(%)'
    $script:dlgNumDim.Minimum = 1; $script:dlgNumDim.Maximum = 100; $script:dlgNumDim.Value = $script:DimLevel
    $script:dlgNumPoll = Add-Row 95 'チェック間隔(秒)'
    $script:dlgNumPoll.Minimum = 5; $script:dlgNumPoll.Maximum = 120; $script:dlgNumPoll.Value = $script:PollSec

    # --- live brightness slider (applies via DDC immediately) ---
    $lblSlider = New-Object System.Windows.Forms.Label
    $lblSlider.Text = '現在の輝度(即時適用)'
    $lblSlider.Location = New-Object System.Drawing.Point(12, 135)
    $lblSlider.Size = New-Object System.Drawing.Size(210, 20)
    $script:dlgForm.Controls.Add($lblSlider)

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
    if ($probe -ne "") {
        $idle = [Ddc]::IdleSeconds()
        $script:dlgLblInfo.Text = "モニター: DDC/CI対応 / 無操作: $idle 秒"
    } else {
        $script:dlgLblInfo.Text = "モニター: DDC/CI非応答"
    }
    $script:dlgLblInfo.Location = New-Object System.Drawing.Point(12, 208)
    $script:dlgLblInfo.Size = New-Object System.Drawing.Size(320, 20)
    $script:dlgForm.Controls.Add($script:dlgLblInfo)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = '保存して適用'
    $btnSave.Location = New-Object System.Drawing.Point(12, 246)
    $btnSave.Size = New-Object System.Drawing.Size(160, 32)
    $script:dlgForm.Controls.Add($btnSave)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = '閉じる'
    $btnCancel.Location = New-Object System.Drawing.Point(184, 246)
    $btnCancel.Size = New-Object System.Drawing.Size(146, 32)
    $btnCancel.DialogResult = 'Cancel'
    $script:dlgForm.Controls.Add($btnCancel)

    # slider -> apply brightness immediately
    $script:syncing = $false
    $script:dlgTrack.Add_ValueChanged({
        if ($script:syncing) { return }
        $v = [int]$script:dlgTrack.Value
        [void][Ddc]::SetLevel([uint32]$v)
        $script:origLevel = $v
        $script:dimmed = $false
        $script:lastRestore = Get-Date
        $script:dlgLblInfo.Text = "輝度を適用中: $v%"
        Log ("slider: brightness -> {0}%" -f $v)
    })

    $btnSave.Add_Click({
        $script:IdleMinutes = [int]$script:dlgNumIdle.Value
        $script:DimLevel    = [int]$script:dlgNumDim.Value
        $script:PollSec     = [int]$script:dlgNumPoll.Value
        [pscustomobject]@{ IdleMinutes = $script:IdleMinutes; DimLevel = $script:DimLevel; PollSec = $script:PollSec } |
            ConvertTo-Json | Set-Content $script:CfgPath -Encoding utf8
        $script:timer.Stop()
        $script:timer.Interval = $script:PollSec * 1000
        $script:timer.Start()
        if ($script:dimmed) { [void][Ddc]::SetLevel([uint32]$script:DimLevel) }
        Log ("config saved: idle={0}min dim={1}% poll={2}s" -f $script:IdleMinutes, $script:DimLevel, $script:PollSec)
        Update-Tray
        $script:dlgForm.Close()
    })

    [void]$script:dlgForm.ShowDialog()
}

# --- timer: dim/restore loop ---
$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = $script:PollSec * 1000
$script:timer.Add_Tick({
    if ($script:paused) { return }
    $probe = [Ddc]::Probe()
    if ($probe -eq "") { return }
    $p = $probe.Split('|')
    $min = [uint32]$p[0]; $cur = [uint32]$p[1]
    $idle = [Ddc]::IdleSeconds()
    $threshold = $script:IdleMinutes * 60
    if ($idle -ge $threshold -and -not $script:dimmed -and ((Get-Date) - $script:lastRestore).TotalSeconds -gt 30) {
        $script:origLevel = $cur
        [void][Ddc]::SetLevel([Math]::Max($script:DimLevel, $min))
        $script:dimmed = $true
        Log ("dim: idle {0}s -> {1}% (restore={2}%)" -f $idle, $script:DimLevel, $script:origLevel)
        Update-Tray
    }
    elseif ($script:dimmed -and $idle -lt 10) {
        if ($script:origLevel -ge 0) { [void][Ddc]::SetLevel([uint32]$script:origLevel) }
        $script:dimmed = $false
        $script:lastRestore = Get-Date
        Log ("restore: input detected -> {0}%" -f $script:origLevel)
        Update-Tray
    }
})

# --- tray icon + menu ---
$script:notify = New-Object System.Windows.Forms.NotifyIcon
$script:notify.Visible = $true
$script:notify.Add_DoubleClick({ Show-Settings })

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$itemSettings = $menu.Items.Add('設定を開く(&O)')
$itemSettings.Add_Click({ Show-Settings })
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$itemTest = $menu.Items.Add('今すぐ暗転テスト')
$itemTest.Add_Click({
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
$itemRestore = $menu.Items.Add('100%に戻す')
$itemRestore.Add_Click({
    [void][Ddc]::SetLevel(100)
    $script:dimmed = $false
    $script:lastRestore = Get-Date
    Log 'manual restore -> 100%'
    Update-Tray
})
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$script:itemPause = $menu.Items.Add('一時停止')
$script:itemPause.CheckOnClick = $true
$script:itemPause.Add_Click({
    $script:paused = $script:itemPause.Checked
    if ($script:paused -and $script:dimmed) {
        if ($script:origLevel -ge 0) { [void][Ddc]::SetLevel([uint32]$script:origLevel) }
        $script:dimmed = $false
    }
    Log ("paused: " + $script:paused)
    Update-Tray
})
$itemExit = $menu.Items.Add('終了(&X)')
$itemExit.Add_Click({
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
