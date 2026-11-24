<#
Test-VM helper: the logged-on user's session, as Windows reports it, every -Every ms for -Seconds; each change one line
in -Log: its number, its state (Active, Disconnected, ...), whether it is the console's session, and its lock flag
(locked / unlocked / unknown). Runs anywhere (also in session 0 through vmrun), so it keeps reporting while the user's
session is locked or disconnected.
#>
param([int]$Seconds = 300, [int]$Every = 250, [string]$User = 'tester', [string]$Log = 'C:\locktest\session.log')
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class Ses {
    [StructLayout(LayoutKind.Sequential)] struct Info { public int SessionId; public IntPtr Station; public int State; }
    [DllImport("wtsapi32.dll")] static extern bool WTSEnumerateSessions(IntPtr server, int reserved, int version, out IntPtr info, out int count);
    [DllImport("wtsapi32.dll")] static extern bool WTSQuerySessionInformation(IntPtr server, int session, int cls, out IntPtr buf, out int bytes);
    [DllImport("wtsapi32.dll")] static extern void WTSFreeMemory(IntPtr p);
    [DllImport("kernel32.dll")] static extern int WTSGetActiveConsoleSessionId();
    static readonly string[] States = { "Active", "Connected", "ConnectQuery", "Shadow", "Disconnected", "Idle", "Listen", "Reset", "Down", "Init" };
    static string Text(int id, int cls) { IntPtr p; int n; if (!WTSQuerySessionInformation(IntPtr.Zero, id, cls, out p, out n)) return ""; string s = Marshal.PtrToStringAnsi(p); WTSFreeMemory(p); return s; }   // the A function: no CharSet given
    public static string Of(string user) {
        IntPtr info; int count; if (!WTSEnumerateSessions(IntPtr.Zero, 0, 1, out info, out count)) return "no answer";
        string r = "no session of " + user; int size = Marshal.SizeOf(typeof(Info));
        for (int i = 0; i < count; i++) {
            Info s = (Info)Marshal.PtrToStructure(info + i * size, typeof(Info));
            if (!string.Equals(Text(s.SessionId, 5), user, StringComparison.OrdinalIgnoreCase)) continue;   // 5 = WTSUserName
            IntPtr p; int n; string flag = "?";
            if (WTSQuerySessionInformation(IntPtr.Zero, s.SessionId, 25, out p, out n)) { int f = Marshal.ReadInt32(p, 16); WTSFreeMemory(p); flag = f == 0 ? "locked" : f == 1 ? "unlocked" : "unknown"; }   // WTSSessionInfoEx
            r = "session " + s.SessionId + " " + (s.State < States.Length ? States[s.State] : s.State.ToString()) + (s.SessionId == WTSGetActiveConsoleSessionId() ? ", on the console" : ", not on the console") + ", " + flag;
        }
        WTSFreeMemory(info); return r;
    }
}
'@
$last = ''; $end = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $end) {
    $s = [Ses]::Of($User)
    if ($s -ne $last) { Add-Content $Log ('{0:HH:mm:ss.fff} {1}' -f (Get-Date), $s); $last = $s }
    Start-Sleep -Milliseconds $Every
}
