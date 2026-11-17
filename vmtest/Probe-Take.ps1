<#
Lock probe for the test VM (logged-on session, unelevated; start it before the lock). Question: does taking a screen
off the desktop look like user activity to Windows, or disturb the lock screen? Four times a second it logs the
session's lock flag, the time since the last input, the pointer position, the lock-screen processes and the number
of desktop screens. -CursorX/-CursorY put the pointer somewhere first (e.g. on the screen that will be taken).
  Log: C:\locktest\take-probe.log
#>
param([int]$Seconds = 40, [int]$CursorX = -1, [int]$CursorY = -1, [string]$Log = 'C:\locktest\take-probe.log')
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class Tk {
    [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize, dwTime; }
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int x, y; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO i);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
    [DllImport("wtsapi32.dll")] static extern bool WTSQuerySessionInformation(IntPtr server, int session, int infoClass, out IntPtr buf, out int bytes);
    [DllImport("wtsapi32.dll")] static extern void WTSFreeMemory(IntPtr p);
    public static uint IdleMs() { LASTINPUTINFO i = new LASTINPUTINFO(); i.cbSize = 8; GetLastInputInfo(ref i); return (uint)Environment.TickCount - i.dwTime; }
    public static string Cursor() { POINT p; return GetCursorPos(out p) ? p.x + "," + p.y : "n/a"; }
    public static int Screens() { return GetSystemMetrics(80); }   // SM_CMONITORS
    public static int Flag() { IntPtr p; int n; if (!WTSQuerySessionInformation(IntPtr.Zero, -1, 25, out p, out n)) return -2; int f = Marshal.ReadInt32(p, 16); WTSFreeMemory(p); return f; }   // 0 locked, 1 unlocked
}
'@
if ($CursorX -ge 0) { $null = [Tk]::SetCursorPos($CursorX, $CursorY) }
for ($end = (Get-Date).AddSeconds($Seconds); (Get-Date) -lt $end; Start-Sleep -Milliseconds 250) {
    $ui = (Get-Process LogonUI, LockApp -ErrorAction SilentlyContinue | Sort-Object ProcessName | ForEach-Object { "$($_.ProcessName):$($_.Id)" }) -join ' '
    Add-Content $Log ('{0:HH:mm:ss.ff} flag={1} idle={2,6} cursor={3,-10} screens={4} {5}' -f (Get-Date), [Tk]::Flag(), [Tk]::IdleMs(), [Tk]::Cursor(), [Tk]::Screens(), $ui)
}
