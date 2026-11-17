<# Test-VM helper: what the waiting agent costs: CPU time over a while, and memory. #>
param([int]$Seconds = 60, [string]$Out = 'C:\locktest\agent-cost.txt')
$rows = Get-Process LockMonitor-Agent -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ P = $_; Cpu = $_.TotalProcessorTime } }
if (-not $rows) { Set-Content $Out 'no agent is running'; return }
Start-Sleep $Seconds
$(foreach ($r in $rows) {
    $r.P.Refresh()
    if ($r.P.HasExited) { "pid $($r.P.Id): ended meanwhile"; continue }
    'pid {0}: CPU {1:N2} ms per second over {2} s; working set {3:N0} MB, private {4:N0} MB, handles {5}, threads {6}' -f $r.P.Id,
        (($r.P.TotalProcessorTime - $r.Cpu).TotalMilliseconds / $Seconds), $Seconds, ($r.P.WorkingSet64 / 1MB), ($r.P.PrivateMemorySize64 / 1MB), $r.P.HandleCount, $r.P.Threads.Count
}) | Set-Content $Out
