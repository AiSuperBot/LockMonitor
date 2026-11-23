// Elevated helper. Install-Auto.ps1 puts it into "%ProgramFiles%\LockMonitor\Switch-LastScreen.exe" and has Windows
// start it on its own lock and unlock events. It does one thing: at lock it takes the highest-numbered screen off the
// Windows desktop (-take), at unlock it puts it back (-give). It uses the switch behind
// Settings > System > Display > Advanced display > "Remove display from desktop" (see Set). The lock itself is not
// touched and nothing else runs elevated: the picture is produced by LockMonitor-Agent.exe (Agent.cs), unelevated.
// Its log (switch.log next to it) has only what is out of the ordinary; the routine is in the agent's log.
//
// It is a program of its own, not a script, on purpose: it runs elevated on every lock, so it should start in
// milliseconds and depend on nothing a non-administrator can change (no script host, no module or temp folders, no
// environment variables). Its log and its notes (Common.Notes) live where only administrators can write.
using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32;

[assembly: AssemblyTitle("LockMonitor helper: takes the kept screen off the desktop at lock, returns it at unlock")]

static class SwitchLastScreen {
    [DllImport("user32.dll")] static extern int DisplayConfigSetDeviceInfo(byte[] request);


    static string logFile;
    static void Log(string m) { Common.Log(logFile, m); }

    static readonly Guid Pseudo = new Guid("f196c02f-f86f-4f9a-aa15-e9cebdfe3b96");   // wingdi.h: GUID_MONITOR_OVERRIDE_PSEUDO_SPECIALIZED

    // 0 = done; needs elevation. First the documented request (SET_MONITOR_SPECIALIZATION = 13, 312 bytes), which
    // Windows 11 takes with exactly this type GUID, an empty sub type and a non-empty application name (found by
    // experiment in the test VM). Windows 10 does not know it: error 87 for every monitor (measured on 19045). Then the
    // request Windows' own Settings sends for that switch, on Windows 10 and 11 alike (its elevated helper,
    // SystemSettingsAdminFlows.exe SpecializeDisplay; read from that program and from its command line in the test VMs):
    // type -23, 48 bytes: the GUID, on/off, and a value Windows checks against the monitor: the monitor's ID from
    // Common.Report followed by "{GUID}", hashed like RtlHashUnicodeString (case-insensitive X65599), the first half of
    // the characters giving the low 32 bits, the rest the high 32 bits (it matched Settings' value; with any other value
    // Windows answers 87, Settings' own helper included).
    static int Set(uint lo, int hi, uint id, bool on) {
        byte[] r = Common.Request(13, 312, lo, hi, id);
        BitConverter.GetBytes(on ? 1 : 0).CopyTo(r, 20); Pseudo.ToByteArray().CopyTo(r, 24); Encoding.Unicode.GetBytes("LockMonitor").CopyTo(r, 56);
        int rc = DisplayConfigSetDeviceInfo(r);
        byte[] report;
        if (rc != 87 || (report = Common.Report(lo, hi, id)) == null) return rc;
        string s = Common.Text(report, 20, 256) + "{" + Pseudo.ToString().ToUpperInvariant() + "}";
        r = Common.Request(-23, 48, lo, hi, id);
        Pseudo.ToByteArray().CopyTo(r, 20); BitConverter.GetBytes(on ? 1 : 0).CopyTo(r, 36);
        BitConverter.GetBytes((ulong)Hash(s.Substring(s.Length / 2)) << 32 | Hash(s.Substring(0, s.Length / 2))).CopyTo(r, 40);
        return DisplayConfigSetDeviceInfo(r);
    }
    static uint Hash(string s) { uint h = 0; foreach (char c in s) h = h * 65599 + char.ToUpperInvariant(c); return h; }

    // The highest-numbered screen of the desktop (\\.\DISPLAYn) and the monitor behind it. Returns the number of screens.
    static int LastScreen(out uint lo, out int hi, out uint id, out string device) {
        lo = 0; hi = 0; id = 0; device = null;
        int best = -1; HashSet<string> screens = new HashSet<string>();
        foreach (Common.Screen s in Common.Screens()) {
            screens.Add(s.Device);
            int n = Common.Number(s.Device);
            if (n > best) { best = n; device = s.Device; lo = s.Lo; hi = s.Hi; id = s.Id; }
        }
        return screens.Count;
    }

    static void Take(RegistryKey k, bool force) {
        string held = k.GetValue("Taken") as string, keep = k.GetValue("Keep") as string;
        uint lo, id; int hi; string device;
        if (held != null) {
            bool? off; string[] h = Common.Address(held, out lo, out hi, out id, out off);
            // the note is stale if the screen was put back by hand meanwhile, or is gone and no longer the one to keep (monitors changed, setup run again)
            if (off == false || (off == null && h.Length > 4 && h[4] != keep)) k.DeleteValue("Taken", false);
            else { Log("take: already holding " + h[3]); return; }
        }
        if (!force && !Common.Locked()) { Log("take: the PC is not locked (any more), nothing done"); return; }
        int screens = LastScreen(out lo, out hi, out id, out device);
        if (screens < 2 || device == null) { Log("take: " + screens + " screen(s) on the desktop, nothing to keep"); return; }
        string path = Common.MonitorPath(lo, hi, id);
        // without the monitor's own path it could neither be told apart from others nor found again after a restart
        if (path.Length == 0) { Log("take: Windows names no monitor behind " + device + ", so nothing stays on at this lock"); return; }
        // Only ever one and the same monitor: the one taken first after the setup. When that one is switched off or
        // unplugged, the next screen in line must not stay visible in its place while the PC is locked.
        if (keep != null && keep != path) {
            Log("take: " + device + " is not the screen kept so far (that one is not connected, or the monitors were changed), so nothing stays on at this lock. To keep another screen from now on, run Install-Auto.ps1 again");
            return;
        }
        int rc = Set(lo, hi, id, true);
        if (rc != 0) { Log("take: Windows refused " + device + ", error " + rc + " (" + Common.Describe(lo, hi, id) + ")"); return; }   // its own answer for that monitor says why
        k.SetValue("Taken", lo + "|" + hi + "|" + id + "|" + device + "|" + path);   // the routine case is not logged here: the agent's log has it
        if (keep == null) k.SetValue("Keep", path);
        // Unlocked again while this ran? The unlock event's -give waits for this run to finish, so it would put the
        // screen back anyway; doing it here returns the screen a moment sooner and does not depend on that second start.
        if (!force && !Common.Locked()) { Log("take: the PC was unlocked meanwhile"); Give(k); }
    }

    static void Give(RegistryKey k) {
        string held = k.GetValue("Taken") as string;
        if (held == null) return;
        uint lo, id; int hi; string[] h = Common.Address(held, out lo, out hi, out id);
        int rc = 0;
        for (int i = 0; i < 100; i++) {   // 10 s: the picture program lets go of the screen within a fraction of a second after the unlock
            rc = Set(lo, hi, id, false);
            bool? off = Common.OffDesktop(lo, hi, id);
            if (rc == 0 || off == false) { k.DeleteValue("Taken", false); return; }
            if (off == null) {   // unplugged or switched off: nothing to wait for. Windows remembers "off the desktop" for it (measured), so the note stays.
                Log("give: " + h[3] + " is not connected right now (error " + rc + "). It is put back as soon as it is there again");
                return;
            }
            Thread.Sleep(100);
        }
        Log("give: Windows refused to put " + h[3] + " back, error " + rc + ". It is tried again while the PC is unlocked, at the next unlock and at sign-in. By hand: Settings > System > Display > Advanced display > Remove display from desktop = Off");
    }

    static int Main(string[] args) {
        logFile = Path.Combine(Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location), "switch.log");
        try {
            bool take = Array.IndexOf(args, "-take") >= 0, give = Array.IndexOf(args, "-give") >= 0, force = Array.IndexOf(args, "-force") >= 0;
            if (Array.IndexOf(args, "-list") >= 0) {   // read-only, needs no rights: which screen would -take choose?  (Switch-LastScreen.exe -list | more)
                uint lo, id; int hi; string device; int screens = LastScreen(out lo, out hi, out id, out device);
                string keep = Common.Note("Keep") as string;
                Console.WriteLine(screens + " screen(s) on the desktop; highest-numbered: " + (device ?? "none") + (device == null ? "" : "  (adapter " + hi + ":" + lo + ", target " + id + ", " + Common.Describe(lo, hi, id) + ")") + "; PC locked: " + Common.Locked()
                    + "; screen kept at lock: " + (keep == null ? "the one taken at the next lock" : device != null && keep == Common.MonitorPath(lo, hi, id) ? "this one" : "not this one but " + keep));
                return 0;
            }
            if (!take && !give) return 2;
            // one run at a time: a -give started by the unlock event must see the note a still-running -take is about to write
            using (Mutex one = new Mutex(false, @"Global\LockMonitor.SwitchLastScreen")) {
                bool mine = false;
                try { mine = one.WaitOne(20000); } catch (AbandonedMutexException) { mine = true; }
                if (!mine) { Log("another run is stuck; nothing done"); return 3; }
                try {
                    using (RegistryKey k = Common.Notes(true)) {
                        if (take) Take(k, force);
                        if (give) Give(k);
                    }
                } finally { one.ReleaseMutex(); }
            }
            return 0;
        } catch (Exception e) { Log("ERROR " + e.Message); return 1; }
    }
}
