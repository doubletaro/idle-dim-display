# idle-dim-watcher.ps1 - dim monitor backlight after keyboard/mouse idle, restore on input
# Config
$IdleMinutes = 3        # idle minutes before dimming
$DimLevel    = 30       # brightness % while dimmed
$PollSec     = 15       # check interval
$LogFile     = "$env:USERPROFILE\bin\idle-dim.log"

# single-instance guard: exit if another watcher is already running
$others = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'idle-dim-watcher' }
if ($others) { exit 0 }

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
    static bool sGot;
    static bool sChanged;
    static uint sNewLevel;
    static bool sProbe;

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
                        else if (cur != sNewLevel) { SetMonitorBrightness(m.hPhysicalMonitor, sNewLevel); sChanged = true; }
                    }
                    DestroyPhysicalMonitor(m.hPhysicalMonitor);
                }
            }
        }
        return true;
    }

    // probe returns "min|cur|max" of first DDC monitor, or "" if none
    public static string Probe() {
        sProbe = true; sGot = false;
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, Callback, IntPtr.Zero);
        sProbe = false;
        return sGot ? (sMin + "|" + sCur + "|" + sMax) : "";
    }

    // set brightness; returns number of monitors actually changed
    public static int SetLevel(uint level) {
        sProbe = false; sNewLevel = level; sChanged = false;
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, Callback, IntPtr.Zero);
        return sChanged ? 1 : 0;
    }
}
'@
Add-Type -TypeDefinition $code

function Log([string]$msg) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" | Out-File -FilePath $LogFile -Append -Encoding utf8
}

# remember original brightness (re-captured while active, so manual changes win)
$origLevel = -1
$dimmed = $false
$lastRestore = [DateTime]::MinValue
Log "watcher started (idle>${IdleMinutes}min -> dim ${DimLevel}%)"

while ($true) {
    $probe = [Ddc]::Probe()
    if ($probe -ne "") {
        $parts = $probe.Split('|')
        $min = [uint32]$parts[0]; $cur = [uint32]$parts[1]; $max = [uint32]$parts[2]
        $idle = [Ddc]::IdleSeconds()
        $threshold = $IdleMinutes * 60

        if ($idle -ge $threshold -and -not $dimmed -and ((Get-Date) - $lastRestore).TotalSeconds -gt 30) {
            # capture current as restore point, then dim
            $origLevel = $cur
            [void][Ddc]::SetLevel([Math]::Max($DimLevel, $min))
            $dimmed = $true
            Log ("dim: idle {0}s -> set {1}% (restore={2}%)" -f $idle, $DimLevel, $origLevel)
        }
        elseif ($dimmed -and $idle -lt 10) {
            # fresh input detected -> restore original brightness
            if ($origLevel -ge 0) { [void][Ddc]::SetLevel([uint32]$origLevel) }
            $dimmed = $false
            $lastRestore = Get-Date
            Log ("restore: input detected -> {0}%" -f $origLevel)
        }
    }
    Start-Sleep -Seconds $PollSec
}
