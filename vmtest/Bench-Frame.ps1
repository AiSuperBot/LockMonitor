<#
Test helper, safe on any PC (draws nothing on the screen, needs no lock): what the agent's picture buffer costs at a
given size. Change detection (Frame.Changed) per picture, in CPU cycles and microseconds, for a picture that did not
change, one with a band of rows changed (a clock), and one with every row changed (an animation); and the process's
private memory with the picture held. Calls the agent's own code. Log: -Out
  .\Bench-Frame.ps1 -Agent bin\LockMonitor-Agent.exe -W 1920 -H 1080
#>
param([string]$Agent = "$env:ProgramFiles\LockMonitor\LockMonitor-Agent.exe", [int]$W = 1920, [int]$H = 1080, [int]$N = 200, [string]$Out)
$null = [Reflection.Assembly]::UnsafeLoadFrom($Agent)
$copy = "$env:TEMP\LockMonitor-Agent-bench-$PID.dll"; Copy-Item $Agent $copy -Force
Add-Type -ReferencedAssemblies $copy -TypeDefinition @'
using System; using System.Diagnostics; using System.Runtime.InteropServices;
public static class BenchFrame {
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentThread();
    [DllImport("kernel32.dll")] static extern bool QueryThreadCycleTime(IntPtr h, out ulong c);
    static ulong Cycles() { ulong c; QueryThreadCycleTime(GetCurrentThread(), out c); return c; }
    static long Private() { using (Process p = Process.GetCurrentProcess()) return p.PrivateMemorySize64; }
    // touch: rows [from, to) get one pixel changed each time
    static string Time(Frame f, string name, int from, int to, int n) {
        int top, bottom; int k = 0;
        f.Changed(out top, out bottom);   // settle: the same picture as last time
        Stopwatch sw = Stopwatch.StartNew(); ulong c0 = Cycles(); int reported = 0;
        for (int i = 0; i < n; i++) {
            k++;
            for (int y = from; y < to; y++) Marshal.WriteInt32(f.Bits, y * f.Stride + ((y * 7) % f.W) * 4, (k << 16) ^ y);
            if (f.Changed(out top, out bottom)) reported += bottom - top;
        }
        ulong c = (Cycles() - c0) / (ulong)n;
        return string.Format("{0,-26} {1,12:N0} cycles {2,8:N0} us per picture, {3} rows reported on average", name, c, sw.Elapsed.TotalMilliseconds * 1000 / n, reported / n);
    }
    public static string[] All(int w, int h, int n) {
        GC.Collect(); GC.WaitForPendingFinalizers();
        long before = Private();
        using (Frame f = new Frame(w, h)) {
            f.Clear();
            int top, bottom; f.Changed(out top, out bottom);   // first call: all rows, and whatever state it keeps
            long held = Private();
            return new[] {
                string.Format("picture {0}x{1}: private memory +{2:N1} MB while held (picture and change-detection state)", w, h, (held - before) / 1048576.0),
                Time(f, "nothing changed", 0, 0, n),
                Time(f, "a band of 40 rows changed", h / 2, h / 2 + 40, n),
                Time(f, "every row changed", 0, h, n)
            };
        }
    }
}
'@
$r = [BenchFrame]::All($W, $H, $N)
if ($Out) { $r | Set-Content $Out }
$r
