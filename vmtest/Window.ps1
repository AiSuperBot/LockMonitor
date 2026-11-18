<#
Test-VM helper (logged-on session): one window, found by part of its title.
  .\Window.ps1 -Title x -Maximize          maximize it
  .\Window.ps1 -Title x -Restore           restore it
  .\Window.ps1 -Title x -Watch 40          for that many seconds, four times a second: where it is, how big, whether it
                                           is maximized, and on how many screens the desktop is; each change one line in
                                           -Log. Start it before a lock to see what Windows and the app do with a window
                                           when its screen leaves the desktop and returns.
#>
param([Parameter(Mandatory)][string]$Title, [switch]$Maximize, [switch]$Restore, [int]$Watch, [string]$Log = 'C:\locktest\window.log')
Add-Type @'
using System; using System.Runtime.InteropServices; using System.Text;
public static class Wnd {
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int l, t, r, b; }
    delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
    public static IntPtr Find(string part) {   // the first visible window whose title contains part
        SetThreadDpiAwarenessContext(new IntPtr(-4));
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, p) => { StringBuilder s = new StringBuilder(256); GetWindowText(h, s, 256); if (IsWindowVisible(h) && s.ToString().Contains(part)) { found = h; return false; } return true; }, IntPtr.Zero);
        return found;
    }
    public static bool Show(IntPtr h, int cmd) { return h != IntPtr.Zero && ShowWindow(h, cmd); }
    public static string State(IntPtr h) {
        string screens = "screens=" + GetSystemMetrics(80);   // SM_CMONITORS
        if (h == IntPtr.Zero) return screens + " window not found";
        RECT r; GetWindowRect(h, out r);
        return screens + " at " + r.l + "," + r.t + " size " + (r.r - r.l) + "x" + (r.b - r.t) + (IsZoomed(h) ? " maximized" : IsIconic(h) ? " minimized" : " normal");
    }
}
'@
$h = [Wnd]::Find($Title)
if ($Maximize) { $null = [Wnd]::Show($h, 3) }   # SW_MAXIMIZE
if ($Restore) { $null = [Wnd]::Show($h, 9) }    # SW_RESTORE
$prev = ''
for ($end = (Get-Date).AddSeconds($Watch); (Get-Date) -lt $end; Start-Sleep -Milliseconds 250) {
    $row = [Wnd]::State($h)
    if ($row -ne $prev) { Add-Content $Log ('{0:HH:mm:ss.ff} {1}' -f (Get-Date), $row); $prev = $row }
}
