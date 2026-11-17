<#
Lock probe for the test VM (run in the logged-on user's session, unelevated).
Question: does the power request Show-Dashboard.ps1 holds (keep the PC and the displays on) stop Windows from switching
the displays off while the workstation is LOCKED (Windows does that 60 s after locking by default)?
It uses the product's own Pwr class. Watch the VM screen from the host: still showing the lock screen = displays on.
  .\Probe-Power.ps1 -Seconds 150              hold the request
  .\Probe-Power.ps1 -Seconds 150 -NoRequest   baseline: hold nothing
#>
param([int]$Seconds = 150, [switch]$NoRequest, [string]$Dir = 'C:\locktest', [string]$Dashboard)
$ErrorActionPreference = 'Stop'
if (-not $Dashboard) { $here = Split-Path $PSCommandPath; $Dashboard = "$here\Show-Dashboard.ps1", "$here\..\Show-Dashboard.ps1" | Where-Object { Test-Path $_ } | Select-Object -First 1 }
Invoke-Expression ([regex]::Match((Get-Content $Dashboard -Raw), "(?s)Add-Type -ReferencedAssemblies.*?\n'@").Value)
$Log = "$Dir\power.log"
$held = if ($NoRequest) { 'none' } else { 'system+display accepted=' + [Pwr]::Keep($true, $true) }
Add-Content $Log ('{0:HH:mm:ss} start: request {1}' -f (Get-Date), $held)
for ($end = (Get-Date).AddSeconds($Seconds); (Get-Date) -lt $end; Start-Sleep 5) { Add-Content $Log ('{0:HH:mm:ss} session={1}' -f (Get-Date), [Pix]::SessionState()) }
if (-not $NoRequest) { $null = [Pwr]::Keep($false, $false) }
Add-Content $Log ('{0:HH:mm:ss} end' -f (Get-Date))
