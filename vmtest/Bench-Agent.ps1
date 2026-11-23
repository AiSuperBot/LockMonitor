<# Test-VM helper (logged-on session, unelevated): what each recurring call of the installed agent costs, in CPU cycles
   of this thread (QueryThreadCycleTime) and microseconds: the lock flag, the helper's note, a window note (Snapshot).
   Calls the agent's own code from a compiled loop (a PowerShell loop costs more than the calls). Log: -Out #>
param([string]$Out = 'C:\locktest\bench.txt', [string]$Agent = "$env:ProgramFiles\LockMonitor\LockMonitor-Agent.exe", [int]$N = 300)
$asm = [Reflection.Assembly]::UnsafeLoadFrom($Agent)   # not LoadFile: an agent from a downloaded zip carries the "from the internet" mark
$copy = "$env:TEMP\LockMonitor-Agent-bench.dll"; Copy-Item $Agent $copy -Force   # Add-Type wants a reference it may read; the loaded one is the same code
Add-Type -ReferencedAssemblies $copy, System.Drawing -TypeDefinition @'
using System; using System.Diagnostics; using System.Runtime.InteropServices;
public static class Bench {
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentThread();
    [DllImport("kernel32.dll")] static extern bool QueryThreadCycleTime(IntPtr h, out ulong c);
    static ulong Now() { ulong c; QueryThreadCycleTime(GetCurrentThread(), out c); return c; }
    public static string Time(string name, Action a, int n) {
        a();   // first-call costs do not count
        Stopwatch sw = Stopwatch.StartNew(); ulong c0 = Now();
        for (int i = 0; i < n; i++) a();
        ulong c = (Now() - c0) / (ulong)n;
        return string.Format("{0,-20} {1,10:N0} cycles {2,8:N1} us per call", name, c, sw.Elapsed.TotalMilliseconds * 1000 / n);
    }
    // one picture as at a lock: every noted window captured into the screen-sized frame, then the changed rows found
    static string Picture(Pix.Snap s, int n) {
        if (s == null || s.Wins.Count == 0) return "picture: no window on the screen";
        using (Frame f = new Frame(s.W, s.H, Frame.Room)) {   // as at a lock
            int top, bottom;
            return Time("picture: capture " + s.Wins.Count + " win", () => Pix.CaptureWindows(s, f), n) + "\n" + Time("picture: changed rows", () => f.Changed(out top, out bottom), n);
        }
    }
    public static string[] All(int n) {
        Pix.DpiAware();
        Pix.Snap s = Pix.Snapshot(null);
        return new[] {
            Time("Common.Locked()", () => Common.Locked(), n),
            Time("Common.Taken()", () => Common.Taken(), n),
            Time("Pix.Snapshot(null)", () => Pix.Snapshot(null), n),
            Time("Pix.Snapshot(last)", () => { s = Pix.Snapshot(s); }, n),
            Picture(s, n / 10),
            "Snapshot: " + (s == null ? "none" : s.Device + ", " + s.Wins.Count + " window(s)")
        };
    }
}
'@
[Bench]::All($N) | Set-Content $Out
Get-Content $Out
