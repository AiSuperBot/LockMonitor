<#
Test-VM helper (logged-on session): one window, found by part of its title.
  .\Window.ps1 -Title x -Maximize          maximize it
  .\Window.ps1 -Title x -Restore           restore it
  .\Window.ps1 -Title x -Left 1300 -Top 40 [-Maximize]   restore it, move it there (another screen, say), and maximize it there
  .\Window.ps1 -Title x -Watch 40          for that many seconds, four times a second: where it is, how big, whether it
                                           is maximized, and on how many screens the desktop is; each change one line in
                                           -Log. Start it before a lock to see what Windows and the app do with a window
                                           when its screen leaves the desktop and returns.
#>
#  .\Window.ps1 -Title x -Hide -After 10   hide it after 10 s, as an app may do (start it before a lock: commands cannot be started while locked)
param([Parameter(Mandatory)][string]$Title, [switch]$Maximize, [switch]$Restore, [switch]$Hide, [int]$After, [int]$Watch, [string]$Log = 'C:\locktest\window.log', [int]$Left = [int]::MinValue, [int]$Top = 0)
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
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
    public static IntPtr Find(string part) {   // the first visible window whose title contains part
        SetThreadDpiAwarenessContext(new IntPtr(-4));
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, p) => { StringBuilder s = new StringBuilder(256); GetWindowText(h, s, 256); if (IsWindowVisible(h) && s.ToString().Contains(part)) { found = h; return false; } return true; }, IntPtr.Zero);
        return found;
    }
    public static bool Show(IntPtr h, int cmd) { return h != IntPtr.Zero && ShowWindow(h, cmd); }
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hgt, uint flags);
    public static bool Move(IntPtr h, int x, int y) { return h != IntPtr.Zero && ShowWindow(h, 9) | SetWindowPos(h, IntPtr.Zero, x, y, 0, 0, 0x1); }   // restored, then moved on top of the others; size kept
    public static string State(IntPtr h) {
        string screens = "screens=" + GetSystemMetrics(80);   // SM_CMONITORS
        if (h == IntPtr.Zero) return screens + " window not found";
        RECT r; GetWindowRect(h, out r);
        return screens + " at " + r.l + "," + r.t + " size " + (r.r - r.l) + "x" + (r.b - r.t) + (IsZoomed(h) ? " maximized" : IsIconic(h) ? " minimized" : " normal") + (GetForegroundWindow() == h ? ", has the focus" : "");
    }
}
'@
$h = [Wnd]::Find($Title)
Start-Sleep $After
if ($Left -ne [int]::MinValue) { $null = [Wnd]::Move($h, $Left, $Top); Start-Sleep -Milliseconds 300 }
if ($Maximize) { $null = [Wnd]::Show($h, 3) }   # SW_MAXIMIZE
if ($Restore) { $null = [Wnd]::Show($h, 9) }    # SW_RESTORE
if ($Hide) { $null = [Wnd]::Show($h, 0); Add-Content $Log ('{0:HH:mm:ss.ff} hid it' -f (Get-Date)) }   # SW_HIDE
$prev = ''
for ($end = (Get-Date).AddSeconds($Watch); (Get-Date) -lt $end; Start-Sleep -Milliseconds 250) {
    $row = [Wnd]::State($h)
    if ($row -ne $prev) { Add-Content $Log ('{0:HH:mm:ss.ff} {1}' -f (Get-Date), $row); $prev = $row }
}
