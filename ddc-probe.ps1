$code = @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public class DdcProbe {
    [DllImport("dxva2.dll")]
    static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, ref uint count);
    [DllImport("dxva2.dll", CharSet=CharSet.Unicode)]
    static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, uint size, [Out] PHYSICAL_MONITOR[] arr);
    [DllImport("dxva2.dll")]
    static extern bool GetMonitorBrightness(IntPtr h, ref uint min, ref uint cur, ref uint max);
    [DllImport("dxva2.dll")]
    static extern bool DestroyPhysicalMonitor(IntPtr h);
    [DllImport("user32.dll")]
    static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, EnumProc cb, IntPtr data);

    delegate bool EnumProc(IntPtr hMon, IntPtr hdc, ref RECT rect, IntPtr data);

    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    struct PHYSICAL_MONITOR {
        public IntPtr hPhysicalMonitor;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)]
        public string szPhysicalMonitorDescription;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct RECT { public int left, top, right, bottom; }

    static StringBuilder sb = new StringBuilder();

    public static string Probe() {
        sb.Length = 0;
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, Callback, IntPtr.Zero);
        if (sb.Length == 0) sb.Append("NO-MONITOR-ENUMERATED");
        return sb.ToString();
    }

    static bool Callback(IntPtr hMon, IntPtr hdc, ref RECT rect, IntPtr data) {
        uint count = 0;
        if (GetNumberOfPhysicalMonitorsFromHMONITOR(hMon, ref count) && count > 0) {
            PHYSICAL_MONITOR[] mons = new PHYSICAL_MONITOR[count];
            if (GetPhysicalMonitorsFromHMONITOR(hMon, count, mons)) {
                foreach (PHYSICAL_MONITOR m in mons) {
                    uint min = 0, cur = 0, max = 0;
                    if (GetMonitorBrightness(m.hPhysicalMonitor, ref min, ref cur, ref max)) {
                        sb.Append("OK | ").Append(m.szPhysicalMonitorDescription)
                          .Append(" | range ").Append(min).Append("-").Append(max)
                          .Append(" current=").Append(cur).Append("\n");
                    } else {
                        sb.Append("NO-DDC | ").Append(m.szPhysicalMonitorDescription)
                          .Append(" | winerr=").Append(Marshal.GetLastWin32Error()).Append("\n");
                    }
                    DestroyPhysicalMonitor(m.hPhysicalMonitor);
                }
            }
        }
        return true;
    }
}
'@
Add-Type -TypeDefinition $code
[DdcProbe]::Probe()
