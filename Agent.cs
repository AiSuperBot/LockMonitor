// LockMonitor agent. Install-Auto.ps1 compiles it to "%ProgramFiles%\LockMonitor\LockMonitor-Agent.exe" and has Windows
// start it at sign-in with the user's normal rights. It waits and holds nothing. While the PC is unlocked it only notes
// which windows are on the highest-numbered screen. At Win+L the elevated helper (Switch-LastScreen.exe, started by
// Windows' own lock event) takes that screen off the Windows desktop; this program then owns the screen and redraws the
// noted windows on it, live, until the PC is unlocked. Then the helper puts the screen back.
//
// The lock itself is not touched: no Windows file is patched, Win+L is not intercepted, nothing imitates the lock
// screen. The kept screen shows pictures only: it has no pointer, no focus and takes no input. Windows are read, never
// typed or clicked into; the one thing done to them is to give them back the size they had (see Pix.GiveBackSizes).
//
//   LockMonitor-Agent.exe                     the agent (no window). Log: %LOCALAPPDATA%\LockMonitor\log.txt
//   LockMonitor-Agent.exe -selftest | more    checks this PC's graphics and window capture; changes nothing
//   LockMonitor-Agent.exe -frames <folder>    test: the agent, but the pictures go to PNG files instead of the screen
//
// Needs Windows 10 2004+ or 11 in the Enterprise, Pro for Workstations or IoT Enterprise edition (only these hand a
// screen to a program) and a WDDM 2.x display driver. "Measured" in a comment means: seen in the test VM or on real PCs.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32;
using Windows.Devices.Display;
using Windows.Devices.Display.Core;
using Windows.Graphics;
using Windows.Graphics.DirectX;
using Windows.Graphics.DirectX.Direct3D11;

// shown in the file's Properties > Details, and in the log at every start
[assembly: AssemblyTitle("LockMonitor agent: keeps one screen's windows showing while Windows is locked")]
[assembly: AssemblyProduct("LockMonitor")]
[assembly: AssemblyVersion("0.2.1")]
[assembly: AssemblyFileVersion("0.2.1")]

// Windows is still busy with the screen (it only just left the desktop): worth asking again at once.
public class NotReady : Exception { public NotReady(string message) : base(message) { } }

// windows.devices.display.core.interop.h: derives from IUnknown (not IInspectable), so CreateSharedHandle is slot 3.
[ComImport, Guid("64338358-366A-471B-BD56-DD8EF48E439B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IDisplayDeviceInterop {
    [PreserveSig] int CreateSharedHandle([MarshalAs(UnmanagedType.IUnknown)] object o, IntPtr sa, uint access, IntPtr name, out IntPtr handle);
    [PreserveSig] int OpenSharedHandle(IntPtr h, ref Guid riid, [MarshalAs(UnmanagedType.IUnknown)] out object o);
}

public static class Spec {   // DisplayConfigGetDeviceInfo(GET_MONITOR_SPECIALIZATION = 12): read-only
    [StructLayout(LayoutKind.Sequential)] struct Req { public int type, size; public uint lo; public int hi; public uint id, flags; }
    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref Req r);
    static int Flags(uint lo, int hi, uint id, out uint flags) {
        Req r = new Req(); r.type = 12; r.size = Marshal.SizeOf(typeof(Req)); r.lo = lo; r.hi = hi; r.id = id;
        int rc = DisplayConfigGetDeviceInfo(ref r); flags = r.flags; return rc;
    }
    // what Windows says about handing this screen to a program: is it off the desktop now, can this monitor be, can this Windows at all
    public static string Get(uint lo, int hi, uint id) {
        uint f; int rc = Flags(lo, hi, id, out f);
        return rc != 0 ? "unknown (error " + rc + ")" : "off the desktop=" + (f & 1) + ", possible for this monitor=" + ((f >> 1) & 1) + ", possible on this Windows=" + ((f >> 2) & 1);
    }
    public static bool Off(uint lo, int hi, uint id) { uint f; return Flags(lo, hi, id, out f) == 0 && (f & 1) != 0; }   // connected and off the desktop
}

public static class Pwr {   // ES_CONTINUOUS 0x80000000 | ES_SYSTEM_REQUIRED 1 | ES_DISPLAY_REQUIRED 2; holds for the calling thread
    [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint f);
    // Windows has one display-power switch for all screens and blanks them a minute after locking: while a picture is
    // shown, the PC is kept awake and the displays on (measured: the request holds through the lock). false = refused.
    public static bool Keep(bool on) { return SetThreadExecutionState(on ? 0x80000003u : 0x80000000u) != 0; }
}

// One picture, kept as a plain Windows bitmap (DIB section): window pictures are copied into it by Windows' own bitmap
// routines and the GPU reads it from there, with no conversions in between. Gdi is a System.Drawing view of the same
// memory, for text.
public class Frame : IDisposable {
    [StructLayout(LayoutKind.Sequential)] struct BITMAPINFOHEADER { public int size, width, height; public short planes, bitCount; public int compression, sizeImage, xppm, yppm, clrUsed, clrImportant; }
    [DllImport("gdi32.dll")] static extern IntPtr CreateDIBSection(IntPtr hdc, ref BITMAPINFOHEADER bmi, uint usage, out IntPtr bits, IntPtr section, uint offset);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr obj);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern bool PatBlt(IntPtr dc, int x, int y, int w, int h, uint rop);
    [DllImport("gdi32.dll")] static extern bool GdiFlush();
    [DllImport("msvcrt.dll", CallingConvention = CallingConvention.Cdecl)] static extern int memcmp(IntPtr a, IntPtr b, UIntPtr n);
    [DllImport("kernel32.dll", EntryPoint = "RtlMoveMemory")] static extern void CopyMemory(IntPtr dst, IntPtr src, UIntPtr n);

    public readonly int W, H, Stride;
    public readonly IntPtr Bits, Dc;
    public readonly Bitmap Gdi;
    IntPtr dib, old, last; bool gone;

    public Frame(int w, int h) {
        W = w; H = h; Stride = w * 4;
        BITMAPINFOHEADER bi = new BITMAPINFOHEADER(); bi.size = 40; bi.width = w; bi.height = -h; bi.planes = 1; bi.bitCount = 32;   // negative height: first row on top
        dib = CreateDIBSection(IntPtr.Zero, ref bi, 0, out Bits, IntPtr.Zero, 0);
        if (dib == IntPtr.Zero) throw new OutOfMemoryException("no memory for a " + w + "x" + h + " picture");
        Dc = CreateCompatibleDC(IntPtr.Zero); old = SelectObject(Dc, dib);
        Gdi = new Bitmap(w, h, Stride, PixelFormat.Format32bppRgb, Bits);
    }
    public void Clear() { PatBlt(Dc, 0, 0, W, H, 0x42); }   // 0x42 = BLACKNESS

    // true when the picture differs from the one at the previous call (always true the first time)
    public bool Changed() {
        GdiFlush();   // Windows may still be holding drawing back; the memory is read directly below
        UIntPtr n = (UIntPtr)(ulong)((long)Stride * H);
        if (last == IntPtr.Zero) last = Marshal.AllocHGlobal((IntPtr)((long)Stride * H));
        else if (memcmp(Bits, last, n) == 0) return false;
        CopyMemory(last, Bits, n); return true;
    }
    public void Dispose() {
        if (gone) return; gone = true;
        Gdi.Dispose();
        SelectObject(Dc, old); DeleteDC(Dc); DeleteObject(dib);
        if (last != IntPtr.Zero) Marshal.FreeHGlobal(last);
    }
}

public static class Pix {
    // ---- the session: locked or not, and the helper's notes ----
    [DllImport("wtsapi32.dll")] static extern bool WTSQuerySessionInformation(IntPtr server, int session, int infoClass, out IntPtr buf, out int bytes);
    [DllImport("wtsapi32.dll")] static extern void WTSFreeMemory(IntPtr p);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("psapi.dll")] static extern bool EmptyWorkingSet(IntPtr process);
    // Windows' own lock flag: WTSSessionInfoEx (25), SessionFlags at offset 16, 0 = locked, 1 = unlocked, -1 here = Windows
    // did not answer. Whether the input desktop can be opened is no test: Windows draws the lock-screen picture on the
    // user's own desktop (measured).
    public static int Flags() { IntPtr p; int n; if (!WTSQuerySessionInformation(IntPtr.Zero, -1, 25, out p, out n)) return -1; int f = Marshal.ReadInt32(p, 16); WTSFreeMemory(p); return f; }
    // Two definite answers; when Windows cannot say, both are false.
    // Locked() decides about holding a screen and drawing on it: anything but a definite "locked" stops that.
    // Unlocked() decides about asking for a held screen to be put back: only a definite "unlocked" does that.
    public static bool Locked() { return Flags() == 0; }
    public static bool Unlocked() { return Flags() == 1; }

    // A note of the elevated side in HKLM\SOFTWARE\LockMonitor (only administrators can write there); null if absent.
    static object Note(string name) {
        using (RegistryKey hklm = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64))
        using (RegistryKey k = hklm.OpenSubKey(@"SOFTWARE\LockMonitor")) { return k == null ? null : k.GetValue(name); }
    }
    // The screen the helper holds off the desktop right now, as "adapterLow|adapterHigh|target|device|monitor path"; null if none.
    public static string Taken() { return Note("Taken") as string; }

    // ---- windows: finding them and getting their live picture ----
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int l, t, r, b; }
    delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")] static extern int GetWindowLong(IntPtr h, int index);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int size);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int v, int size);
    [DllImport("gdi32.dll")] static extern bool BitBlt(IntPtr dst, int x, int y, int w, int h, IntPtr src, int sx, int sy, uint rop);
    [DllImport("gdi32.dll")] static extern int SetStretchBltMode(IntPtr dc, int mode);
    [DllImport("gdi32.dll")] static extern bool SetBrushOrgEx(IntPtr dc, int x, int y, IntPtr prev);
    [DllImport("gdi32.dll")] static extern bool StretchBlt(IntPtr dst, int x, int y, int w, int h, IntPtr src, int sx, int sy, int sw, int sh, uint rop);
    [DllImport("gdi32.dll")] static extern bool GdiFlush();

    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
    [DllImport("shcore.dll")] static extern int GetDpiForMonitor(IntPtr hmon, int type, out uint dpiX, out uint dpiY);
    // sizes and pictures in real pixels on every screen, whatever its scaling (-4 = per-monitor aware v2; older Windows lacks it)
    public static void DpiAware() {
        try { if (!SetProcessDpiAwarenessContext(new IntPtr(-4))) SetThreadDpiAwarenessContext(new IntPtr(-4)); } catch (EntryPointNotFoundException) { }
    }

    // The part of a window that is really visible, in screen pixels. Windows adds an invisible resize border around
    // windows; the compositor knows the true outline (9 = DWMWA_EXTENDED_FRAME_BOUNDS).
    static bool Outline(IntPtr hwnd, out RECT whole, out RECT seen) {
        seen = new RECT();
        if (!GetWindowRect(hwnd, out whole) || whole.r <= whole.l || whole.b <= whole.t) return false;
        RECT f;
        if (DwmGetWindowAttribute(hwnd, 9, out f, 16) == 0 && f.r > f.l && f.b > f.t) {
            seen.l = Math.Max(f.l, whole.l); seen.t = Math.Max(f.t, whole.t); seen.r = Math.Min(f.r, whole.r); seen.b = Math.Min(f.b, whole.b);
            if (seen.r > seen.l && seen.b > seen.t) return true;
        }
        seen = whole; return true;
    }
    public static Rectangle Visible(IntPtr hwnd) { RECT w, s; return Outline(hwnd, out w, out s) ? Rectangle.FromLTRB(s.l, s.t, s.r, s.b) : Rectangle.Empty; }

    static Frame scratch;
    // Draw a window's visible part into the box (x, y, w, h) of dst. Same size as the box: copied pixel for pixel.
    // Any other size: fitted into the box, keeping its proportions. false when the window has no picture.
    // 2 = PW_RENDERFULLCONTENT: the picture comes from the window compositor, so GPU-drawn apps (Chrome) work and the
    // window may be covered by others. Measured: it keeps delivering fresh pictures while locked. Measured too: it
    // always draws the whole window at the top-left corner of the bitmap, ignoring the DC's origin and clipping. Hence
    // the detour through a bitmap of its own, from which the visible part is copied into place.
    static bool Blit(IntPtr hwnd, Frame dst, int x, int y, int w, int h) {
        RECT whole, seen;
        if (w <= 0 || h <= 0 || !Outline(hwnd, out whole, out seen)) return false;
        int ww = whole.r - whole.l, wh = whole.b - whole.t, fx = seen.l - whole.l, fy = seen.t - whole.t, fw = seen.r - seen.l, fh = seen.b - seen.t;
        if (scratch == null || scratch.W < ww || scratch.H < wh) {   // kept between pictures, grown when a bigger window comes along
            int nw = Math.Max(ww, scratch == null ? 0 : scratch.W), nh = Math.Max(wh, scratch == null ? 0 : scratch.H);
            if (scratch != null) scratch.Dispose();
            scratch = new Frame(nw, nh);
        }
        if (!PrintWindow(hwnd, scratch.Dc, 2)) return false;
        if (fw == w && fh == h) return BitBlt(dst.Dc, x, y, w, h, scratch.Dc, fx, fy, 0x00CC0020);   // SRCCOPY
        double k = Math.Min((double)w / fw, (double)h / fh);
        int tw = Math.Max(1, (int)Math.Round(fw * k)), th = Math.Max(1, (int)Math.Round(fh * k));
        SetStretchBltMode(dst.Dc, 4); SetBrushOrgEx(dst.Dc, 0, 0, IntPtr.Zero);   // 4 = HALFTONE: averages pixels when shrinking
        return StretchBlt(dst.Dc, x + (w - tw) / 2, y + (h - th) / 2, tw, th, scratch.Dc, fx, fy, fw, fh, 0x00CC0020);
    }

    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hgt, uint flags);
    // Windows shrinks or un-maximizes windows when it moves them to another screen (measured: a maximized browser arrived
    // there in its smaller, restored size; enlarged to fit, it looked like a lower resolution). So every noted window is
    // asked to take the size it had on its screen, in the corner of the screen it is on now (measured: a browser will not
    // reach past the screen's edge from where Windows put it); nobody sees the desktop while the PC is locked.
    // This is the only thing this program ever does to a window. It asks without waiting (0x4000), so a window that does
    // not answer cannot hold the pictures up, and at most 3 times: one that will not take the size is fitted instead.
    // When the screen returns, Windows itself puts each window back exactly as it was (measured: maximized again, and
    // its un-maximized place and size untouched).
    public static void GiveBackSizes(Snap s) {
        foreach (Win w in s.Wins) {
            RECT whole, seen;
            if (w.Asked >= 3 || !IsWindow(w.H) || IsIconic(w.H) || !Outline(w.H, out whole, out seen)) continue;
            int sw = seen.r - seen.l, sh = seen.b - seen.t;
            if (sw == w.W && sh == w.Hgt) continue;
            MONITORINFOEX mi = new MONITORINFOEX(); mi.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
            if (!GetMonitorInfo(MonitorFromWindow(w.H, 2), ref mi)) continue;   // 2 = the nearest screen
            w.Asked++;   // place and size include the invisible border the window has now; 4 = same stacking, 0x10 = no focus
            SetWindowPos(w.H, IntPtr.Zero, mi.mon.l - (seen.l - whole.l), mi.mon.t - (seen.t - whole.t), w.W + (whole.r - whole.l - sw), w.Hgt + (whole.b - whole.t - sh), 0x4000 | 0x4 | 0x10);
        }
    }

    // What was on the screen: its windows, top-most first, in the screen's own pixels. Check = not a lock but the setup's test.
    public class Win { public IntPtr H; public int X, Y, W, Hgt, Asked; public string Title; }
    // Scale: the screen's display scaling in percent; OtherScale: that of another desktop screen when it differs, else 0.
    public class Snap { public string Device; public int W, H, Scale, OtherScale; public List<Win> Wins = new List<Win>(); public bool Check; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct MONITORINFOEX { public int cbSize; public RECT mon, work; public uint flags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string device; }
    delegate bool MonProc(IntPtr hm, IntPtr dc, IntPtr rc, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, MonProc cb, IntPtr data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr hm, ref MONITORINFOEX mi);

    // The highest-numbered screen of the desktop (\\.\DISPLAYn) and the app windows on it.
    // null when the desktop has a single screen: there is nothing to keep then.
    public static Snap Snapshot() {
        IntPtr best = IntPtr.Zero; int bestN = -1, count = 0; MONITORINFOEX bm = new MONITORINFOEX();
        Dictionary<IntPtr, int> scale = new Dictionary<IntPtr, int>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (hm, dc, rc, d) => {
            MONITORINFOEX mi = new MONITORINFOEX(); mi.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
            if (!GetMonitorInfo(hm, ref mi)) return true;
            count++;
            uint dx, dy; scale[hm] = GetDpiForMonitor(hm, 0, out dx, out dy) == 0 ? (int)Math.Round(dx * 100.0 / 96) : 0;   // 0 = effective DPI; 96 is 100%
            int p = mi.device.Length; while (p > 0 && char.IsDigit(mi.device[p - 1])) p--;
            int n; if (int.TryParse(mi.device.Substring(p), out n) && n > bestN) { bestN = n; best = hm; bm = mi; }
            return true;
        }, IntPtr.Zero);
        if (best == IntPtr.Zero || count < 2) return null;
        Snap s = new Snap(); s.Device = bm.device; s.W = bm.mon.r - bm.mon.l; s.H = bm.mon.b - bm.mon.t; s.Scale = scale[best];
        foreach (int other in scale.Values) if (other != s.Scale && other != 0 && s.Scale != 0) s.OtherScale = other;
        StringBuilder text = new StringBuilder(256);
        EnumWindows((h, p) => {   // cheapest tests first: most of the hundreds of top-level windows fall out on the first line
            if (!IsWindowVisible(h) || IsIconic(h) || MonitorFromWindow(h, 0) != best) return true;
            if ((GetWindowLong(h, -20) & 0x20) != 0) return true;   // WS_EX_TRANSPARENT: click-through overlays (GPU vendor overlays, screen dimmers) are not content
            int cloaked; if (DwmGetWindowAttribute(h, 14, out cloaked, 4) == 0 && cloaked != 0) return true;   // hidden by Windows (other virtual desktop, suspended app)
            text.Length = 0; GetClassName(h, text, 256); string cls = text.ToString();
            if (cls == "Progman" || cls == "WorkerW" || cls == "Shell_TrayWnd" || cls == "Shell_SecondaryTrayWnd") return true;   // wallpaper and taskbars
            text.Length = 0; GetWindowText(h, text, 256); if (text.Length == 0) return true;
            RECT whole, seen; if (!Outline(h, out whole, out seen)) return true;
            Win w = new Win(); w.H = h; w.X = seen.l - bm.mon.l; w.Y = seen.t - bm.mon.t; w.W = seen.r - seen.l; w.Hgt = seen.b - seen.t; w.Title = text.ToString();
            s.Wins.Add(w); return true;
        }, IntPtr.Zero);
        return s;
    }

    // Redraw the noted screen: every window's live picture at the place it had, stacked as it was. Returns how many were
    // drawn. Windows moved these windows to another screen when this one left the desktop; they are drawn where they were.
    public static int CaptureWindows(Snap s, Frame dst) {
        dst.Clear();
        double k = Math.Min((double)dst.W / s.W, (double)dst.H / s.H);   // one factor for both directions: nothing gets stretched
        double ox = (dst.W - s.W * k) / 2, oy = (dst.H - s.H * k) / 2; int drawn = 0;
        for (int i = s.Wins.Count - 1; i >= 0; i--) {   // bottom-most first
            Win w = s.Wins[i];
            if (!IsWindow(w.H) || IsIconic(w.H)) continue;
            if (Blit(w.H, dst, (int)Math.Round(ox + w.X * k), (int)Math.Round(oy + w.Y * k), (int)Math.Round(w.W * k), (int)Math.Round(w.Hgt * k))) drawn++;
        }
        GdiFlush();
        return drawn;
    }

    public static void Notice(Frame b, string text) {
        using (Graphics g = Graphics.FromImage(b.Gdi))
        using (Font f = new Font("Segoe UI", b.H / 28f, GraphicsUnit.Pixel))
        using (Brush w = new SolidBrush(Color.FromArgb(200, 200, 200))) {
            g.Clear(Color.FromArgb(16, 24, 40));
            g.DrawString(text + "\n" + DateTime.Now.ToString("HH:mm:ss"), f, w, 40, 40);
        }
    }

    static Snap noted, latest;
    // Sleeps while the PC is unlocked, noting every 0.7 s what is on the last screen, and returns the note when the PC
    // gets locked: the note from one round earlier, because the newest one may already contain the lock screen.
    // Nothing is noted while the helper holds a screen off the desktop (the "last" screen would be the wrong one).
    // With mayCheck it also returns, as a note with Check set, when the setup asks for its test (see Agent.Check).
    public static Snap WaitForLock(bool mayCheck) {
        GC.Collect(); EmptyWorkingSet(GetCurrentProcess());   // this wait lasts hours: hand back the memory the last lock used
        int kept = 0;
        while (!Locked()) {
            string held = Taken();
            if (held == null) { kept = 0; noted = latest; latest = Snapshot(); }
            else if (mayCheck && Note("Check") != null) { Snap c = new Snap(); c.Check = true; return c; }
            else if (++kept >= 8 && Unlocked() && AskToGiveBack(held)) kept = -7;   // asked: allow 10 s before asking again
            Thread.Sleep(700);
        }
        return noted ?? latest ?? new Snap();
    }

    // The PC has been unlocked for 5 s and the helper still holds the screen: it was unplugged or switched off at the
    // moment of unlocking, so it could not be put back, and Windows remembers "off the desktop" for it (measured: it
    // would stay unused until the next unlock). Once it is connected again, ask Windows to run the give-back task; this
    // program has no rights to do that itself. true when asked.
    static bool AskToGiveBack(string held) {
        try {
            string[] h = held.Split('|');
            if (!Spec.Off(uint.Parse(h[0]), int.Parse(h[1]), uint.Parse(h[2]))) return false;
            ProcessStartInfo p = new ProcessStartInfo(Environment.SystemDirectory + @"\schtasks.exe", "/run /tn LockMonitor-Give");
            p.UseShellExecute = false; p.CreateNoWindow = true;
            using (Process.Start(p)) { }
            return true;
        } catch (Exception) { return false; }   // a note this program cannot read, or no schtasks: the next unlock puts the screen back
    }
    // The newest note may have been made while the lock was already starting: go on from the one known to be good.
    // And do not sit on a screen-sized bitmap until the next lock.
    public static void LockEnded() { latest = noted; if (scratch != null) { scratch.Dispose(); scratch = null; } }

    // Sleeps ms, but returns false at once when go says stop: at an unlock the screen must go back without delay.
    public static bool SleepWhile(Func<bool> go, int ms) {
        for (int left = ms; ; left -= 100) {
            if (!go()) return false;
            if (left <= 0) return true;
            Thread.Sleep(Math.Min(100, left));
        }
    }
}

// D3D11 on the adapter that owns the screen. COM is called through raw vtable slots (no SDK needed to build this);
// the self-test exercises every slot used.
public class Gfx : IDisposable {
    [StructLayout(LayoutKind.Sequential)] struct TexDesc { public uint W, H, Mips, ArraySize, Format, SampCount, SampQuality, Usage, Bind, Cpu, Misc; }
    [StructLayout(LayoutKind.Sequential)] struct Mapped { public IntPtr Data; public uint RowPitch, DepthPitch; }
    [StructLayout(LayoutKind.Sequential)] struct QDesc { public uint Query, Misc; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct AdapterDesc { [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Name; public uint Vendor, Device, SubSys, Rev; public IntPtr Vram, SysRam, SharedRam; public long Luid; }

    delegate int FnQI(IntPtr self, ref Guid iid, out IntPtr obj);
    delegate uint FnRel(IntPtr self);
    delegate int FnByLuid(IntPtr self, long luid, ref Guid iid, out IntPtr adapter);
    delegate int FnDesc(IntPtr self, out AdapterDesc d);
    delegate int FnOpen1(IntPtr self, IntPtr h, ref Guid iid, out IntPtr res);
    delegate int FnTex(IntPtr self, ref TexDesc d, IntPtr init, out IntPtr tex);
    delegate int FnQuery(IntPtr self, ref QDesc d, out IntPtr q);
    delegate int FnShare(IntPtr self, IntPtr attrs, uint access, IntPtr name, out IntPtr h);
    delegate void FnUpdate(IntPtr self, IntPtr res, uint sub, IntPtr box, IntPtr data, uint rowPitch, uint depthPitch);
    delegate void FnCopy(IntPtr self, IntPtr dst, IntPtr src);
    delegate int FnMap(IntPtr self, IntPtr res, uint sub, uint type, uint flags, out Mapped m);
    delegate void FnUnmap(IntPtr self, IntPtr res, uint sub);
    delegate void FnEnd(IntPtr self, IntPtr asyncObj);
    delegate int FnData(IntPtr self, IntPtr asyncObj, out int data, uint size, uint flags);
    delegate void FnTexDesc(IntPtr self, out TexDesc d);

    [DllImport("dxgi.dll")] static extern int CreateDXGIFactory1(ref Guid riid, out IntPtr factory);
    [DllImport("d3d11.dll")] static extern int D3D11CreateDevice(IntPtr adapter, int driverType, IntPtr software, uint flags, IntPtr levels, uint nLevels, uint sdk, out IntPtr dev, out int level, out IntPtr ctx);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

    static T Slot<T>(IntPtr obj, int slot) where T : class {
        IntPtr fn = Marshal.ReadIntPtr(Marshal.ReadIntPtr(obj), slot * IntPtr.Size);
        return (T)(object)Marshal.GetDelegateForFunctionPointer(fn, typeof(T));
    }
    static void Check(int hr, string what) { if (hr < 0) throw new COMException(what + " failed, HRESULT 0x" + hr.ToString("X8"), hr); }
    static void Release(IntPtr p) { if (p != IntPtr.Zero) Slot<FnRel>(p, 2)(p); }
    public static void Free(IntPtr comObject) { Release(comObject); }   // for the textures OpenSurface hands out

    public string AdapterName;
    IntPtr dev, dev1, ctx, query;
    FnOpen1 open1; FnTex createTex; FnUpdate update; FnCopy copy; FnMap map; FnUnmap unmap; FnEnd end; FnData getData;

    public Gfx(uint luidLow, int luidHigh) {
        Guid iidFactory4 = new Guid("1bc6ea02-ef36-464f-bf0c-21ca39e5168a"), iidAdapter = new Guid("2411e7e1-12ac-4ccf-bd14-9798e8534dc0"), iidDev1 = new Guid("a04bfb29-08ef-43d6-a49c-a9bdbdcbe686");
        IntPtr factory, adapter; int level;
        Check(CreateDXGIFactory1(ref iidFactory4, out factory), "CreateDXGIFactory1");
        Check(Slot<FnByLuid>(factory, 26)(factory, ((long)luidHigh << 32) | luidLow, ref iidAdapter, out adapter), "EnumAdapterByLuid");
        AdapterDesc ad; Check(Slot<FnDesc>(adapter, 8)(adapter, out ad), "GetDesc"); AdapterName = ad.Name;
        Check(D3D11CreateDevice(adapter, 0, IntPtr.Zero, 0x20, IntPtr.Zero, 0, 7, out dev, out level, out ctx), "D3D11CreateDevice");
        Release(adapter); Release(factory);
        Check(Slot<FnQI>(dev, 0)(dev, ref iidDev1, out dev1), "ID3D11Device1");
        open1 = Slot<FnOpen1>(dev1, 48); createTex = Slot<FnTex>(dev, 5);
        update = Slot<FnUpdate>(ctx, 48); copy = Slot<FnCopy>(ctx, 47); map = Slot<FnMap>(ctx, 14); unmap = Slot<FnUnmap>(ctx, 15);
        end = Slot<FnEnd>(ctx, 28); getData = Slot<FnData>(ctx, 29);
        QDesc q = new QDesc(); q.Query = 0;   // D3D11_QUERY_EVENT (0): lets the CPU wait until the GPU finished the upload
        Check(Slot<FnQuery>(dev, 24)(dev, ref q, out query), "CreateQuery");
    }

    IntPtr OpenHandle(IntPtr h) {
        Guid iidTex = new Guid("6f15aaf2-d208-4e89-9ab4-489535d34f9c"); IntPtr tex;
        Check(open1(dev1, h, ref iidTex, out tex), "OpenSharedResource1");
        return tex;
    }

    // DisplaySurface -> shareable D3D11 texture on this device. The caller releases it with Free.
    public IntPtr OpenSurface(object displayDevice, object surface) {
        IntPtr h;
        Check(((IDisplayDeviceInterop)displayDevice).CreateSharedHandle(surface, IntPtr.Zero, 0x10000000, IntPtr.Zero, out h), "IDisplayDeviceInterop.CreateSharedHandle");
        try { return OpenHandle(h); } finally { CloseHandle(h); }
    }

    // bits: BGRA rows of exactly the texture's size. Returns once the GPU has the picture, so it can be shown.
    public void Upload(IntPtr tex, IntPtr bits, int stride) {
        update(ctx, tex, 0, IntPtr.Zero, bits, (uint)stride, 0);
        end(ctx, query);
        Stopwatch sw = Stopwatch.StartNew(); int done, hr;
        while ((hr = getData(ctx, query, out done, 4, 0)) != 0) {
            if (hr < 0) throw new COMException("the GPU was lost during an upload, HRESULT 0x" + hr.ToString("X8"), hr);
            long ms = sw.ElapsedMilliseconds;
            if (ms > 2000) throw new TimeoutException("the GPU did not finish an upload");
            if (ms < 5) Thread.Yield(); else Thread.Sleep(1);   // it takes a millisecond or two: do not sleep a whole 15 ms timer tick for that
        }
    }

    // texture shared by NT handle (as a DisplaySurface is) -> upload two known pixels -> read them back
    public bool SelfTest(out string seen) {
        TexDesc d = new TexDesc(); d.W = 64; d.H = 32; d.Mips = 1; d.ArraySize = 1; d.Format = 87; d.SampCount = 1; d.Bind = 0x20; d.Misc = 0x2 | 0x800;
        IntPtr tex, res1, h;
        Check(createTex(dev, ref d, IntPtr.Zero, out tex), "CreateTexture2D");
        Guid iidRes1 = new Guid("30961379-4609-4a41-998e-54fe567ee0c1");
        Check(Slot<FnQI>(tex, 0)(tex, ref iidRes1, out res1), "IDXGIResource1");
        Check(Slot<FnShare>(res1, 13)(res1, IntPtr.Zero, 0x80000001, IntPtr.Zero, out h), "IDXGIResource1.CreateSharedHandle");
        IntPtr opened = OpenHandle(h); CloseHandle(h);
        using (Frame f = new Frame(64, 32)) {
            using (Graphics g = Graphics.FromImage(f.Gdi)) g.Clear(Color.FromArgb(10, 20, 30));
            f.Gdi.SetPixel(5, 7, Color.FromArgb(200, 100, 50));
            Upload(opened, f.Bits, f.Stride);
        }
        int p0 = ReadPixel(opened, 0, 0) & 0xFFFFFF, p1 = ReadPixel(opened, 5, 7) & 0xFFFFFF;
        Release(opened); Release(res1); Release(tex);
        seen = "pixels 0x" + p0.ToString("X6") + " / 0x" + p1.ToString("X6");
        return p0 == 0x0A141E && p1 == 0xC86432;
    }

    // What kind of texture this is (ID3D11Texture2D::GetDesc, slot 10).
    public string Describe(IntPtr tex) {
        TexDesc d; Slot<FnTexDesc>(tex, 10)(tex, out d);
        return d.W + "x" + d.H + " format " + d.Format + " usage " + d.Usage + " bind 0x" + d.Bind.ToString("X") + " misc 0x" + d.Misc.ToString("X");
    }

    // One pixel of a texture, read back through a staging copy: the proof that an upload arrived.
    public int ReadPixel(IntPtr tex, int x, int y) {
        TexDesc d; Slot<FnTexDesc>(tex, 10)(tex, out d);
        d.Mips = 1; d.ArraySize = 1; d.SampCount = 1; d.SampQuality = 0; d.Usage = 3; d.Bind = 0; d.Cpu = 0x20000; d.Misc = 0;   // STAGING, CPU read
        IntPtr st; Check(createTex(dev, ref d, IntPtr.Zero, out st), "CreateTexture2D(staging)");
        try {
            copy(ctx, st, tex);
            Mapped m; Check(map(ctx, st, 0, 1, 0, out m), "Map");
            int p = Marshal.ReadInt32(m.Data, (int)(y * m.RowPitch) + x * 4);
            unmap(ctx, st, 0);
            return p;
        } finally { Release(st); }
    }

    public void Dispose() { Release(query); Release(ctx); Release(dev1); Release(dev); query = ctx = dev1 = dev = IntPtr.Zero; }
}

// Owning the freed screen and putting pictures on it (Windows.Devices.Display.Core).
public static class Show {
    public struct Mode { public int W, H; public double Hz; }
    // Largest picture first, then the rate closest to 60 Hz; a rate Windows does not state (0) comes last. -1 if there is none.
    public static int Choose(IList<Mode> modes) {
        int best = -1;
        for (int i = 0; i < modes.Count; i++) {
            if (best < 0) { best = i; continue; }
            Mode a = modes[i], b = modes[best]; long pa = (long)a.W * a.H, pb = (long)b.W * b.H;
            double da = a.Hz > 0 ? Math.Abs(a.Hz - 60) : double.MaxValue, db = b.Hz > 0 ? Math.Abs(b.Hz - 60) : double.MaxValue;
            if (pa > pb || (pa == pb && da < db)) best = i;
        }
        return best;
    }

    static DisplayModeInfo ChooseMode(DisplayPath path, Pix.Snap noted) {
        IReadOnlyList<DisplayModeInfo> modes = path.FindModes(DisplayModeQueryOptions.OnlyPreferredResolution);
        bool sized = noted != null && noted.W > 0;
        if (modes.Count == 0 || sized) {
            IReadOnlyList<DisplayModeInfo> all = path.FindModes(DisplayModeQueryOptions.None);
            if (modes.Count == 0) modes = all;
            if (sized) {   // the size this screen had on the desktop, if the monitor offers it: the redraw is then pixel for pixel
                List<DisplayModeInfo> same = new List<DisplayModeInfo>();
                foreach (DisplayModeInfo m in all) if (m.SourceResolution.Width == noted.W && m.SourceResolution.Height == noted.H) same.Add(m);
                if (same.Count > 0) modes = same;
            }
        }
        List<Mode> list = new List<Mode>();
        foreach (DisplayModeInfo m in modes) {
            Mode x = new Mode(); x.W = m.SourceResolution.Width; x.H = m.SourceResolution.Height;
            uint den = m.PresentationRate.VerticalSyncRate.Denominator;
            x.Hz = den == 0 ? 0 : (double)m.PresentationRate.VerticalSyncRate.Numerator / den;
            list.Add(x);
        }
        int i = Choose(list);
        return i < 0 ? null : modes[i];
    }

    // "Access denied" and "stale" are what Windows answers for a moment after a screen left the desktop (measured, the
    // second one is literally its "retry" status): worth asking again at once. Anything else is a real refusal.
    static Exception Refused(string what, DisplayManagerResultWithState r) {
        string text = what + ": " + r.ErrorCode + (r.ExtendedErrorCode == null ? "" : " (0x" + r.ExtendedErrorCode.HResult.ToString("X8") + ")");
        if (r.ErrorCode == DisplayManagerResult.TargetAccessDenied || r.ErrorCode == DisplayManagerResult.TargetStale) return new NotReady(text);
        return new InvalidOperationException(text);
    }

    static bool toldScaling;   // said once per start of the program

    // Let go of a display object now, not whenever .NET gets round to it.
    static void Let(object o) {
        if (o == null) return;
        IDisposable d = o as IDisposable;
        if (d != null) d.Dispose(); else if (Marshal.IsComObject(o)) Marshal.FinalReleaseComObject(o);
    }

    // Own the screen named by the helper's note (held) and keep putting pictures on it while go() says so: the noted
    // windows, redrawn live, or the text of notice if there is one. shown counts the pictures; firstLine is logged with
    // the first of them. framesTo (test): the pictures go to PNG files in that folder and the screen is only owned.
    // Throws NotReady when Windows is still busy with the screen, anything else when it really cannot be done.
    public static void Pictures(string held, Pix.Snap noted, string notice, string framesTo, Func<bool> go, Func<string> firstLine, ref int shown) {
        try { Run(held, noted, notice, framesTo, go, firstLine, ref shown); }
        // every display object is let go of the moment the pictures stop: the helper is waiting to put the screen back
        finally { GC.Collect(); GC.WaitForPendingFinalizers(); }
    }

    static void Run(string held, Pix.Snap noted, string notice, string framesTo, Func<bool> go, Func<string> firstLine, ref int shown) {
        string[] h = held.Split('|'); uint lo = uint.Parse(h[0]); int hi = int.Parse(h[1]); uint id = uint.Parse(h[2]);
        DisplayManager dm = DisplayManager.Create(DisplayManagerOptions.None);
        Gfx gfx = null; Frame frame = null; IntPtr[] tex = new IntPtr[2];
        DisplayDevice dev = null; DisplaySource src = null; DisplayTaskPool pool = null;
        DisplaySurface[] surf = new DisplaySurface[2]; DisplayScanout[] scan = new DisplayScanout[2];
        try {
            // exactly the screen the helper took; a screen that is on the desktop is never a candidate
            DisplayTarget t = null;
            foreach (DisplayTarget x in dm.GetCurrentTargets()) {
                if (!x.IsConnected || x.UsageKind == DisplayMonitorUsageKind.Standard || x.AdapterRelativeId != id) continue;
                DisplayAdapterId a = x.Adapter.Id;
                if (a.LowPart == lo && a.HighPart == hi) { t = x; break; }
            }
            if (t == null) throw new NotReady("Windows does not list the freed screen yet");
            DisplayTarget[] mine = { t };
            DisplayManagerResultWithState r = dm.TryAcquireTargetsAndCreateEmptyState(mine);
            if (r.ErrorCode != DisplayManagerResult.Success) throw Refused("Windows does not hand the screen over", r);
            DisplayPath path = r.State.ConnectTarget(t);
            path.IsInterlaced = false; path.Scaling = DisplayPathScaling.Identity; path.SourcePixelFormat = DirectXPixelFormat.B8G8R8A8UIntNormalized;
            DisplayModeInfo mode = ChooseMode(path, noted);
            if (mode == null) throw new InvalidOperationException("the screen offers no usable mode (BGRA8, unscaled)");
            path.ApplyPropertiesFromMode(mode);
            DisplayStateOperationResult applied = r.State.TryApply(DisplayStateApplyOptions.None);
            if (applied.Status == DisplayStateOperationStatus.SystemStateChanged) throw new NotReady("the display set-up changed while the screen's mode was being set");
            if (applied.Status != DisplayStateOperationStatus.Success) throw new InvalidOperationException("the screen's mode could not be set: " + applied.Status + (applied.ExtendedErrorCode == null ? "" : " (0x" + applied.ExtendedErrorCode.HResult.ToString("X8") + ")"));
            r = dm.TryAcquireTargetsAndReadCurrentState(mine);   // re-read: the state that was really applied
            if (r.ErrorCode != DisplayManagerResult.Success) throw Refused("the mode that was set could not be read back", r);
            SizeInt32 res = r.State.GetPathForTarget(t).SourceResolution.Value; int w = res.Width, hgt = res.Height;

            if (framesTo != null) Directory.CreateDirectory(framesTo);
            else {
                dev = dm.CreateDisplayDevice(t.Adapter);
                try { src = dev.CreateScanoutSource(t); }
                catch (Exception e) { throw new InvalidOperationException("this display driver cannot give its screen to a program (" + e.Message.Trim() + "). It takes a current WDDM 2.x driver; a virtual machine's display adapter fails exactly here."); }
                pool = dev.CreateTaskPool();
                Direct3DMultisampleDescription ms = new Direct3DMultisampleDescription(); ms.Count = 1;
                DisplayPrimaryDescription desc = new DisplayPrimaryDescription((uint)w, (uint)hgt, DirectXPixelFormat.B8G8R8A8UIntNormalized, DirectXColorSpace.RgbFullG22NoneP709, false, ms);
                gfx = new Gfx(lo, hi);
                for (int k = 0; k < 2; k++) {
                    surf[k] = dev.CreatePrimary(t, desc);
                    scan[k] = dev.CreateSimpleScanout(src, surf[k], 0, 1);
                    tex[k] = gfx.OpenSurface(dev, surf[k]);
                }
            }
            if (!Pwr.Keep(true)) Agent.Log("Windows refused the request to keep the displays on: the picture may go dark with them");
            frame = new Frame(w, hgt);
            int i = 0, still = 0; bool first = true, said = false;
            while (go()) {
                if (noted != null) Pix.GiveBackSizes(noted);
                int drawn = noted != null && noted.Wins.Count > 0 ? Pix.CaptureWindows(noted, frame) : 0;
                if (drawn == 0) {   // say why the screen is empty, on the screen itself and once in the log
                    string why = notice != null ? notice
                        : noted.Wins.Count == 0 ? "Nothing was open on this screen when the PC was locked"
                        : "The windows of this screen cannot be shown:\nWindows minimized them when the screen left the desktop, or they were closed.\nIf they were minimized: sign out and back in once. The setup changed a Windows\nsetting for that, and it takes effect only at sign-in.";
                    Pix.Notice(frame, why);
                    if (!said && notice == null && noted.Wins.Count > 0) { said = true; Agent.Log("no window picture: " + why.Replace('\n', ' ')); }
                }
                if (frame.Changed()) {   // an unchanged picture is neither uploaded nor shown again
                    still = 0;
                    if (framesTo != null) { if (shown % 8 == 0) frame.Gdi.Save(Path.Combine(framesTo, "frame-" + shown.ToString("0000") + ".png"), ImageFormat.Png); }
                    else {
                        gfx.Upload(tex[i], frame.Bits, frame.Stride);
                        DisplayTask task = pool.CreateTask(); task.SetScanout(scan[i]);
#pragma warning disable 618   // Windows 11 marks ExecuteTask as superseded; it is the call Windows 10 has too, and the one proven on real hardware
                        pool.ExecuteTask(task);
#pragma warning restore 618
                        dev.WaitForVBlank(src);
                        i = 1 - i;
                    }
                    shown++;
                    if (first) {
                        first = false; Agent.Log(firstLine() + " (" + w + "x" + hgt + (gfx == null ? ", to files" : " on " + gfx.AdapterName) + ")");
                        // Measured, and nothing this program can change: while the screen is off the desktop its windows live on
                        // another screen, and each app draws its window for the scaling of the screen it is on.
                        if (noted != null && noted.OtherScale != 0 && !toldScaling) {
                            toldScaling = true;
                            Agent.Log("the picture is larger or smaller than it was on the screen: this screen is scaled " + noted.Scale + "%, another one " + noted.OtherScale
                                + "%, and while this one is off the desktop its windows are drawn for the other. The same scaling on all screens (Settings > System > Display > Scale) gives an identical picture");
                        }
                    }
                } else still++;
                // windows have to be asked for their picture: 4 times a second while it changes, once a second after 2 s without change
                if (!Pix.SleepWhile(go, still >= 8 ? 1000 : 250)) break;
            }
        } finally {
            Pwr.Keep(false);
            foreach (IntPtr x in tex) Gfx.Free(x);
            if (gfx != null) gfx.Dispose();
            if (frame != null) frame.Dispose();
            Let(scan[0]); Let(scan[1]); Let(surf[0]); Let(surf[1]); Let(pool); Let(src); Let(dev);
            dm.Dispose();   // gives the screen up
        }
    }
}

public static class Agent {
    static readonly string Version = typeof(Agent).Assembly.GetName().Version.ToString(3);
    static string logFile;

    // A few lines per lock at most; the file keeps its newer half when it passes 256 KB.
    public static void Log(string m) {
        if (logFile == null) { Console.WriteLine(m); return; }
        try {
            FileInfo f = new FileInfo(logFile);
            if (f.Exists && f.Length > 262144) { string[] all = File.ReadAllLines(logFile); File.WriteAllLines(logFile, new List<string>(all).GetRange(all.Length / 2, all.Length - all.Length / 2)); }
            File.AppendAllText(logFile, DateTime.Now.ToString("s") + " " + m + Environment.NewLine);
        } catch (Exception) { }   // a log that cannot be written must not stop the pictures
    }

    static int Main(string[] args) {
        Pix.DpiAware();
        if (Array.IndexOf(args, "-selftest") >= 0) return SelfTest();
        int f = Array.IndexOf(args, "-frames"); string framesTo = f >= 0 && f + 1 < args.Length ? args[f + 1] : null;
        string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LockMonitor");
        Directory.CreateDirectory(dir); logFile = Path.Combine(dir, "log.txt");
        bool first;
        using (Mutex one = new Mutex(true, @"Local\LockMonitor.Agent", out first)) {   // one agent per signed-in user
            if (!first) return 3;
            Log("LockMonitor " + Version + " started" + (framesTo == null ? "" : " in test mode: pictures go to " + framesTo));
            for (;;) {
                try { Loop(framesTo); }
                catch (Exception e) { Log("starting over after an error: " + e.GetType().Name + ": " + e.Message); Thread.Sleep(10000); }
            }
        }
    }

    static void Loop(string framesTo) {
        bool checkedOnce = false;
        for (;;) {
            Pix.Snap noted = Pix.WaitForLock(!checkedOnce);
            if (noted.Check) { checkedOnce = true; Check(framesTo); continue; }
            Stopwatch locked = Stopwatch.StartNew(), since = null;
            int fails = 0, shown = 0; bool freed = false; HashSet<string> early = new HashSet<string>();
            while (Pix.Locked()) {
                string held = Pix.Taken();
                if (held == null) { Thread.Sleep(250); continue; }   // nothing to do until the helper has freed the screen
                freed = true; if (since == null) since = Stopwatch.StartNew();
                Stopwatch ran = Stopwatch.StartNew();
                try {
                    Show.Pictures(held, noted, null, framesTo, Pix.Locked,
                        () => "showing " + noted.Wins.Count + " window(s) of " + noted.Device + ", " + locked.Elapsed.TotalSeconds.ToString("0.0") + " s after the lock", ref shown);
                } catch (Exception e) {
                    if (ran.Elapsed.TotalSeconds > 60) { fails = 0; early.Clear(); since.Restart(); }   // it had been working: a new problem, not the old one again
                    // ask again at once for the first 20 s, each kind of answer logged once; after that, and for real refusals,
                    // after 2 s, 4 s, ... at most a minute: no busy loop, no flood in the log
                    if (e is NotReady && since.Elapsed.TotalSeconds < 20) { if (early.Add(e.Message)) Log("not ready yet: " + e.Message); Thread.Sleep(200); continue; }
                    fails++; Log(e is NotReady || e is InvalidOperationException ? e.Message : e.GetType().Name + ": " + e.Message);
                    Pix.SleepWhile(Pix.Locked, 1000 * Math.Min(60, 2 * fails));
                }
            }
            if (noted.Device != null || freed)   // on a single-screen desktop there is nothing to say
                Log("lock over after " + locked.Elapsed.TotalSeconds.ToString("0") + " s, " + (shown > 0 ? shown + " picture(s)"
                    : freed ? "no picture: Windows never handed the screen over" : "no picture: the helper did not free the screen (its reasons are in switch.log next to it)"));
            Pix.LockEnded();
        }
    }

    // The setup's test, once per start of this program: while the PC is unlocked, the setup has the helper take the
    // screen and leaves the note "Check" (only administrators can). Show a text on the screen for a few seconds, the
    // same way as at a lock, and say in the log how it went. No window is shown. The setup then puts the screen back.
    static void Check(string framesTo) {
        Stopwatch t = Stopwatch.StartNew(); int shown = 0; string why = "the screen was not freed";
        while (shown == 0 && t.Elapsed.TotalSeconds < 12) {
            string held = Pix.Taken(); if (held == null) break;
            Stopwatch on = Stopwatch.StartNew();
            try {
                Show.Pictures(held, null, "LockMonitor test picture\nWhen the PC is locked, this screen keeps showing its windows.", framesTo,
                    () => on.Elapsed.TotalSeconds < 4 && Pix.Taken() != null, () => "check: the test picture is on the screen", ref shown);
            } catch (Exception e) { why = e.Message; Thread.Sleep(e is NotReady ? 200 : 1000); }
        }
        if (shown == 0) Log("check: no picture: " + why);
    }

    // ---- -selftest: checks of this PC that change nothing ----
    static int failed;
    static void Line(string what, bool ok, string detail) {
        if (!ok) failed++;
        Console.WriteLine(what.PadRight(52) + ": " + (ok ? "OK" : "FAILED") + (string.IsNullOrEmpty(detail) ? "" : "  (" + detail + ")"));
    }
    static bool Near(Color c, int r, int g, int b) { return Math.Abs(c.R - r) <= 3 && Math.Abs(c.G - g) <= 3 && Math.Abs(c.B - b) <= 3; }
    static string Rgb(Color c) { return c.R + "," + c.G + "," + c.B; }
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);

    static int SelfTest() {
        Console.WriteLine("LockMonitor " + Version + " self-test. Nothing is changed.");
        using (DisplayManager dm = DisplayManager.Create(DisplayManagerOptions.None)) {
            DisplayTarget any = null;
            foreach (DisplayTarget t in dm.GetCurrentTargets()) {
                if (!t.IsConnected) continue;
                if (any == null) any = t;
                DisplayAdapterId a = t.Adapter.Id;
                Console.WriteLine("screen " + (t.UsageKind + ", target " + t.AdapterRelativeId).PadRight(45) + ": " + Spec.Get(a.LowPart, a.HighPart, t.AdapterRelativeId));
            }
            if (any == null) { Console.WriteLine("no screen is connected"); return 1; }
            DisplayAdapterId id = any.Adapter.Id;
            using (Gfx g = new Gfx(id.LowPart, id.HighPart)) {
                Console.WriteLine("graphics adapter".PadRight(52) + ": " + g.AdapterName);
                string seen; bool ok = g.SelfTest(out seen);
                Line("picture to a shared GPU texture and back", ok, seen);
                // a real display surface, allocated but never shown, must open as a texture, take a picture and give it back
                try {
                    Direct3DMultisampleDescription ms = new Direct3DMultisampleDescription(); ms.Count = 1;
                    DisplayPrimaryDescription desc = new DisplayPrimaryDescription(256, 128, DirectXPixelFormat.B8G8R8A8UIntNormalized, DirectXColorSpace.RgbFullG22NoneP709, false, ms);
                    DisplayDevice dev = dm.CreateDisplayDevice(any.Adapter);
                    IntPtr tex = g.OpenSurface(dev, dev.CreatePrimary(any, desc));
                    using (Frame f = new Frame(256, 128)) {
                        using (Graphics gr = Graphics.FromImage(f.Gdi)) gr.Clear(Color.FromArgb(200, 100, 50));
                        g.Upload(tex, f.Bits, f.Stride);
                    }
                    int px = g.ReadPixel(tex, 100, 60) & 0xFFFFFF;
                    Line("picture to a display surface and back", px == 0xC86432, "pixel 0x" + px.ToString("X6") + ", surface " + g.Describe(tex));
                    Gfx.Free(tex);
                } catch (Exception e) { Line("picture to a display surface and back", false, e.Message.Trim() + ". This display driver cannot give a screen to a program"); }
            }
        }
        Console.WriteLine("not testable here".PadRight(52) + ": owning a screen and showing on it; the setup tests that live");

        Show.Mode[] m = new Show.Mode[4];
        m[0].W = 1920; m[0].H = 1080; m[0].Hz = 60; m[1].W = 1920; m[1].H = 1200; m[1].Hz = 75; m[2].W = 1920; m[2].H = 1200; m[2].Hz = 0; m[3].W = 1920; m[3].H = 1200; m[3].Hz = 59.94;
        Line("choice of the screen mode", Show.Choose(m) == 3 && Show.Choose(new Show.Mode[0]) == -1, "");
        bool kept = Pwr.Keep(true); Pwr.Keep(false);
        Line("request to keep PC and displays on", kept, "");

        // the picture path, against a small window of our own in a known colour
        using (System.Windows.Forms.Form form = new System.Windows.Forms.Form())
        using (Frame shot = new Frame(640, 400)) {
            form.Text = "LockMonitor self-test"; form.StartPosition = System.Windows.Forms.FormStartPosition.Manual;
            form.SetBounds(60, 60, 320, 200); form.BackColor = Color.FromArgb(200, 100, 50); form.ShowInTaskbar = false;
            ShowWindow(form.Handle, 4);   // shown without taking the focus
            System.Windows.Forms.Application.DoEvents(); Thread.Sleep(400); System.Windows.Forms.Application.DoEvents();
            Rectangle v = Pix.Visible(form.Handle);
            Pix.Snap note = new Pix.Snap(); note.W = 640; note.H = 400;
            Pix.Win win = new Pix.Win(); win.H = form.Handle; win.X = 100; win.Y = 50; win.W = v.Width; win.Hgt = v.Height; note.Wins.Add(win);
            int drawn = Pix.CaptureWindows(note, shot);
            Color inside = shot.Gdi.GetPixel(100 + v.Width / 2, 50 + v.Height - 12), left = shot.Gdi.GetPixel(96, 50 + v.Height - 12), below = shot.Gdi.GetPixel(100 + v.Width / 2, 50 + v.Height + 4);
            Line("window redrawn in its place, pixel for pixel", drawn == 1 && Near(inside, 200, 100, 50) && Near(left, 0, 0, 0) && Near(below, 0, 0, 0), "inside " + Rgb(inside) + ", left " + Rgb(left) + ", below " + Rgb(below));
            Line("an unchanged picture is recognised", shot.Changed() && Pix.CaptureWindows(note, shot) == 1 && !shot.Changed(), "");
            win.W = 200; win.Hgt = 300;   // another size than noted (Windows resized it on another screen): fitted into its place
            drawn = Pix.CaptureWindows(note, shot);
            Color fit = shot.Gdi.GetPixel(200, 215), outside = shot.Gdi.GetPixel(200, 60);
            Line("window of another size fitted into its place", drawn == 1 && Near(fit, 200, 100, 50) && Near(outside, 0, 0, 0) && shot.Changed(), "inside " + Rgb(fit) + ", outside " + Rgb(outside));
            form.Close();
            Line("a closed window is left out", Pix.CaptureWindows(note, shot) == 0, "");
        }
        Pix.Snap s = Pix.Snapshot();
        Console.WriteLine("screen that would be kept".PadRight(52) + ": " + (s == null ? "none: the desktop has a single screen" : s.Device + " " + s.W + "x" + s.H + ", " + s.Wins.Count + " window(s) on it now"));
        Console.WriteLine("held by the helper now / PC locked".PadRight(52) + ": " + (Pix.Taken() ?? "nothing") + " / " + Pix.Locked());
        Console.WriteLine(failed == 0 ? "All checks passed." : failed + " check(s) FAILED.");
        return failed == 0 ? 0 : 1;
    }
}
