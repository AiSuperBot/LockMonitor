<#
Lock probe for the test VM (logged-on session, unelevated; start it before the lock): every 2 s, the lock state, the
note the helper holds, what the helper sees on the desktop, and how Windows reports every display target. Made to
follow a screen that is unplugged while the helper holds it off the desktop.   Log: C:\locktest\unplug-probe.log
#>
param([int]$Seconds = 120, [string]$Dir = 'C:\locktest', [string]$Dashboard)
$ErrorActionPreference = 'Stop'
if (-not $Dashboard) { $here = Split-Path $PSCommandPath; $Dashboard = "$here\Show-Dashboard.ps1", "$here\..\Show-Dashboard.ps1" | Where-Object { Test-Path $_ } | Select-Object -First 1 }
Invoke-Expression ([regex]::Match((Get-Content $Dashboard -Raw), "(?s)Add-Type -ReferencedAssemblies.*?\n'@").Value)
$null = [Windows.Devices.Display.Core.DisplayManager, Windows.Devices.Display.Core, ContentType=WindowsRuntime]
$Log = "$Dir\unplug-probe.log"
for ($end = (Get-Date).AddSeconds($Seconds); (Get-Date) -lt $end; Start-Sleep 2) {
    $dm = [Windows.Devices.Display.Core.DisplayManager]::Create('None')
    # connected targets only: an unplugged screen simply drops out of the row
    $targets = ($dm.GetCurrentTargets() | Where-Object IsConnected | ForEach-Object { 'target {0}: {1} {2}' -f $_.AdapterRelativeId, $_.UsageKind, ([Spec]::Get($_.Adapter.Id.LowPart, $_.Adapter.Id.HighPart, $_.AdapterRelativeId) -replace ' available.*$') }) -join '; '
    $dm.Dispose()
    $desk = (& 'C:\Program Files\LockMonitor\Switch-LastScreen.exe' -list | Out-String).Trim() -replace ';.*$'
    Add-Content $Log ('{0:HH:mm:ss} {1,-8} note={2,-24} | {3} | {4}' -f (Get-Date), [Pix]::SessionState(), [Pix]::Taken(), $desk, $targets)
}
Add-Content $Log ('{0:HH:mm:ss} end' -f (Get-Date))
