<# Test-VM helper: end every running Show-Dashboard.ps1 -Auto of this user (the guest has no wmic). Prints how many. #>
$a = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*Show-Dashboard.ps1*-Auto*' })
$a | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Set-Content C:\locktest\stop-agent.txt "ended $($a.Count) agent(s)"
