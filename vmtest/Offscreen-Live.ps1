<#
Test-VM helper (logged-on session, unlocked): does a window still draw once it is moved outside every screen, where
the agent parks windows during a lock? Captures it with the installed agent's own code where it is, then moved to
-Left/-Top (off every screen), twice, -Gap seconds apart; then puts it back. PNGs and one line per capture go to -Out.
  .\Offscreen-Live.ps1 -Title classic-clock -Left 3000
#>
param([Parameter(Mandatory)][string]$Title, [int]$Left = 3000, [int]$Top = 100, [int]$Gap = 2, [string]$Out = 'C:\locktest\offscreen',
      [string]$Agent = "$env:ProgramFiles\LockMonitor\LockMonitor-Agent.exe")
$ErrorActionPreference = 'Stop'
$null = New-Item -ItemType Directory -Force $Out
$null = [Reflection.Assembly]::UnsafeLoadFrom($Agent)
[Pix]::DpiAware()
Add-Type @'
using System; using System.Runtime.InteropServices; using System.Text;
public static class OffW {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
    delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hgt, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
    public static IntPtr Find(string part) { IntPtr f = IntPtr.Zero; EnumWindows((h, p) => { StringBuilder s = new StringBuilder(256); GetWindowText(h, s, 256); if (IsWindowVisible(h) && s.ToString().Contains(part)) { f = h; return false; } return true; }, IntPtr.Zero); return f; }
}
'@
$h = [OffW]::Find($Title); if ($h -eq [IntPtr]::Zero) { throw "no window '$Title'" }
$r = New-Object OffW+RECT; $null = [OffW]::GetWindowRect($h, [ref]$r)
$log = Join-Path $Out 'offscreen.txt'
$last = $null
function Shot($name) {
    $v = [Pix]::Visible($h)
    $s = New-Object Pix+Snap; $s.Left = $v.X; $s.Top = $v.Y; $s.W = $v.Width; $s.H = $v.Height
    $w = New-Object Pix+Win; $w.H = $h; $w.W = $v.Width; $w.Hgt = $v.Height; $s.Wins.Add($w)
    $f = New-Object Frame($v.Width, $v.Height, [Frame]::Room)
    $d = [Pix]::CaptureWindows($s, $f); $t = 0; $b = 0
    $p = Join-Path $Out "$name.png"; $f.Gdi.Save($p, [System.Drawing.Imaging.ImageFormat]::Png)
    $bytes = [IO.File]::ReadAllBytes($p); $hash = [BitConverter]::ToString([Security.Cryptography.MD5]::Create().ComputeHash($bytes)).Substring(0, 11)
    $f.Dispose()
    $line = '{0:HH:mm:ss.ff} {1}: at {2},{3} {4}x{5}, on a screen: {6}, drawn {7}, picture {8}{9}' -f (Get-Date), $name, $v.X, $v.Y, $v.Width, $v.Height, ([OffW]::MonitorFromWindow($h, 0) -ne [IntPtr]::Zero), $d, $hash, $(if ($hash -eq $script:last) { ' (UNCHANGED)' } else { '' })
    $script:last = $hash
    Add-Content $log $line
}
try {
    Shot 'on-1'; Start-Sleep $Gap; Shot 'on-2'
    $null = [OffW]::SetWindowPos($h, [IntPtr]::Zero, $Left, $Top, 0, 0, 0x1 -bor 0x4 -bor 0x10)
    Start-Sleep $Gap; Shot 'off-1'; Start-Sleep $Gap; Shot 'off-2'; Start-Sleep $Gap; Shot 'off-3'
} finally { $null = [OffW]::SetWindowPos($h, [IntPtr]::Zero, $r.l, $r.t, 0, 0, 0x1 -bor 0x4 -bor 0x10) }
