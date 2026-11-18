<#
Lock probe for the test VM (logged-on session, unelevated; start it before the lock): every 2 s, the lock flag, the
note the helper holds, what the helper sees on the desktop, and how Windows reports every connected display target.
Made to follow a screen that is unplugged while the helper holds it off the desktop.   Log: C:\locktest\unplug-probe.log
#>
param([int]$Seconds = 120, [string]$Dir = 'C:\locktest', [string]$Agent = "$env:ProgramFiles\LockMonitor\LockMonitor-Agent.exe")
$ErrorActionPreference = 'Stop'
$null = [Reflection.Assembly]::LoadFile($Agent)
$null = [Windows.Devices.Display.Core.DisplayManager, Windows.Devices.Display.Core, ContentType=WindowsRuntime]
$Log = "$Dir\unplug-probe.log"
for ($end = (Get-Date).AddSeconds($Seconds); (Get-Date) -lt $end; Start-Sleep 2) {
    $dm = [Windows.Devices.Display.Core.DisplayManager]::Create('None')
    # connected targets only: an unplugged screen simply drops out of the row
    $targets = ($dm.GetCurrentTargets() | Where-Object IsConnected | ForEach-Object { 'target {0}: {1} {2}' -f $_.AdapterRelativeId, $_.UsageKind, ([Common]::Describe($_.Adapter.Id.LowPart, $_.Adapter.Id.HighPart, $_.AdapterRelativeId) -replace ';.*$') }) -join '; '
    $dm.Dispose()
    $desk = (& "$env:ProgramFiles\LockMonitor\Switch-LastScreen.exe" -list | Out-String).Trim() -replace ';.*$'
    Add-Content $Log ('{0:HH:mm:ss} flag={1} note={2} | {3} | {4}' -f (Get-Date), [Common]::SessionFlag(), ([Common]::Taken() -replace '\|\\\\\?.*$'), $desk, $targets)
}
Add-Content $Log ('{0:HH:mm:ss} end' -f (Get-Date))
