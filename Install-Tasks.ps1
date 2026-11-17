<#
Registers two per-user tasks. No admin and no audit policy needed: they use Task Scheduler's own lock/unlock triggers.
  LockMonitor-Lock    on workstation lock              -> Set-LockMonitor.ps1 -Action Lock -KioskInput <n>
  LockMonitor-Unlock  on workstation unlock + on logon -> Set-LockMonitor.ps1 -Action Unlock
                      (logon too, so a reboot while locked cannot leave the panel stuck on the kiosk input)
Run the manual Lock/Unlock round trip from Set-LockMonitor.ps1 first.
Remove: Unregister-ScheduledTask LockMonitor-Lock, LockMonitor-Unlock -Confirm:$false
#>
param([Parameter(Mandatory)][uint32]$KioskInput)
$ErrorActionPreference = 'Stop'
$dir = "$env:LOCALAPPDATA\LockMonitor"
New-Item -ItemType Directory -Force $dir | Out-Null
Copy-Item "$PSScriptRoot\Set-LockMonitor.ps1" $dir -Force   # tasks run this private copy, not a folder other users may be able to write to

$me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$cls = Get-CimClass -Namespace Root/Microsoft/Windows/TaskScheduler -ClassName MSFT_TaskSessionStateChangeTrigger
function OnState($s) { New-CimInstance -CimClass $cls -ClientOnly -Property @{ StateChange = $s; UserId = $me } }   # 7 = lock, 8 = unlock
$who = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited   # must run in the user's session, not session 0
$set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 1)

function Reg($name, $scriptArgs, $triggers) {
    # through "conhost --headless": where Windows Terminal is the console host, -WindowStyle Hidden alone still pops up a window (measured).
    # Full paths: a task that is stored and started at every lock must not depend on the search path.
    $sys = [Environment]::GetFolderPath('System')
    $act = New-ScheduledTaskAction -Execute "`"$sys\conhost.exe`"" -Argument "--headless `"$sys\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dir\Set-LockMonitor.ps1`" $scriptArgs"
    Register-ScheduledTask -TaskName $name -Force -Action $act -Trigger $triggers -Principal $who -Settings $set | Out-Null
}
Reg LockMonitor-Lock "-Action Lock -KioskInput $KioskInput" (OnState 7)
Reg LockMonitor-Unlock '-Action Unlock' @((OnState 8), (New-ScheduledTaskTrigger -AtLogOn -User $me))
'Registered LockMonitor-Lock and LockMonitor-Unlock. Log: {0}\log.txt' -f $dir
