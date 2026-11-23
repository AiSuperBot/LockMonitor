<#
Test-VM helper (logged-on session): which window has the keyboard focus (the foreground window), every 20 ms for
-Seconds; each change one line with milliseconds in -Log. Start it before a lock to see who gets the focus at the
unlock: the window that had it before the lock should get it back, never one this program moved.
#>
param([int]$Seconds = 60, [string]$Log = 'C:\locktest\focus.log')
Add-Type @'
using System; using System.Runtime.InteropServices; using System.Text;
public static class Fg {
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("winmm.dll")] public static extern uint timeBeginPeriod(uint ms);
    public static string Now() { IntPtr h = GetForegroundWindow(); if (h == IntPtr.Zero) return "(none)"; StringBuilder s = new StringBuilder(128); GetWindowText(h, s, 128); return "0x" + h.ToString("X") + " '" + s + "'"; }
}
'@
$null = [Fg]::timeBeginPeriod(1)
$prev = ''
for ($end = (Get-Date).AddSeconds($Seconds); (Get-Date) -lt $end; Start-Sleep -Milliseconds 20) {
    $row = [Fg]::Now()
    if ($row -ne $prev) { Add-Content $Log ('{0:HH:mm:ss.fff} {1}' -f (Get-Date), $row); $prev = $row }
}
