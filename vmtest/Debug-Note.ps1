<#
Test-VM helper (logged-on session, unelevated): print what the agent would note about the highest-numbered screen,
redraw it once into a PNG, and say how many windows were drawn. Uses the installed agent's own code.
#>
param([string]$Out = 'C:\locktest\note.png', [string]$Agent = "$env:ProgramFiles\LockMonitor\LockMonitor-Agent.exe")
$ErrorActionPreference = 'Stop'
$null = [Reflection.Assembly]::UnsafeLoadFrom($Agent)   # not LoadFile: an agent installed from a downloaded zip carries the "from the internet" mark, which LoadFile refuses
[Pix]::DpiAware()
$s = [Pix]::Snapshot($null)
if (-not $s) { 'Snapshot: null (single screen)'; return }
"screen $($s.Device) $($s.W)x$($s.H), windows: $($s.Wins.Count)"
$s.Wins | ForEach-Object { '  hwnd 0x{0:X} at {1},{2} size {3}x{4}  "{5}"' -f $_.H.ToInt64(), $_.X, $_.Y, $_.W, $_.Hgt, $_.Title }
$f = New-Object Frame($s.W, $s.H)
"drawn: $([Pix]::CaptureWindows($s, $f))"
$f.Gdi.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png); "saved $Out"
