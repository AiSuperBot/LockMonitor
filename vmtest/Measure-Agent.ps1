<# Test-VM helper: what the agent costs over a while: CPU time (the scheduler's, in 15.6 ms steps), CPU cycles (exact:
   QueryProcessCycleTime) and memory. Start it while the PC is unlocked for the waiting cost, or before a lock (-Seconds
   long enough) for the cost of showing pictures. #>
param([int]$Seconds = 60, [string]$Out = 'C:\locktest\agent-cost.txt')
Add-Type 'using System; using System.Runtime.InteropServices; public static class Cyc { [DllImport("kernel32.dll")] public static extern bool QueryProcessCycleTime(IntPtr h, out ulong c); }'
function Cycles($p) { $c = [uint64]0; $null = [Cyc]::QueryProcessCycleTime($p.Handle, [ref]$c); $c }
$rows = Get-Process LockMonitor-Agent -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ P = $_; Cpu = $_.TotalProcessorTime; Cyc = (Cycles $_) } }
if (-not $rows) { Set-Content $Out 'no agent is running'; return }
Start-Sleep $Seconds
$(foreach ($r in $rows) {
    $r.P.Refresh()
    if ($r.P.HasExited) { "pid $($r.P.Id): ended meanwhile"; continue }
    'pid {0} over {1} s: CPU {2:N2} ms per second, {3:N2} million cycles per second; working set {4:N0} MB, private {5:N0} MB, handles {6}, threads {7}' -f $r.P.Id, $Seconds,
        (($r.P.TotalProcessorTime - $r.Cpu).TotalMilliseconds / $Seconds), (((Cycles $r.P) - $r.Cyc) / 1e6 / $Seconds),
        ($r.P.WorkingSet64 / 1MB), ($r.P.PrivateMemorySize64 / 1MB), $r.P.HandleCount, $r.P.Threads.Count
}) | Set-Content $Out
