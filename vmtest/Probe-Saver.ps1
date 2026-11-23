<#
Test-VM helper (logged-on session): for -Seconds, four times a second, which desktop has the input (the name, or
"refused" when this user may not open it, as for the sign-in screen) and how many screens the desktop has; each change
one line in C:\locktest\saver.log. Start it before a screen saver or a lock to see what the agent sees meanwhile.
#>
param([int]$Seconds = 200)
Add-Type @'
using System; using System.Runtime.InteropServices; using System.Text;
public static class InputDesk {
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr OpenInputDesktop(uint f, bool inherit, uint access);
    [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetUserObjectInformation(IntPtr h, int index, StringBuilder b, int n, out int need);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
    public static string Name() {
        IntPtr d = OpenInputDesktop(0, false, 1);   // DESKTOP_READOBJECTS, as the agent asks
        if (d == IntPtr.Zero) return "refused (" + Marshal.GetLastWin32Error() + ")";
        StringBuilder b = new StringBuilder(64); int need; GetUserObjectInformation(d, 2, b, 128, out need); CloseDesktop(d);   // 2 = UOI_NAME
        return b.ToString();
    }
}
'@
$last = ''; $end = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $end) {
    $s = 'input desktop ' + [InputDesk]::Name() + ', screens ' + [InputDesk]::GetSystemMetrics(80)   # 80 = SM_CMONITORS
    if ($s -ne $last) { Add-Content C:\locktest\saver.log ('{0:HH:mm:ss.fff} {1}' -f (Get-Date), $s); $last = $s }
    Start-Sleep -Milliseconds 250
}
