<#
Test-VM probe (logged-on session; elevated only for -Take): what this Windows answers to the monitor-specialization
requests the helper makes, with Windows' raw return codes. For every connected display target: device-info type 2
(target name, a request every Windows 10 knows) as the control, then type 12 (GET specialization) with every packet size
from 20 to 64 bytes. 0 = understood; 87 for every size = this Windows does not know the request at all.
-Take additionally sends the helper's type 13 SET for the last target and puts it back right away.   Log: -Out
#>
param([string]$Out = 'C:\locktest\probe-spec.txt', [switch]$Take)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Text;
public static class SpecProbe {
    [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint np, out uint nm);
    [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint np, byte[] paths, ref uint nm, byte[] modes, IntPtr topo);
    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(byte[] packet);
    [DllImport("user32.dll")] static extern int DisplayConfigSetDeviceInfo(byte[] packet);
    static byte[] Packet(int type, int size, uint lo, int hi, uint id) {
        byte[] p = new byte[Math.Max(size, 20)];
        BitConverter.GetBytes(type).CopyTo(p, 0); BitConverter.GetBytes(size).CopyTo(p, 4);
        BitConverter.GetBytes(lo).CopyTo(p, 8); BitConverter.GetBytes(hi).CopyTo(p, 12); BitConverter.GetBytes(id).CopyTo(p, 16);
        return p;
    }
    static int Set13(uint lo, int hi, uint id, bool on) {   // the helper's request, byte for byte: 312 bytes, pseudo-specialized GUID, app name
        byte[] p = Packet(13, 312, lo, hi, id);
        BitConverter.GetBytes(on ? 1 : 0).CopyTo(p, 20);
        new Guid("f196c02f-f86f-4f9a-aa15-e9cebdfe3b96").ToByteArray().CopyTo(p, 24);
        Encoding.Unicode.GetBytes("LockMonitor").CopyTo(p, 56);
        return DisplayConfigSetDeviceInfo(p);
    }
    public static string Run(bool take) {
        StringBuilder sb = new StringBuilder();
        uint np, nm; int rc = GetDisplayConfigBufferSizes(1 /* QDC_ALL_PATHS */, out np, out nm);
        byte[] paths = new byte[np * 72], modes = new byte[nm * 64];
        rc = QueryDisplayConfig(1, ref np, paths, ref nm, modes, IntPtr.Zero);
        sb.AppendLine("QueryDisplayConfig(all paths): " + rc + ", " + np + " paths");
        var seen = new System.Collections.Generic.HashSet<string>();
        uint lastLo = 0, lastId = 0; int lastHi = 0; bool any = false;
        for (int i = 0; i < np; i++) {
            int o = i * 72;
            uint lo = BitConverter.ToUInt32(paths, o + 20); int hi = BitConverter.ToInt32(paths, o + 24); uint id = BitConverter.ToUInt32(paths, o + 28);
            bool available = BitConverter.ToInt32(paths, o + 60) != 0;
            if (!available || !seen.Add(lo + ":" + hi + ":" + id)) continue;
            byte[] name = Packet(2, 420, lo, hi, id);
            int rn = DisplayConfigGetDeviceInfo(name);
            string friendly = Encoding.Unicode.GetString(name, 36, 128).TrimEnd('\0');
            string path = Encoding.Unicode.GetString(name, 164, 256).TrimEnd('\0');
            sb.AppendLine("target " + id + " on adapter " + hi + ":" + lo + ": type 2 -> " + rn + " \"" + friendly + "\" " + path);
            StringBuilder sizes = new StringBuilder();
            for (int size = 20; size <= 64; size += 4) {
                byte[] g = Packet(12, size, lo, hi, id);
                int r = DisplayConfigGetDeviceInfo(g);
                sizes.Append(" " + size + ":" + r + (r == 0 && size >= 24 ? "(flags " + BitConverter.ToUInt32(g, 20) + ")" : ""));
            }
            sb.AppendLine("  type 12 by size:" + sizes);
            lastLo = lo; lastHi = hi; lastId = id; any = true;
        }
        if (take && any) {
            int on = Set13(lastLo, lastHi, lastId, true);
            System.Threading.Thread.Sleep(3000);
            int off = Set13(lastLo, lastHi, lastId, false);
            sb.AppendLine("type 13 SET for target " + lastId + ": on -> " + on + ", back -> " + off);
        }
        return sb.ToString();
    }
}
'@
$v = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$text = "{0:s} {1} build {2}.{3}`r`n" -f (Get-Date), $v.EditionID, $v.CurrentBuild, $v.UBR
$text += [SpecProbe]::Run($Take.IsPresent)
Set-Content $Out $text
$text
