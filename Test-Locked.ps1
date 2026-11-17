<#
Evidence that the session is genuinely locked, independent of what any monitor shows.
Run it, press Win+L, wait ~30 s, unlock. Log: %TEMP%\lockcheck.log. One row per second:
  locked         Windows' own answer (WTS session state). Must be True from Win+L until the password is accepted.
  LogonUI        the sign-in process is running. Must be True for the same period.
  secureDesktop  True while Windows' secure desktop owns the screen: the first seconds after locking and while the
                 sign-in box is up. While only the lock-screen picture shows it reads False, because Windows 10/11 draw
                 that picture with their lock app on the user's own desktop (measured in the test VM). So it is NOT a
                 lock test, and it is why windows keep rendering while locked.
  input          seconds since the last keyboard/mouse input in this session (its time only, never its content).
  dashboard      Show-Dashboard.ps1's heartbeat: 'time' and 'frames' must keep advancing while locked=True.
#>
param([int]$Seconds = 90)
if (-not ('LockState' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class LockState {
    [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize, dwTime; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO l);
    [DllImport("user32.dll")] static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr h);
    [DllImport("wtsapi32.dll")] static extern bool WTSQuerySessionInformation(IntPtr server, int session, int infoClass, out IntPtr buf, out int bytes);
    [DllImport("wtsapi32.dll")] static extern void WTSFreeMemory(IntPtr p);
    public static long IdleSeconds() { LASTINPUTINFO l = new LASTINPUTINFO(); l.cbSize = 8; return GetLastInputInfo(ref l) ? (long)(unchecked((uint)Environment.TickCount - l.dwTime) / 1000) : -1L; }
    public static bool SecureDesktop() { IntPtr h = OpenInputDesktop(0, false, 0x100); if (h == IntPtr.Zero) return true; CloseDesktop(h); return false; }   // a user process cannot open the secure desktop
    public static string Locked() {   // WTSSessionInfoEx (25): SessionFlags at offset 16 (Level, padding, SessionId, SessionState, SessionFlags); 0 = locked, 1 = unlocked
        IntPtr p; int n;
        if (!WTSQuerySessionInformation(IntPtr.Zero, -1, 25, out p, out n)) return "unknown";
        int flags = Marshal.ReadInt32(p, 16); WTSFreeMemory(p);
        return flags == 0 ? "True" : flags == 1 ? "False" : "unknown";
    }
}
'@
}
$log = "$env:TEMP\lockcheck.log"
for ($end = (Get-Date).AddSeconds($Seconds); (Get-Date) -lt $end; Start-Sleep 1) {
    $hb = Get-Content "$env:LOCALAPPDATA\LockMonitor\dashboard.heartbeat" -ErrorAction SilentlyContinue
    $row = '{0:HH:mm:ss} locked={1,-5} LogonUI={2,-5} secureDesktop={3,-5} input={4}s dashboard=[{5}]' -f (Get-Date), [LockState]::Locked(), [bool](Get-Process LogonUI -ErrorAction SilentlyContinue), [LockState]::SecureDesktop(), [LockState]::IdleSeconds(), $hb
    Add-Content $log $row
    $row
}
