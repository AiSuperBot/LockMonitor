<# Test-VM helper (logged-on session): maximize (default) or restore the first visible window whose title contains the text. #>
param([Parameter(Mandatory)][string]$Title, [switch]$Restore)
Add-Type @'
using System; using System.Runtime.InteropServices; using System.Text;
public static class Wn {
    delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    public static bool Show(string part, int cmd) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, p) => { StringBuilder s = new StringBuilder(256); GetWindowText(h, s, 256); if (IsWindowVisible(h) && s.ToString().Contains(part)) { found = h; return false; } return true; }, IntPtr.Zero);
        return found != IntPtr.Zero && ShowWindow(found, cmd);
    }
}
'@
$null = [Wn]::Show($Title, $(if ($Restore) { 9 } else { 3 }))   # 3 = SW_MAXIMIZE, 9 = SW_RESTORE
