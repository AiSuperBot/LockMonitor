# Test-VM helper: CPU cycles per thread of the running agent over -Seconds, to see where the waiting cost goes.
param([int]$Seconds = 60, [string]$Out = 'C:\locktest\thread-cycles.txt')
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class Thr {
    [DllImport("kernel32.dll")] public static extern IntPtr OpenThread(uint access, bool inherit, uint id);
    [DllImport("kernel32.dll")] public static extern bool QueryThreadCycleTime(IntPtr h, out ulong c);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    public static ulong Cycles(int id) { IntPtr h = OpenThread(0x0800, false, (uint)id); if (h == IntPtr.Zero) return 0; ulong c; QueryThreadCycleTime(h, out c); CloseHandle(h); return c; }
}
'@
$p = Get-Process LockMonitor-Agent | Select-Object -First 1
$before = @{}; foreach ($t in $p.Threads) { $before[$t.Id] = [Thr]::Cycles($t.Id) }
Start-Sleep $Seconds
$p.Refresh()
$rows = foreach ($t in $p.Threads) {
    $c = [Thr]::Cycles($t.Id); $b = if ($before.ContainsKey($t.Id)) { $before[$t.Id] } else { 0 }
    [pscustomobject]@{ Id = $t.Id; PerSecond = [math]::Round(($c - $b) / 1e6 / $Seconds, 3); Start = $t.StartAddress; State = $t.ThreadState; Wait = $t.WaitReason }
}
$rows | Sort-Object PerSecond -Descending | Format-Table -AutoSize | Out-String -Width 200 | Set-Content $Out
