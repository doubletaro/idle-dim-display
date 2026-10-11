# ddc-restore.ps1 - restore monitor brightness to 100 via DDC/CI
$code = @'
using System;
using System.Runtime.InteropServices;
public class DdcR {
    [DllImport("dxva2.dll")]
    public static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, ref uint count);
    [DllImport("dxva2.dll", CharSet=CharSet.Unicode)]
    public static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, uint size, [Out] PHYSICAL_MONITOR[] arr);
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
    static uint sLevel;
    static bool Callback(IntPtr hMon, IntPtr hdc, ref RECT rect, IntPtr data) {
        uint count = 0;
        if (GetNumberOfPhysicalMonitorsFromHMONITOR(hMon, ref count) && count > 0) {
            PHYSICAL_MONITOR[] mons = new PHYSICAL_MONITOR[count];
            if (GetPhysicalMonitorsFromHMONITOR(hMon, count, mons)) {
                foreach (PHYSICAL_MONITOR m in mons) {
                    SetMonitorBrightness(m.hPhysicalMonitor, sLevel);
                    DestroyPhysicalMonitor(m.hPhysicalMonitor);
                }
            }
        }
        return true;
    }
    public static void Set(uint level) { sLevel = level; EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, Callback, IntPtr.Zero); }
}
'@
Add-Type -TypeDefinition $code
[DdcR]::Set(100)
Write-Output "brightness restored to 100"
