// Shared by both programs and compiled into each of them (see Build.ps1): the version, Windows' lock flag, what Windows
// says about handing a monitor to a program, screen numbers, the notes the two programs keep in the registry, and the log.
using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32;

// shown in each file's Properties > Details; the agent also logs it at every start
[assembly: AssemblyProduct("LockMonitor")]
[assembly: AssemblyVersion("0.2.8")]
[assembly: AssemblyFileVersion("0.2.8")]

public static class Common {
    [DllImport("wtsapi32.dll")] static extern bool WTSQuerySessionInformation(IntPtr server, int session, int infoClass, out IntPtr buf, out int bytes);
    [DllImport("wtsapi32.dll")] static extern void WTSFreeMemory(IntPtr p);
    // Windows' own lock flag: WTSSessionInfoEx (25), SessionFlags at offset 16: 0 = locked, 1 = unlocked; -1 here = no
    // answer. Whether the input desktop can be opened is no test: Windows draws the lock-screen picture on the user's own
    // desktop (measured).
    public static int SessionFlag() {
        IntPtr p; int n;
        if (!WTSQuerySessionInformation(IntPtr.Zero, -1, 25, out p, out n)) return -1;
        int f = Marshal.ReadInt32(p, 16); WTSFreeMemory(p); return f;
    }
    // Two definite answers; when Windows cannot say, both are false. Holding a screen and drawing on it takes a definite
    // "locked"; asking for a held screen to be put back takes a definite "unlocked".
    public static bool Locked() { return SessionFlag() == 0; }
    public static bool Unlocked() { return SessionFlag() == 1; }

    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo([In, Out] byte[] request);
    // A DisplayConfig device-info request: header (type, size, adapter LUID, target id); the rest is filled in by the
    // caller (a SET) or by Windows (a GET). Ask sends a GET: Windows' answer, or null.
    public static byte[] Request(int type, int size, uint lo, int hi, uint id) {
        byte[] r = new byte[size];
        BitConverter.GetBytes(type).CopyTo(r, 0); BitConverter.GetBytes(size).CopyTo(r, 4);
        BitConverter.GetBytes(lo).CopyTo(r, 8); BitConverter.GetBytes(hi).CopyTo(r, 12); BitConverter.GetBytes(id).CopyTo(r, 16);
        return r;
    }
    public static byte[] Ask(int type, int size, uint lo, int hi, uint id) { byte[] r = Request(type, size, lo, hi, id); return DisplayConfigGetDeviceInfo(r) == 0 ? r : null; }
    public static string Text(byte[] answer, int at, int bytes) {   // a zero-terminated WCHAR[] in an answer
        string s = Encoding.Unicode.GetString(answer, at, bytes); int z = s.IndexOf('\0'); return z >= 0 ? s.Substring(0, z) : s;
    }

    [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint paths, out uint modes);
    [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint paths, [Out] byte[] pathArray, ref uint modes, [Out] byte[] modeArray, IntPtr topology);
    // Windows' list of display paths: 1 = all possible ones (QDC_ALL_PATHS), 2 = those of the desktop (QDC_ONLY_ACTIVE_PATHS).
    // DISPLAYCONFIG_PATH_INFO is 72 bytes: source adapter LUID at 0, source id at 8, target adapter LUID at 20, target id at 28.
    // Sized first and read then: when the screens change in between, Windows answers 122 (ERROR_INSUFFICIENT_BUFFER) and
    // its documentation says to ask again.
    public static byte[] Paths(uint which, out uint np) {
        for (int tries = 0; tries < 3; tries++) {
            uint nm;
            if (GetDisplayConfigBufferSizes(which, out np, out nm) != 0) break;
            byte[] paths = new byte[72 * np], modes = new byte[64 * nm];
            int rc = QueryDisplayConfig(which, ref np, paths, ref nm, modes, IntPtr.Zero);
            if (rc == 0) return paths;
            if (rc != 122) break;
        }
        np = 0; return new byte[0];
    }

    // The monitor's own device path (DISPLAYCONFIG_TARGET_DEVICE_NAME: type 2, 420 bytes, the path at offset 164); "" if
    // there is no monitor. Measured in the test VM: it is the same after a restart, and Windows also gives it for a
    // screen that is off the desktop.
    public static string MonitorPath(uint lo, int hi, uint id) { byte[] a = Ask(2, 420, lo, hi, id); return a == null ? "" : Text(a, 164, 256); }

    // Where the screen named by a "Taken" note is now; returns the note's parts. Windows numbers the graphics adapters anew
    // at every start, so the adapter in a note that outlived a restart (the PC was restarted while locked) means nothing
    // any more: the screen is then found again by its monitor path, as the same target on whichever adapter answers with
    // that path. Measured in the test VM: without this, such a screen stayed off the desktop for good. Both programs go
    // through this: the agent too, or it would look for the screen under the old numbers.
    public static string[] Address(string note, out uint lo, out int hi, out uint id) {
        string[] h = Parse(note, out lo, out hi, out id);
        if (h.Length < 5 || h[4].Length == 0 || OffDesktop(lo, hi, id) != null) return h;
        uint np; byte[] paths = Paths(1, out np); HashSet<long> tried = new HashSet<long>();
        for (int i = 0; i < np; i++) {   // every adapter shows up in the list of all paths, even when its screen itself is hidden from it
            long luid = BitConverter.ToInt64(paths, 72 * i);
            if (!tried.Add(luid)) continue;
            if (MonitorPath((uint)luid, (int)(luid >> 32), id) == h[4]) { lo = (uint)luid; hi = (int)(luid >> 32); break; }
        }
        return h;
    }

    // What Windows says about handing a monitor to a program (GET_MONITOR_SPECIALIZATION = 12, 24 bytes): bit 0 = it is
    // off the desktop now, bit 1 = possible for this monitor, bit 2 = possible on this Windows. null = no answer: the
    // monitor is not connected, the adapter numbers in the request are from before a restart, or this is Windows 10,
    // which does not know the request (error 87 at any size; measured on 19045).
    public static uint? Specialization(uint lo, int hi, uint id) { byte[] a = Ask(12, 24, lo, hi, id); return a == null ? (uint?)null : BitConverter.ToUInt32(a, 20); }
    // The report on a monitor that Windows' own Settings reads (type -7, undocumented, 940 bytes on Windows 10 19045 and
    // Windows 11 26100): the monitor's ID at offset 20, and bit 8 of the value at offset 588 = off the desktop (measured
    // on both, also for a monitor taken off the desktop and then unplugged and plugged in again). null = not connected.
    public static byte[] Report(uint lo, int hi, uint id) { return Ask(-7, 940, lo, hi, id); }
    public static bool? OffDesktop(uint lo, int hi, uint id) {
        uint? f = Specialization(lo, hi, id);
        if (f == null) { byte[] r = Report(lo, hi, id); if (r != null) f = (BitConverter.ToUInt32(r, 588) >> 8) & 1; }   // Windows 10
        return f == null ? (bool?)null : (f & 1) != 0;
    }
    public static string Describe(uint lo, int hi, uint id) {
        uint? f = Specialization(lo, hi, id);
        if (f != null) return "off the desktop: " + Yes(f, 1) + "; can be handed to a program: this monitor " + Yes(f, 2) + ", this Windows " + Yes(f, 4);
        byte[] r = Report(lo, hi, id);   // Windows 10
        return r == null ? "unknown" : "off the desktop: " + Yes(BitConverter.ToUInt32(r, 588), 0x100) + " (Windows 10 report)";
    }
    static string Yes(uint? f, uint bit) { return (f & bit) != 0 ? "yes" : "no"; }

    // \\.\DISPLAY3 -> 3; -1 for a name that does not end in a number
    public static int Number(string device) {
        int p = device.Length; while (p > 0 && char.IsDigit(device[p - 1])) p--;
        int n; return int.TryParse(device.Substring(p), out n) ? n : -1;
    }

    // The notes in HKLM\SOFTWARE\LockMonitor, where only administrators can write. "Taken": the screen the helper holds
    // off the desktop right now, as "adapterLow|adapterHigh|target|device|monitor path". "Keep": the one monitor it ever
    // takes. "Check": left by the setup during its live test.
    public static RegistryKey Notes(bool write) {
        using (RegistryKey hklm = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64))
            return write ? hklm.CreateSubKey(@"SOFTWARE\LockMonitor") : hklm.OpenSubKey(@"SOFTWARE\LockMonitor");
    }
    public static object Note(string name) { using (RegistryKey k = Notes(false)) return k == null ? null : k.GetValue(name); }
    public static string Taken() { return Note("Taken") as string; }
    // The parts of a "Taken" note, and its screen's adapter and target as numbers.
    public static string[] Parse(string note, out uint lo, out int hi, out uint id) {
        string[] h = note.Split('|'); lo = uint.Parse(h[0]); hi = int.Parse(h[1]); id = uint.Parse(h[2]); return h;
    }

    // One line with the time in front; the file keeps its newer half when it passes 256 KB. A log that cannot be written
    // must never stop the work it reports on.
    public static void Log(string file, string m) {
        try {
            FileInfo f = new FileInfo(file);
            if (f.Exists && f.Length > 262144) { string[] all = File.ReadAllLines(file); File.WriteAllLines(file, new List<string>(all).GetRange(all.Length / 2, all.Length - all.Length / 2)); }
            File.AppendAllText(file, DateTime.Now.ToString("s") + " " + m + Environment.NewLine);
        } catch (Exception) { }
    }
}
