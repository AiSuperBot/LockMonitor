<#
Test-VM helper (logged-on session, unelevated): print what Show-Dashboard.ps1's -Auto mode would note about the
highest-numbered screen, redraw it once into a PNG, and say how many windows were drawn.
#>
param([string]$Out = 'C:\locktest\note.png', [string]$Dashboard)
$ErrorActionPreference = 'Stop'
if (-not $Dashboard) { $here = Split-Path $PSCommandPath; $Dashboard = "$here\Show-Dashboard.ps1", "$here\..\Show-Dashboard.ps1" | Where-Object { Test-Path $_ } | Select-Object -First 1 }
Invoke-Expression ([regex]::Match((Get-Content $Dashboard -Raw), "(?s)Add-Type -ReferencedAssemblies.*?\n'@").Value)
[Pix]::DpiAware()
$s = [Pix]::Snapshot()
if (-not $s) { 'Snapshot: null (single screen)'; return }
"screen $($s.Device) $($s.W)x$($s.H), windows: $($s.Wins.Count)"
$s.Wins | ForEach-Object { '  hwnd 0x{0:X} at {1},{2} size {3}x{4}  "{5}"' -f $_.H.ToInt64(), $_.X, $_.Y, $_.W, $_.Hgt, $_.Title }
$bmp = New-Object Frame($s.W, $s.H)
"drawn: $([Pix]::CaptureWindows($s, $bmp))"
$bmp.Gdi.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png); "saved $Out"
