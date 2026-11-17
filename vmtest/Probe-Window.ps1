<#
Lock probe for the test VM (logged-on session, unelevated; start it before the lock): four times a second, where one
window is and how big, whether it is maximized, and on how many screens the desktop is. Shows what Windows and the app
do with a window when its screen leaves the desktop and returns.   Log: C:\locktest\window-probe.log
#>
param([Parameter(Mandatory)][string]$Title, [int]$Seconds = 40, [string]$Log = 'C:\locktest\window-probe.log')
Add-Type @'
using System; using System.Runtime.InteropServices; using System.Text;
public static class Wp {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
    delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
    public static string Row(string part) {
        SetThreadDpiAwarenessContext(new IntPtr(-4));
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, p) => { StringBuilder s = new StringBuilder(256); GetWindowText(h, s, 256); if (IsWindowVisible(h) && s.ToString().Contains(part)) { found = h; return false; } return true; }, IntPtr.Zero);
        if (found == IntPtr.Zero) return "screens=" + GetSystemMetrics(80) + " window not found";
        RECT r; GetWindowRect(found, out r);
        return "screens=" + GetSystemMetrics(80) + " at " + r.l + "," + r.t + " size " + (r.r - r.l) + "x" + (r.b - r.t) + (IsZoomed(found) ? " maximized" : IsIconic(found) ? " minimized" : " normal");
    }
}
'@
$prev = ''
for ($end = (Get-Date).AddSeconds($Seconds); (Get-Date) -lt $end; Start-Sleep -Milliseconds 250) {
    $row = [Wp]::Row($Title)
    if ($row -ne $prev) { Add-Content $Log ('{0:HH:mm:ss.ff} {1}' -f (Get-Date), $row); $prev = $row }   # only changes
}
