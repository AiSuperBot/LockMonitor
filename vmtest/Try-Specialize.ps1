<#
Test-VM helper (run elevated in the desktop session): try parameter combinations of DISPLAYCONFIG_SET_MONITOR_SPECIALIZATION
on one monitor and print the Win32 result of each, to learn what the API accepts. Stops a direction at the first success.
  .\Try-Specialize.ps1 -Index 1
#>
param([int]$Index = 1)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition (([regex]::Match((Get-Content "$PSScriptRoot\Set-Specialized.ps1" -Raw), "(?s)using System; using System.Runtime.InteropServices;.*?\n(?='@)")).Value)
$null = [Windows.Devices.Display.Core.DisplayManager, Windows.Devices.Display.Core, ContentType=WindowsRuntime]
$dm = [Windows.Devices.Display.Core.DisplayManager]::Create('None')
$t = @($dm.GetCurrentTargets() | Where-Object IsConnected)[$Index]
$lo = $t.Adapter.Id.LowPart; $hi = $t.Adapter.Id.HighPart; $id = $t.AdapterRelativeId
"target [$Index] relId=$id  " + [SpecApi]::Get($lo, $hi, $id)
$pseudo = [guid]'f196c02f-f86f-4f9a-aa15-e9cebdfe3b96'; $none = [guid]::Empty
$combos = foreach ($type in $none, $pseudo) { foreach ($sub in $none, $pseudo) { foreach ($app in '', 'LockMonitor') { , @($type, $sub, $app) } } }
foreach ($on in $false, $true) {
    foreach ($c in $combos) {
        $rc = [SpecApi]::Set($lo, $hi, $id, $on, $c[0], $c[1], $c[2])
        '{0,-3} type={1,-6} sub={2,-6} app={3,-11} -> {4}' -f $(if ($on) { 'ON' } else { 'OFF' }), $(if ($c[0] -eq $none) { 'empty' } else { 'PSEUDO' }), $(if ($c[1] -eq $none) { 'empty' } else { 'PSEUDO' }), "'$($c[2])'", $rc
        if ($rc -eq 0) { Start-Sleep 3; '    now: ' + [SpecApi]::Get($lo, $hi, $id); break }
    }
}
$dm.Dispose()
