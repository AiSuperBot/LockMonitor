<#
Test-VM helper (logged-on session): set or list the display scaling ("Scale" in Settings > Display) of one screen, at
once, the way Settings does it. Made to test screens with different scaling.
  .\Set-Scale.ps1                                   list: device, current and recommended scaling
  .\Set-Scale.ps1 -Device \\.\DISPLAY1 -Percent 150
#>
param([string]$Device, [int]$Percent = 0, [string]$Out = 'C:\locktest\scale.txt')
Add-Type @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text;
public static class Scale {
    [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint paths, out uint modes);
    [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint paths, [Out] byte[] pathArray, ref uint modes, [Out] byte[] modeArray, IntPtr topology);
    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo([In, Out] byte[] request);
    [DllImport("user32.dll")] static extern int DisplayConfigSetDeviceInfo([In] byte[] request);
    static readonly int[] Steps = { 100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500 };
    static byte[] Header(int type, int size, byte[] paths, int o) {   // DISPLAYCONFIG_DEVICE_INFO_HEADER for the SOURCE of a path: type, size, adapter LUID, source id
        byte[] r = new byte[size];
        BitConverter.GetBytes(type).CopyTo(r, 0); BitConverter.GetBytes(size).CopyTo(r, 4);
        Buffer.BlockCopy(paths, o, r, 8, 8); Buffer.BlockCopy(paths, o + 8, r, 16, 4);
        return r;
    }
    // every desktop screen as "device current% recommended%"; with device and percent given, that screen is set first. Types -3 / -4: the calls Settings uses for scaling.
    public static List<string> Run(string device, int percent) {
        List<string> rows = new List<string>();
        uint np, nm; GetDisplayConfigBufferSizes(2, out np, out nm);
        byte[] paths = new byte[72 * np], modes = new byte[64 * nm];
        QueryDisplayConfig(2, ref np, paths, ref nm, modes, IntPtr.Zero);
        for (int i = 0; i < np; i++) {
            byte[] name = Header(1, 84, paths, 72 * i); DisplayConfigGetDeviceInfo(name);
            string dev = Encoding.Unicode.GetString(name, 20, 64); int z = dev.IndexOf('\0'); if (z >= 0) dev = dev.Substring(0, z);
            byte[] get = Header(-3, 32, paths, 72 * i);
            if (DisplayConfigGetDeviceInfo(get) != 0) { rows.Add(dev + " scaling unknown"); continue; }
            int min = BitConverter.ToInt32(get, 20), cur = BitConverter.ToInt32(get, 24);
            int recommended = -min;   // index of the recommended step
            if (dev == device && percent > 0) {
                int want = Array.IndexOf(Steps, percent);
                byte[] set = Header(-4, 24, paths, 72 * i); BitConverter.GetBytes(want - recommended).CopyTo(set, 20);
                rows.Add("set " + dev + " to " + percent + "%: result " + DisplayConfigSetDeviceInfo(set));
                DisplayConfigGetDeviceInfo(get); cur = BitConverter.ToInt32(get, 24);
            }
            rows.Add(dev + " " + Steps[recommended + cur] + "% (recommended " + Steps[recommended] + "%)");
        }
        return rows;
    }
}
'@
Set-Content $Out ([Scale]::Run($Device, $Percent))
