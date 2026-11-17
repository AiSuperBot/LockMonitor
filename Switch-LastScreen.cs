// Elevated helper. Install-Auto.ps1 compiles it to "%ProgramFiles%\LockMonitor\Switch-LastScreen.exe" and has Windows
// start it on its own lock and unlock events. It does one thing: at lock it takes the highest-numbered screen off the
// Windows desktop (-take), at unlock it puts it back (-give). It uses the documented switch behind
// Settings > System > Display > Advanced display > "Remove display from desktop". The lock itself is not touched and
// nothing else runs elevated: the picture is produced by LockMonitor-Agent.exe (Agent.cs), unelevated.
// Its log (switch.log next to it) has only what is out of the ordinary; the routine is in the agent's log.
//
// It is a program of its own, not a script, on purpose: it runs elevated on every lock, so it should start in
// milliseconds and depend on nothing a non-administrator can change (no script host, no module or temp folders, no
// environment variables). Its log and its two notes live where only administrators can write: next to the exe, and
// in HKLM\SOFTWARE\LockMonitor ("Taken": the screen it holds right now; "Keep": the one monitor it ever takes).
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32;

static class SwitchLastScreen {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct SetReq { public int type, size; public uint lo; public int hi; public uint id, flags; public Guid specType, specSubType;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string app; }
    [StructLayout(LayoutKind.Sequential)] struct GetReq { public int type, size; public uint lo; public int hi; public uint id, flags; }
    [DllImport("user32.dll")] static extern int DisplayConfigSetDeviceInfo(ref SetReq r);
    [DllImport("user32.dll", EntryPoint = "DisplayConfigGetDeviceInfo")] static extern int GetSpecialization(ref GetReq r);
    [DllImport("user32.dll", EntryPoint = "DisplayConfigGetDeviceInfo")] static extern int GetInfo([In, Out] byte[] request);
    [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint paths, out uint modes);
    [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint paths, [Out] byte[] pathArray, ref uint modes, [Out] byte[] modeArray, IntPtr topology);
    [DllImport("wtsapi32.dll")] static extern bool WTSQuerySessionInformation(IntPtr server, int session, int infoClass, out IntPtr buf, out int bytes);
    [DllImport("wtsapi32.dll")] static extern void WTSFreeMemory(IntPtr p);

    static string logFile;
    static void Log(string m) {
        try {
            FileInfo f = new FileInfo(logFile);
            if (f.Exists && f.Length > 262144) { string[] all = File.ReadAllLines(logFile); File.WriteAllLines(logFile, new List<string>(all).GetRange(all.Length / 2, all.Length - all.Length / 2)); }   // keep the newer half
            File.AppendAllText(logFile, DateTime.Now.ToString("s") + " " + m + Environment.NewLine);
        } catch (Exception) { }   // logging must never be the reason the screen is not switched
    }

    // Windows' own lock flag: WTSSessionInfoEx (25), SessionFlags at offset 16, 0 = locked
    static bool Locked() {
        IntPtr p; int n; if (!WTSQuerySessionInformation(IntPtr.Zero, -1, 25, out p, out n)) return false;
        int f = Marshal.ReadInt32(p, 16); WTSFreeMemory(p); return f == 0;
    }

    // 0 = done. Found by experiment in the test VM: Windows wants exactly this type value (wingdi.h:
    // GUID_MONITOR_OVERRIDE_PSEUDO_SPECIALIZED), an empty sub type and a non-empty application name; needs elevation.
    static int Set(uint lo, int hi, uint id, bool on) {
        SetReq r = new SetReq(); r.type = 13; r.size = Marshal.SizeOf(typeof(SetReq)); r.lo = lo; r.hi = hi; r.id = id;
        r.flags = on ? 1u : 0u; r.specType = new Guid("f196c02f-f86f-4f9a-aa15-e9cebdfe3b96"); r.app = "LockMonitor";
        return DisplayConfigSetDeviceInfo(ref r);
    }

    // true/false: that monitor is off / on the desktop. null: Windows cannot say (monitor unplugged).
    static bool? OffDesktop(uint lo, int hi, uint id) {
        GetReq r = new GetReq(); r.type = 12; r.size = Marshal.SizeOf(typeof(GetReq)); r.lo = lo; r.hi = hi; r.id = id;
        if (GetSpecialization(ref r) != 0) return null;
        return (r.flags & 1) != 0;
    }
    // What Windows itself says about handing that screen to a program (the other two bits of the same answer).
    static string Possible(uint lo, int hi, uint id) {
        GetReq r = new GetReq(); r.type = 12; r.size = Marshal.SizeOf(typeof(GetReq)); r.lo = lo; r.hi = hi; r.id = id;
        if (GetSpecialization(ref r) != 0) return "unknown";
        return "this monitor " + ((r.flags & 2) != 0 ? "yes" : "no") + ", this Windows " + ((r.flags & 4) != 0 ? "yes" : "no");
    }

    // Windows' list of display paths: 1 = all possible ones (QDC_ALL_PATHS), 2 = those of the desktop (QDC_ONLY_ACTIVE_PATHS).
    // DISPLAYCONFIG_PATH_INFO is 72 bytes: source adapter LUID at 0, source id at 8, target adapter LUID at 20, target id at 28.
    static byte[] Paths(uint which, out uint np) {
        uint nm;
        if (GetDisplayConfigBufferSizes(which, out np, out nm) != 0) { np = 0; return new byte[0]; }
        byte[] paths = new byte[72 * np], modes = new byte[64 * nm];
        if (QueryDisplayConfig(which, ref np, paths, ref nm, modes, IntPtr.Zero) != 0) np = 0;
        return paths;
    }

    // The monitor's own device path (DISPLAYCONFIG_TARGET_DEVICE_NAME: type 2, 420 bytes, the path at offset 164); "" if
    // there is no monitor. Measured in the test VM: it is the same after a restart, and Windows also gives it for a
    // screen that is off the desktop.
    static string MonitorPath(uint lo, int hi, uint id) {
        byte[] req = new byte[420];
        BitConverter.GetBytes(2).CopyTo(req, 0); BitConverter.GetBytes(420).CopyTo(req, 4);
        BitConverter.GetBytes(lo).CopyTo(req, 8); BitConverter.GetBytes(hi).CopyTo(req, 12); BitConverter.GetBytes(id).CopyTo(req, 16);
        if (GetInfo(req) != 0) return "";
        string s = Encoding.Unicode.GetString(req, 164, 256); int z = s.IndexOf('\0'); return z >= 0 ? s.Substring(0, z) : s;
    }

    // Where the screen named by a note ("adapterLow|adapterHigh|target|device|monitor path") is now. Windows numbers the
    // graphics adapters anew at every start, so the adapter in a note that outlived a restart (the PC was restarted while
    // locked) means nothing any more: the screen is then found again by its monitor path, as the same target on whichever
    // adapter answers with that path. Measured in the test VM: without this, such a screen stayed off the desktop for good.
    static void Address(string[] h, out uint lo, out int hi, out uint id) {
        lo = uint.Parse(h[0]); hi = int.Parse(h[1]); id = uint.Parse(h[2]);
        if (h.Length < 5 || h[4].Length == 0 || OffDesktop(lo, hi, id) != null) return;
        uint np; byte[] paths = Paths(1, out np); HashSet<long> tried = new HashSet<long>();
        for (int i = 0; i < np; i++) {   // every adapter shows up in the list of all paths, even when its screen itself is hidden from it
            long luid = BitConverter.ToInt64(paths, 72 * i);
            if (!tried.Add(luid)) continue;
            if (MonitorPath((uint)luid, (int)(luid >> 32), id) == h[4]) { lo = (uint)luid; hi = (int)(luid >> 32); return; }
        }
    }

    // The highest-numbered screen of the desktop (\\.\DISPLAYn) and the monitor behind it. Returns the number of screens.
    static int LastScreen(out uint lo, out int hi, out uint id, out string device) {
        lo = 0; hi = 0; id = 0; device = null;
        uint np; byte[] paths = Paths(2, out np);
        int best = -1; HashSet<string> screens = new HashSet<string>();
        for (int i = 0; i < np; i++) {
            int o = 72 * i;
            byte[] req = new byte[84];   // DISPLAYCONFIG_SOURCE_DEVICE_NAME: header (type 1, size, adapter LUID, id) + WCHAR[32]
            BitConverter.GetBytes(1).CopyTo(req, 0); BitConverter.GetBytes(84).CopyTo(req, 4);
            Buffer.BlockCopy(paths, o, req, 8, 8); Buffer.BlockCopy(paths, o + 8, req, 16, 4);
            if (GetInfo(req) != 0) continue;
            string name = Encoding.Unicode.GetString(req, 20, 64); int z = name.IndexOf('\0'); if (z >= 0) name = name.Substring(0, z);
            screens.Add(name);
            int p = name.Length; while (p > 0 && char.IsDigit(name[p - 1])) p--;
            int n; if (!int.TryParse(name.Substring(p), out n)) continue;
            if (n > best) { best = n; device = name; lo = BitConverter.ToUInt32(paths, o + 20); hi = BitConverter.ToInt32(paths, o + 24); id = BitConverter.ToUInt32(paths, o + 28); }
        }
        return screens.Count;
    }

    static void Take(RegistryKey k, bool force) {
        string held = k.GetValue("Taken") as string, keep = k.GetValue("Keep") as string;
        uint lo, id; int hi; string device;
        if (held != null) {
            string[] h = held.Split('|'); Address(h, out lo, out hi, out id);
            bool? off = OffDesktop(lo, hi, id);
            // the note is stale if the screen was put back by hand meanwhile, or is gone and no longer the one to keep (monitors changed, setup run again)
            if (off == false || (off == null && h.Length > 4 && h[4] != keep)) k.DeleteValue("Taken", false);
            else { Log("take: already holding " + h[3]); return; }
        }
        if (!force && !Locked()) { Log("take: the PC is not locked (any more), nothing done"); return; }
        int screens = LastScreen(out lo, out hi, out id, out device);
        if (screens < 2 || device == null) { Log("take: " + screens + " screen(s) on the desktop, nothing to keep"); return; }
        string path = MonitorPath(lo, hi, id);
        // Only ever one and the same monitor: the one taken first after the setup. When that one is switched off or
        // unplugged, the next screen in line must not stay visible in its place while the PC is locked.
        if (keep != null && keep != path) {
            Log("take: " + device + " is not the screen kept so far (that one is not connected, or the monitors were changed), so nothing stays on at this lock. To keep another screen from now on, run Install-Auto.ps1 again");
            return;
        }
        int rc = Set(lo, hi, id, true);
        if (rc != 0) { Log("take: Windows refused " + device + ", error " + rc); return; }
        k.SetValue("Taken", lo + "|" + hi + "|" + id + "|" + device + "|" + path);   // the routine case is not logged here: the agent's log has it
        if (keep == null) k.SetValue("Keep", path);
        // Unlocked again while this ran? The unlock event's -give waits for this run to finish, so it would put the
        // screen back anyway; doing it here returns the screen a moment sooner and does not depend on that second start.
        if (!force && !Locked()) { Log("take: the PC was unlocked meanwhile"); Give(k); }
    }

    static void Give(RegistryKey k) {
        string held = k.GetValue("Taken") as string;
        if (held == null) return;
        string[] h = held.Split('|'); uint lo, id; int hi; Address(h, out lo, out hi, out id);
        int rc = 0;
        for (int i = 0; i < 40; i++) {   // 10 s: the picture program lets go of the screen within a fraction of a second after the unlock
            rc = Set(lo, hi, id, false);
            bool? off = OffDesktop(lo, hi, id);
            if (rc == 0 || off == false) { k.DeleteValue("Taken", false); return; }
            if (off == null) {   // unplugged or switched off: nothing to wait for. Windows remembers "off the desktop" for it (measured), so the note stays.
                Log("give: " + h[3] + " is not connected right now (error " + rc + "). It is put back as soon as it is there again");
                return;
            }
            Thread.Sleep(250);
        }
        Log("give: Windows refused to put " + h[3] + " back, error " + rc + ". It is tried again while the PC is unlocked, at the next unlock and at sign-in. By hand: Settings > System > Display > Advanced display > Remove display from desktop = Off");
    }

    static int Main(string[] args) {
        logFile = Path.Combine(Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location), "switch.log");
        try {
            bool take = Array.IndexOf(args, "-take") >= 0, give = Array.IndexOf(args, "-give") >= 0, force = Array.IndexOf(args, "-force") >= 0;
            if (Array.IndexOf(args, "-list") >= 0) {   // read-only, needs no rights: which screen would -take choose?  (Switch-LastScreen.exe -list | more)
                uint lo, id; int hi; string device, keep; int screens = LastScreen(out lo, out hi, out id, out device);
                using (RegistryKey hklm = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64))
                using (RegistryKey k = hklm.OpenSubKey(@"SOFTWARE\LockMonitor")) keep = k == null ? null : k.GetValue("Keep") as string;
                Console.WriteLine(screens + " screen(s) on the desktop; highest-numbered: " + (device ?? "none") + (device == null ? "" : "  (adapter " + hi + ":" + lo + ", target " + id + ", off the desktop now: " + OffDesktop(lo, hi, id) + ", can be handed to a program: " + Possible(lo, hi, id) + ")") + "; PC locked: " + Locked()
                    + "; screen kept at lock: " + (keep == null ? "the one taken at the next lock" : device != null && keep == MonitorPath(lo, hi, id) ? "this one" : "not this one but " + keep));
                return 0;
            }
            if (!take && !give) return 2;
            // one run at a time: a -give started by the unlock event must see the note a still-running -take is about to write
            using (Mutex one = new Mutex(false, @"Global\LockMonitor.SwitchLastScreen")) {
                bool mine = false;
                try { mine = one.WaitOne(20000); } catch (AbandonedMutexException) { mine = true; }
                if (!mine) { Log("another run is stuck; nothing done"); return 3; }
                try {
                    using (RegistryKey hklm = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64))
                    using (RegistryKey k = hklm.CreateSubKey(@"SOFTWARE\LockMonitor")) {
                        if (take) Take(k, force);
                        if (give) Give(k);
                    }
                } finally { one.ReleaseMutex(); }
            }
            return 0;
        } catch (Exception e) { Log("ERROR " + e.Message); return 1; }
    }
}
