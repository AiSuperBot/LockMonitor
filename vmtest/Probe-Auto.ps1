<#
Lock probe for the test VM (logged-on session, unelevated): follow the windows of the highest-numbered screen through
a lock in which Switch-LastScreen.exe takes that screen off the desktop. Every 2 s, per window: where Windows has it
now, whether it is minimized, and how much picture the product's capture call returns (lit = non-black sample pixels).
  .\Probe-Auto.ps1 -Seconds 90        log: C:\locktest\auto-probe.log
#>
param([int]$Seconds = 90, [string]$Dir = 'C:\locktest', [string]$Dashboard)
$ErrorActionPreference = 'Stop'
if (-not $Dashboard) { $here = Split-Path $PSCommandPath; $Dashboard = "$here\Show-Dashboard.ps1", "$here\..\Show-Dashboard.ps1" | Where-Object { Test-Path $_ } | Select-Object -First 1 }
Invoke-Expression ([regex]::Match((Get-Content $Dashboard -Raw), "(?s)Add-Type -ReferencedAssemblies.*?\n'@").Value)
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class Wq {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int v, int size);
}
'@
[Pix]::DpiAware()
$Log = "$Dir\auto-probe.log"
$note = $null
$bmp = New-Object Frame(640, 400)
for ($end = (Get-Date).AddSeconds($Seconds); (Get-Date) -lt $end; Start-Sleep 2) {
    $state = [Pix]::SessionState()
    if ($state -ne 'LOCKED') { $s = [Pix]::Snapshot(); if ($s -and $s.Wins.Count) { $note = $s } }
    $row = '{0:HH:mm:ss} {1,-8} screens={2}' -f (Get-Date), $state, [System.Windows.Forms.Screen]::AllScreens.Count
    if ($note) {
        foreach ($w in $note.Wins) {
            $r = New-Object Wq+RECT; $null = [Wq]::GetWindowRect($w.H, [ref]$r); $cl = 0; $null = [Wq]::DwmGetWindowAttribute($w.H, 14, [ref]$cl, 4)
            $st = [Pix]::CaptureWindow($w.H, $bmp); $lit = 0
            if ($st -eq 'ok') { for ($x = 0; $x -lt 640; $x += 16) { for ($y = 0; $y -lt 400; $y += 16) { $p = $bmp.Gdi.GetPixel($x, $y); if ($p.R + $p.G + $p.B -gt 24) { $lit++ } } } }
            $row += ' | 0x{0:X}: at {1},{2} {3}x{4} min={5} vis={6} cloak={7} cap={8} lit={9}' -f $w.H.ToInt64(), $r.l, $r.t, ($r.r - $r.l), ($r.b - $r.t), [Wq]::IsIconic($w.H), [Wq]::IsWindowVisible($w.H), $cl, $st, $lit
        }
    }
    Add-Content $Log $row
}
Add-Content $Log ('{0:HH:mm:ss} end' -f (Get-Date))
