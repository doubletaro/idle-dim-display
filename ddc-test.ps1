# one-shot test: dim to 30, verify, restore to 100
$code = @'
using System;
using System.Runtime.InteropServices;
public class DdcT {
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
    static bool sProbe; static uint sCur; static bool sGot;
    static bool Callback(IntPtr hMon, IntPtr hdc, ref RECT rect, IntPtr data) {
        uint count = 0;
        if (GetNumberOfPhysicalMonitorsFromHMONITOR(hMon, ref count) && count > 0) {
            PHYSICAL_MONITOR[] mons = new PHYSICAL_MONITOR[count];
            if (GetPhysicalMonitorsFromHMONITOR(hMon, count, mons)) {
                foreach (PHYSICAL_MONITOR m in mons) {
                    uint min=0, cur=0, max=0;
                    if (GetMonitorBrightness(m.hPhysicalMonitor, ref min, ref cur, ref max)) {
                        if (sProbe) { sCur = cur; sGot = true; }
                        else { SetMonitorBrightness(m.hPhysicalMonitor, sCur); }
                    }
                    DestroyPhysicalMonitor(m.hPhysicalMonitor);
                }
            }
        }
        return true;
    }
    public static string Read() { sProbe = true; sGot = false; EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, Callback, IntPtr.Zero); sProbe = false; return sGot ? sCur.ToString() : "?"; }
    public static void Write(uint level) { sProbe = false; sCur = level; EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, Callback, IntPtr.Zero); }
}
'@
Add-Type -TypeDefinition $code
$before = [DdcT]::Read()
Write-Output "before: $before"
[DdcT]::Write(30)
Start-Sleep -Milliseconds 800
Write-Output ("during dim: " + [DdcT]::Read())
Start-Sleep -Milliseconds 1200
[DdcT]::Write(100)
Start-Sleep -Milliseconds 800
Write-Output ("restored: " + [DdcT]::Read())
