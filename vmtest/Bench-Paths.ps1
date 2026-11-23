# Test-VM helper (logged-on session): A/B of the picture path. One picture of the kept screen's windows, drawn into a picture with a
# margin (bottom window straight in) and into one without (every window through the scratch bitmap), alternating.
param([string]$Out = 'C:\locktest\bench-paths.txt', [string]$Agent = "$env:ProgramFiles\LockMonitor\LockMonitor-Agent.exe", [int]$Rounds = 8, [int]$N = 15)
$null = [Reflection.Assembly]::UnsafeLoadFrom($Agent)
$copy = "$env:TEMP\LockMonitor-Agent-bench3.dll"; Copy-Item $Agent $copy -Force
Add-Type -ReferencedAssemblies $copy -TypeDefinition @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices;
public static class Paths {
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentThread();
    [DllImport("kernel32.dll")] static extern bool QueryThreadCycleTime(IntPtr h, out ulong c);
    static ulong Now() { ulong c; QueryThreadCycleTime(GetCurrentThread(), out c); return c; }
    static double Cost(Pix.Snap s, Frame f, int n) { Pix.CaptureWindows(s, f); ulong c0 = Now(); for (int i = 0; i < n; i++) Pix.CaptureWindows(s, f); return (Now() - c0) / (double)n / 1e6; }
    public static string[] Run(int rounds, int n) {
        Pix.DpiAware();
        Pix.Snap s = Pix.Snapshot(null);
        List<string> rows = new List<string>(); double a = 0, b = 0;
        using (Frame direct = new Frame(s.W, s.H, Frame.Room)) using (Frame plain = new Frame(s.W, s.H)) {
            for (int r = 0; r < rounds; r++) {
                double x = Cost(s, direct, n), y = Cost(s, plain, n); a += x; b += y;
                rows.Add(string.Format("round {0}: straight in {1:N2} M cycles, through scratch {2:N2} M cycles", r, x, y));
            }
        }
        rows.Add(string.Format("mean: straight in {0:N2}, through scratch {1:N2} M cycles per picture ({2} window(s))", a / rounds, b / rounds, s.Wins.Count));
        return rows.ToArray();
    }
}
'@
[Paths]::Run($Rounds, $N) | Set-Content $Out
