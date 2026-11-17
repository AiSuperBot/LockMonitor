<# Test-VM helper: what the waiting automatic-mode agent (Show-Dashboard.ps1 -Auto) costs: CPU time over a while, and memory. #>
param([int]$Seconds = 60, [string]$Out = 'C:\locktest\agent-cost.txt')
$rows = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*Show-Dashboard.ps1*-Auto*' } |
    ForEach-Object { $p = Get-Process -Id $_.ProcessId; [pscustomobject]@{ P = $p; Cpu = $p.TotalProcessorTime } }
if (-not $rows) { Set-Content $Out 'no agent is running'; return }
Start-Sleep $Seconds
$(foreach ($r in $rows) {
    $r.P.Refresh()
    'pid {0}: CPU {1:N2} ms per second over {2} s; working set {3:N0} MB, private {4:N0} MB, handles {5}, threads {6}' -f $r.P.Id,
        (($r.P.TotalProcessorTime - $r.Cpu).TotalMilliseconds / $Seconds), $Seconds, ($r.P.WorkingSet64 / 1MB), ($r.P.PrivateMemorySize64 / 1MB), $r.P.HandleCount, $r.P.Threads.Count
}) | Set-Content $Out
