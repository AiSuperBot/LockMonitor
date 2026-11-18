// Shared by both programs and compiled into each of them (see Build.ps1): the version, Windows' lock flag, what Windows
// says about handing a monitor to a program, screen numbers, the notes the two programs keep in the registry, and the log.
using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using Microsoft.Win32;

// shown in each file's Properties > Details; the agent also logs it at every start
[assembly: AssemblyProduct("LockMonitor")]
[assembly: AssemblyVersion("0.2.5")]
[assembly: AssemblyFileVersion("0.2.5")]

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

    [StructLayout(LayoutKind.Sequential)] struct SpecReq { public int type, size; public uint lo; public int hi; public uint id, flags; }
    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref SpecReq r);
    // What Windows says about handing a monitor to a program (DisplayConfigGetDeviceInfo, GET_MONITOR_SPECIALIZATION = 12):
    // bit 0 = it is off the desktop now, bit 1 = possible for this monitor, bit 2 = possible on this Windows.
    // null = no answer: the monitor is not connected, or the adapter numbers in the request are from before a restart.
    public static uint? Specialization(uint lo, int hi, uint id) {
        SpecReq r = new SpecReq(); r.type = 12; r.size = Marshal.SizeOf(typeof(SpecReq)); r.lo = lo; r.hi = hi; r.id = id;
        return DisplayConfigGetDeviceInfo(ref r) == 0 ? r.flags : (uint?)null;
    }
    public static bool? OffDesktop(uint lo, int hi, uint id) { uint? f = Specialization(lo, hi, id); return f == null ? (bool?)null : (f & 1) != 0; }
    public static string Describe(uint lo, int hi, uint id) {
        uint? f = Specialization(lo, hi, id);
        return f == null ? "unknown" : "off the desktop: " + Yes(f, 1) + "; can be handed to a program: this monitor " + Yes(f, 2) + ", this Windows " + Yes(f, 4);
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
