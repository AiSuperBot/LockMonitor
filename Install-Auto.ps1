<#
One-time setup of the automatic mode. Run it once from an elevated PowerShell; afterwards you only press Win+L.

What then happens at Win+L (the genuine Windows lock, not intercepted):
  1. Windows locks. Its own "workstation locked" event starts Switch-LastScreen.exe -take (elevated), which takes the
     highest-numbered screen off the desktop, using the switch behind Settings > "Remove display from desktop".
  2. Show-Dashboard.ps1 -Auto (unelevated, running since logon) sees the freed screen and redraws on it, live, the
     windows that were on it. The other screens show the normal lock screen; keyboard and mouse work there as always.
  3. At unlock it lets go, and Windows' "unlocked" event starts Switch-LastScreen.exe -give: the screen is a normal
     desktop screen again and Windows moves your windows back.

It puts two files into "%ProgramFiles%\LockMonitor" (only administrators can change files there, which matters because
one of them runs elevated): Show-Dashboard.ps1, and Switch-LastScreen.exe, built on the spot from Switch-LastScreen.cs
with the C# compiler that is part of Windows. It registers three scheduled tasks for the logged-on user:
  LockMonitor-Agent  at logon          Show-Dashboard.ps1 -Auto      normal rights
  LockMonitor-Take   at lock           Switch-LastScreen.exe -take   elevated
  LockMonitor-Give   at unlock, logon  Switch-LastScreen.exe -give   elevated
The account must be an administrator account (the usual kind with UAC prompts is fine).

Which screen: the highest-numbered one at the first Win+L after this setup, and from then on only that very monitor.
If it is switched off or unplugged when you lock, nothing stays on: the next screen in line never takes its place.
After changing monitors, run this setup again.

Two settings are changed so that whatever is on that screen keeps drawing with nothing to configure per app. Both are
remembered and put back by -Remove:
  * Windows, for that user: "Minimize windows when a monitor is disconnected" off (Settings > System > Display >
    Multiple displays). With it on, Windows minimizes the windows of the screen that leaves the desktop and there is
    nothing left to show. Windows reads it at sign-in: sign out and back in once after the first setup.
  * Chrome and Edge: their policy WindowOcclusionEnabled = 0. These browsers stop drawing windows they believe hidden,
    and they treat a locked PC that way, so their picture would freeze at the moment of locking. That is the browser's
    own decision; nothing outside it can change it per window, and this policy is its switch. The browsers then say
    "managed by your organization". Restart them once. Classic apps need nothing: they keep drawing anyway.
    Other apps built on the same engine (Electron apps) may still freeze; they have no such switch from outside.

  .\Install-Auto.ps1                 set up and start (run it again after changing monitors, or after changing these files)
  .\Install-Auto.ps1 -LeaveBrowsers  same, but do not touch the Chrome and Edge policy
  .\Install-Auto.ps1 -Remove         undo everything
Which screen it will be: "%ProgramFiles%\LockMonitor\Switch-LastScreen.exe" -list | more     (read-only)
#>
param([switch]$Remove, [switch]$LeaveBrowsers, [string]$User = (Get-CimInstance Win32_ComputerSystem).UserName)
$ErrorActionPreference = 'Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this from an elevated PowerShell (right-click > Run as administrator).' }
if (-not $User) { throw 'No user is logged on at the console; pass -User DOMAIN\name.' }
$dst = [Environment]::GetFolderPath('ProgramFiles') + '\LockMonitor'
$helper = "$dst\Switch-LastScreen.exe"
$tasks = 'LockMonitor-Agent', 'LockMonitor-Take', 'LockMonitor-Give'
$own = 'HKLM:\SOFTWARE\LockMonitor'
# that user's own settings, reachable whichever administrator account approved the elevation
$desk = 'Registry::HKEY_USERS\{0}\Control Panel\Desktop' -f (New-Object Security.Principal.NTAccount($User)).Translate([Security.Principal.SecurityIdentifier]).Value
# every setting this setup changes: where it lives, its name, the value needed, and the name its old value is remembered under
$settings = @(
    @{ Key = $desk; Name = 'MonitorRemovalRecalcBehavior'; Want = 1; Memo = 'PrevMonitorRemoval' },
    @{ Key = 'HKLM:\SOFTWARE\Policies\Google\Chrome'; Name = 'WindowOcclusionEnabled'; Want = 0; Memo = 'PrevChromeOcclusion'; Browser = $true },
    @{ Key = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'WindowOcclusionEnabled'; Want = 0; Memo = 'PrevEdgeOcclusion'; Browser = $true }
)
function Mine($name) { (Get-ItemProperty $own -Name $name -ErrorAction SilentlyContinue).$name }
function Current($s) { (Get-ItemProperty $s.Key -Name $s.Name -ErrorAction SilentlyContinue).($s.Name) }

if ($Remove) {
    foreach ($t in $tasks) { Stop-ScheduledTask $t -ErrorAction SilentlyContinue; Unregister-ScheduledTask $t -Confirm:$false -ErrorAction SilentlyContinue }
    if (Test-Path $helper) { Start-Process $helper -ArgumentList '-give' -Wait }   # never leave a screen off the desktop
    Remove-Item $dst -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($s in $settings) {   # each setting goes back to what it was before the setup; settings the setup never changed are left alone
        $was = Mine $s.Memo
        if ($was -eq 'unset') { Remove-ItemProperty $s.Key -Name $s.Name -ErrorAction SilentlyContinue }
        elseif ($null -ne $was) { Set-ItemProperty $s.Key -Name $s.Name -Value ([int]$was) -Type DWord }
    }
    Remove-Item $own -Recurse -Force -ErrorAction SilentlyContinue
    'Removed. Sign out and back in for the Windows setting, and restart Chrome and Edge, to be exactly as before.'
    return
}

if (-not (Test-Path $own)) { $null = New-Item $own }
Remove-ItemProperty $own -Name Keep -ErrorAction SilentlyContinue   # which monitor to keep is settled afresh at the next lock
$null = New-Item -ItemType Directory -Force $dst
Stop-ScheduledTask 'LockMonitor-Agent' -ErrorAction SilentlyContinue   # a second run is an update: the running agent must not go on with the old files
Copy-Item "$PSScriptRoot\Show-Dashboard.ps1" $dst -Force
# The elevated part is a small program of its own, not a script: it starts in milliseconds at every lock and depends on
# nothing a non-administrator can change. WindowsApplication = no console window flashing up at lock and unlock.
Add-Type -TypeDefinition (Get-Content "$PSScriptRoot\Switch-LastScreen.cs" -Raw) -OutputAssembly $helper -OutputType WindowsApplication

$cls = Get-CimClass -Namespace Root/Microsoft/Windows/TaskScheduler -ClassName MSFT_TaskSessionStateChangeTrigger
function OnState($s) { New-CimInstance -CimClass $cls -ClientOnly -Property @{ StateChange = $s; UserId = $User } }   # 7 = lock, 8 = unlock
$logon = New-ScheduledTaskTrigger -AtLogOn -User $User
function Reg($name, $exe, $arg, $triggers, $level, $set) {
    $act = New-ScheduledTaskAction -Execute "`"$exe`"" -Argument $arg
    $who = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel $level   # Interactive: inside the user's own session
    Register-ScheduledTask -TaskName $name -Force -Action $act -Trigger $triggers -Principal $who -Settings $set | Out-Null
}
$short = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances Queue
$long = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 99 -RestartInterval (New-TimeSpan -Minutes 1)
$ps = [Environment]::GetFolderPath('System') + '\WindowsPowerShell\v1.0\powershell.exe'
Reg 'LockMonitor-Agent' $ps "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dst\Show-Dashboard.ps1`" -Auto" $logon 'Limited' $long
Reg 'LockMonitor-Take' $helper '-take' (OnState 7) 'Highest' $short
Reg 'LockMonitor-Give' $helper '-give' @((OnState 8), $logon) 'Highest' $short   # logon too: a restart while locked must not leave the screen off the desktop

$changed = @()
foreach ($s in $settings) {
    if ($s.Browser -and $LeaveBrowsers) { continue }
    $now = Current $s
    if ($now -eq $s.Want) { continue }
    if ($null -eq (Mine $s.Memo)) { Set-ItemProperty $own -Name $s.Memo -Value $(if ($null -eq $now) { 'unset' } else { "$now" }) }   # remembered once, so a second setup run cannot overwrite the real old value
    if (-not (Test-Path $s.Key)) { $null = New-Item $s.Key -Force }
    Set-ItemProperty $s.Key -Name $s.Name -Value $s.Want -Type DWord
    $changed += $s.Memo
}
if ((Get-ItemProperty $desk -Name RestorePreviousStateRecalcBehavior -ErrorAction SilentlyContinue).RestorePreviousStateRecalcBehavior -eq 1) {
    'Note: "Remember window locations based on monitor connection" is off in Settings > System > Display > Multiple displays. With it off, your windows will not move back to the screen after unlocking.'
}
Start-ScheduledTask 'LockMonitor-Agent'
"Set up for $User. Logs: %LOCALAPPDATA%\LockMonitor\log.txt and $dst\switch.log. Undo: .\Install-Auto.ps1 -Remove"
$todo = @()
if ($changed -contains 'PrevMonitorRemoval') { $todo += 'sign out and back in once (Windows reads its "Minimize windows when a monitor is disconnected" setting, now off, only at sign-in)' }
if ($changed -match 'Occlusion') { $todo += 'restart Chrome and Edge once (they now keep drawing while the PC is locked, and will say "managed by your organization")' }
if ($todo) { 'Before the first use: ' + ($todo -join '; and ') + '. After that, just press Win+L.' } else { 'Press Win+L to use it.' }
'The screen that stays on at the first Win+L is the one kept from then on (no other screen ever takes its place). After changing monitors, run this setup again.'
