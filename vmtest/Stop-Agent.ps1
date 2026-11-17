<# Test-VM helper: end every running agent of this user. Says how many in C:\locktest\stop-agent.txt. #>
$a = @(Get-Process LockMonitor-Agent -ErrorAction SilentlyContinue)
$a | Stop-Process -Force
Set-Content C:\locktest\stop-agent.txt "ended $($a.Count) agent(s)"
