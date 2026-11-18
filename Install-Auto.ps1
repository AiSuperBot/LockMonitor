<#
One-time setup. Run it once from an elevated PowerShell; afterwards you only press Win+L.

What then happens at Win+L (the genuine Windows lock, not intercepted):
  1. Windows locks. Its own "workstation locked" event starts Switch-LastScreen.exe -take (elevated), which takes one
     screen off the desktop, using the switch behind Settings > "Remove display from desktop".
  2. LockMonitor-Agent.exe (not elevated, running since sign-in) redraws on that screen, live, the windows that were on
     it. The other screens show the normal lock screen; keyboard and mouse work there as always.
  3. At unlock it lets go, and Windows' "unlocked" event starts Switch-LastScreen.exe -give: the screen is a normal
     desktop screen again and Windows moves your windows back.

Which screen: the highest-numbered one, and from then on only that very monitor. If it is switched off or unplugged
when you lock, nothing stays on: the next screen in line never takes its place. After changing monitors, run this again.

The setup puts the two programs into "%ProgramFiles%\LockMonitor" (only administrators can change files there): the
ready-built ones next to it (a release's -bin.zip), or, run from the source code, built from Agent.cs and
Switch-LastScreen.cs by Build.ps1. It registers three scheduled tasks for the signed-in user, who must be an
administrator (the usual kind with UAC prompts is fine):
  LockMonitor-Agent  at sign-in, unlock  LockMonitor-Agent.exe         normal rights (one instance; an unlock starts it only if it is not running)
  LockMonitor-Take   at lock             Switch-LastScreen.exe -take   elevated
  LockMonitor-Give   at unlock, sign-in  Switch-LastScreen.exe -give   elevated
Then it tests the whole thing once, live: that screen goes dark for a few seconds and shows a test picture. If the test
fails, everything is removed again and the reason is shown. The usual reason is the edition of Windows: only
Enterprise, Pro for Workstations and IoT Enterprise hand a screen to a program; Home and Pro refuse.

Two settings are changed so that whatever is on that screen keeps drawing with nothing to configure per app. Both are
remembered and put back by -Remove:
  * Windows, for that user: "Minimize windows when a monitor is disconnected" off (Settings > System > Display >
    Multiple displays). With it on, Windows minimizes the windows of the screen that leaves the desktop and there is
    nothing left to show. Windows reads it at sign-in: sign out and back in once after the first setup.
  * Chrome and Edge: their policy WindowOcclusionEnabled = 0. These browsers stop drawing windows they believe hidden,
    and they treat a locked PC that way. This policy is their own switch for that; they then say "managed by your
    organization". Restart them once. Apps built on the same engine (Electron) have no such switch and may freeze.

  .\Install-Auto.ps1                 set up, test, start (run it again to update, or after changing monitors)
  .\Install-Auto.ps1 -LeaveBrowsers  same, but do not touch the Chrome and Edge policy
  .\Install-Auto.ps1 -Remove         undo everything
  .\Install-Auto.ps1 -TestFrames <folder>   test machines only: the agent writes its pictures to PNG files in that folder
                                     instead of the screen (a virtual machine's display adapter cannot give a screen to a program)
#>
param([switch]$Remove, [switch]$LeaveBrowsers, [string]$TestFrames, [string]$User = (Get-CimInstance Win32_ComputerSystem).UserName)
$ErrorActionPreference = 'Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this from an elevated PowerShell (right-click > Run as administrator).' }
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { throw 'Run this from the normal PowerShell, not the "(x86)" one.' }
if (-not $User) { throw 'No user is logged on at the console; pass -User DOMAIN\name.' }
$dst = [Environment]::GetFolderPath('ProgramFiles') + '\LockMonitor'
$helper = "$dst\Switch-LastScreen.exe"; $agent = "$dst\LockMonitor-Agent.exe"
$tasks = 'LockMonitor-Agent', 'LockMonitor-Take', 'LockMonitor-Give'
$own = 'HKLM:\SOFTWARE\LockMonitor'
# that user's own settings and files, reachable whichever administrator account approved the elevation
$sid = (New-Object Security.Principal.NTAccount($User)).Translate([Security.Principal.SecurityIdentifier]).Value
$desk = "Registry::HKEY_USERS\$sid\Control Panel\Desktop"
$userDir = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid").ProfileImagePath + '\AppData\Local\LockMonitor'   # the agent's log: only read from here, never written or deleted
# every setting this setup changes: where it lives, its name, the value needed, and the name its old value is remembered under
$settings = @(
    @{ Key = $desk; Name = 'MonitorRemovalRecalcBehavior'; Want = 1; Memo = 'PrevMonitorRemoval' },
    @{ Key = 'HKLM:\SOFTWARE\Policies\Google\Chrome'; Name = 'WindowOcclusionEnabled'; Want = 0; Memo = 'PrevChromeOcclusion'; Browser = $true },
    @{ Key = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'WindowOcclusionEnabled'; Want = 0; Memo = 'PrevEdgeOcclusion'; Browser = $true }
)
function Mine($name) { (Get-ItemProperty $own -Name $name -ErrorAction SilentlyContinue).$name }
function Current($s) { (Get-ItemProperty $s.Key -Name $s.Name -ErrorAction SilentlyContinue).($s.Name) }
function Stop-Agent {
    Stop-ScheduledTask 'LockMonitor-Agent' -ErrorAction SilentlyContinue
    Get-Process LockMonitor-Agent -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    # up to version 0.1.3 the agent was a PowerShell script behind a console host, which a stopped task leaves running
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like "*$dst\Show-Dashboard.ps1*-Auto*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}
function Uninstall {
    Stop-Agent
    foreach ($t in $tasks) { Stop-ScheduledTask $t -ErrorAction SilentlyContinue; Unregister-ScheduledTask $t -Confirm:$false -ErrorAction SilentlyContinue }
    if (Test-Path $helper) { Start-Process $helper -ArgumentList '-give' -Wait }   # never leave a screen off the desktop
    Remove-Item $dst -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($s in $settings) {   # each setting goes back to what it was before the setup; settings the setup never changed are left alone
        $was = Mine $s.Memo
        if ($was -eq 'unset') { Remove-ItemProperty $s.Key -Name $s.Name -ErrorAction SilentlyContinue }
        elseif ($null -ne $was) { Set-ItemProperty $s.Key -Name $s.Name -Value ([int]$was) -Type DWord }
    }
    Remove-Item $own -Recurse -Force -ErrorAction SilentlyContinue
}

if ($Remove) {
    Uninstall
    # The agent's log is left alone. This script runs elevated, and that folder is the user's to change: an elevated
    # delete there follows a junction the user may have put in its place, into folders the user cannot touch (measured
    # in the test VM with version 0.2.2, which deleted it here).
    'Removed. Sign out and back in for the Windows setting, and restart Chrome and Edge, to be exactly as before.'
    "The log stays in $userDir; delete it if you like."
    return
}

if (-not (Test-Path $own)) { $null = New-Item $own }
Remove-ItemProperty $own -Name Keep -ErrorAction SilentlyContinue   # which monitor to keep is settled afresh, by the test below or the next lock
$null = New-Item -ItemType Directory -Force $dst
Stop-Agent   # a second run is an update: the running agent must not go on with the old files
Remove-Item "$dst\Show-Dashboard.ps1" -ErrorAction SilentlyContinue   # the agent of versions up to 0.1.3

# The two programs: the ready-built ones next to this script (a release's -bin.zip), or else built here from the
# sources next to it (the source code), by Build.ps1.
$ready = (Test-Path "$PSScriptRoot\LockMonitor-Agent.exe") -and (Test-Path "$PSScriptRoot\Switch-LastScreen.exe")
if ($ready) { Copy-Item "$PSScriptRoot\LockMonitor-Agent.exe", "$PSScriptRoot\Switch-LastScreen.exe" $dst -Force }
else { $null = & "$PSScriptRoot\Build.ps1" -Out $dst }
$version = (Get-Item $agent).VersionInfo.FileVersion

$cls = Get-CimClass -Namespace Root/Microsoft/Windows/TaskScheduler -ClassName MSFT_TaskSessionStateChangeTrigger
function OnState($s) { New-CimInstance -CimClass $cls -ClientOnly -Property @{ StateChange = $s; UserId = $User } }   # 7 = lock, 8 = unlock
$logon = New-ScheduledTaskTrigger -AtLogOn -User $User
function Reg($name, $exe, $arg, $triggers, $level, $set) {
    $act = if ($arg) { New-ScheduledTaskAction -Execute "`"$exe`"" -Argument $arg } else { New-ScheduledTaskAction -Execute "`"$exe`"" }
    $who = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel $level   # Interactive: inside the user's own session
    Register-ScheduledTask -TaskName $name -Force -Action $act -Trigger $triggers -Principal $who -Settings $set | Out-Null
}
$short = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances Queue
$long = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
# At every unlock too: Windows does not restart an agent that died (measured), so each unlock starts it if it is not
# running; while it is running, the extra start is ignored.
Reg 'LockMonitor-Agent' $agent $(if ($TestFrames) { "-frames `"$TestFrames`"" }) @($logon, (OnState 8)) 'Limited' $long
Reg 'LockMonitor-Take' $helper '-take' (OnState 7) 'Highest' $short
Reg 'LockMonitor-Give' $helper '-give' @((OnState 8), $logon) 'Highest' $short   # sign-in too: a restart while locked must not leave the screen off the desktop

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
Start-ScheduledTask 'LockMonitor-Agent'

# The live test: the helper takes the screen as it will at Win+L, the agent shows a text on it for a few seconds (it
# does so because of the note "Check", which only administrators can leave), and the helper puts the screen back.
$os = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
"Windows: $((Get-CimInstance Win32_OperatingSystem).Caption), edition $($os.EditionID), build $($os.CurrentBuild)"
'Testing: the highest-numbered screen goes dark for a few seconds and shows a test picture. Its windows move away and come back.'
Start-Sleep 1   # the agent has to be up and waiting
$start = (Get-Date).ToString('s')   # both logs start every line with this kind of time stamp
function Since($file) { if (Test-Path $file) { @(Get-Content $file | Where-Object { $_.Length -ge 19 -and $_.Substring(0, 19) -ge $start }) } }   # robust against the logs being trimmed meanwhile
Set-ItemProperty $own -Name Check -Value 1 -Type DWord
$taken = $false; $verdict = $null
try {
    Start-Process $helper -ArgumentList '-take -force' -Wait
    $taken = [bool](Mine 'Taken')
    for ($i = 0; $taken -and -not $verdict -and $i -lt 80; $i++) {   # the agent gives up after 12 s; allow 20
        Start-Sleep -Milliseconds 250
        $verdict = Since "$userDir\log.txt" | Where-Object { $_ -match ' check: ' } | Select-Object -Last 1
    }
    if ($verdict -match 'is on the screen') { Start-Sleep 4 }   # leave it there long enough to be seen
} finally {
    Start-Process $helper -ArgumentList '-give' -Wait
    Remove-ItemProperty $own -Name Check -ErrorAction SilentlyContinue
}
$why = if ($verdict) { $verdict -replace '^.* check: ' } elseif ($taken) { 'the agent did not answer' }
       else { (Since "$dst\switch.log" | Select-Object -Last 1) -replace '^\S+ (take: )?' }
if (-not $why) { $why = 'the helper did not take the screen, and its log does not say why' }
if ($verdict -match 'is on the screen') { "Test passed: $why. That screen is the one kept at Win+L." }
elseif (-not $taken -and $why -match 'nothing to keep') {
    "Not tested: $why. It stays set up; run this again when all screens are connected, to have it tested."
} else {
    Uninstall
    "Test FAILED: $($why.TrimEnd('.'))."
    if ($why -match 'TargetAccessDenied') { 'Windows refuses to hand the screen to a program. Windows Home and Pro do that; it takes the Enterprise, Pro for Workstations or IoT Enterprise edition.' }
    'Nothing is left installed.'
    return
}
if ((Get-ItemProperty $desk -Name RestorePreviousStateRecalcBehavior -ErrorAction SilentlyContinue).RestorePreviousStateRecalcBehavior -eq 1) {
    'Note: "Remember window locations based on monitor connection" is off in Settings > System > Display > Multiple displays. With it off, your windows will not move back to the screen after unlocking.'
}
"Set up LockMonitor $version for $User ($(if ($ready) { 'the ready-built programs' } else { 'built here from the sources' })). Logs: %LOCALAPPDATA%\LockMonitor\log.txt and $dst\switch.log. Undo: .\Install-Auto.ps1 -Remove"
$todo = @()
if ($changed -contains 'PrevMonitorRemoval') { $todo += 'sign out and back in once (Windows reads its "Minimize windows when a monitor is disconnected" setting, now off, only at sign-in)' }
if ($changed -match 'Occlusion') { $todo += 'restart Chrome and Edge once (they now keep drawing while the PC is locked, and will say "managed by your organization")' }
if ($todo) { 'Before the first use: ' + ($todo -join '; and ') + '. After that, just press Win+L.' } else { 'Press Win+L to use it.' }
