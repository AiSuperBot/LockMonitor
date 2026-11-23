// LockMonitor agent. Install-Auto.ps1 puts it into "%ProgramFiles%\LockMonitor\LockMonitor-Agent.exe" and has Windows
// start it at sign-in with the user's normal rights. It waits and holds nothing. While the PC is unlocked it only notes
// which windows are on the highest-numbered screen. At Win+L the elevated helper (Switch-LastScreen.exe, started by
// Windows' own lock event) takes that screen off the Windows desktop; this program then owns the screen and redraws the
// noted windows on it, live, until the PC is unlocked. Then the helper puts the screen back.
//
// The lock itself is not touched: no Windows file is patched, Win+L is not intercepted, nothing imitates the lock
// screen. The kept screen shows pictures only: it has no pointer, no focus and takes no input. Windows are read, never
// typed or clicked into; the only things done to them are to give them back the size they had during a lock (see
// Pix.Arrange), to keep them out of sight while the user signs in until their screen is back (see Pix.Arrange and
// Pix.Away), and to put them back then (see Pix.PutBack).
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
using Microsoft.Win32.SafeHandles;
using Windows.Devices.Display;
using Windows.Devices.Display.Core;
using Windows.Graphics;
using Windows.Graphics.DirectX;
using Windows.Graphics.DirectX.Direct3D11;
using Forms = System.Windows.Forms;

[assembly: AssemblyTitle("LockMonitor agent: keeps one screen's windows showing while Windows is locked")]

// Windows is still busy with the screen (it only just left the desktop): worth asking again at once.
public class NotReady : Exception { public NotReady(string message) : base(message) { } }

// windows.devices.display.core.interop.h: derives from IUnknown (not IInspectable), so CreateSharedHandle is slot 3.
[ComImport, Guid("64338358-366A-471B-BD56-DD8EF48E439B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IDisplayDeviceInterop {
    [PreserveSig] int CreateSharedHandle([MarshalAs(UnmanagedType.IUnknown)] object o, IntPtr sa, uint access, IntPtr name, out IntPtr handle);
    [PreserveSig] int OpenSharedHandle(IntPtr h, ref Guid riid, [MarshalAs(UnmanagedType.IUnknown)] out object o);
}

// The lock flag as the agent needs it: many times a second while it shows pictures, so that it lets go of the screen the
// moment the PC is unlocked. Windows' own answer (Common.SessionFlag) is a call into the session manager, the dearest
// call this program makes (measured: 130 us), so it is asked at most every 2 s; in between, Windows' own announcement of
// each lock and unlock (WM_WTSSESSION_CHANGE, to a message-only window on a thread of its own) keeps the flag current at
// once. Message-only: such a window gets no broadcasts (measured: .NET's SystemEvents, whose window gets them all, made
// the waiting agent 55% dearer). Without announcements (no window) Windows is asked every time.
// Windows also says when the PC goes to sleep and when it wakes up: to a callback, not to a message-only window
// (measured: the window got nothing). Each lock, unlock, sleep and wake-up ends a Wait at once.
public static class Session {
    delegate IntPtr WndProc(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct WNDCLASS { public uint style; public WndProc proc; public int clsExtra, wndExtra; public IntPtr inst, icon, cursor, brush; public string menu, name; }
    [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr h; public uint msg; public IntPtr w, l; public uint time; public int x, y; }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern ushort RegisterClass(ref WNDCLASS c);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateWindowEx(int ex, string cls, string name, int style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr p);
    [DllImport("user32.dll")] static extern IntPtr DefWindowProc(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern int GetMessage(out MSG m, IntPtr h, uint min, uint max);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref MSG m);
    [DllImport("wtsapi32.dll")] static extern bool WTSRegisterSessionNotification(IntPtr h, int flags);
    [DllImport("user32.dll")] static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr h);
    delegate uint PowerProc(IntPtr context, uint type, IntPtr setting);
    [StructLayout(LayoutKind.Sequential)] struct SUBSCRIBE { public PowerProc proc; public IntPtr context; }   // DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS
    [DllImport("powrprof.dll")] static extern uint PowerRegisterSuspendResumeNotification(uint flags, IntPtr recipient, out IntPtr handle);

    static volatile int flag = -1;   // as Common.SessionFlag: 0 locked, 1 unlocked, -1 not known
    static volatile int news;        // counts announcements: an answer asked for before the latest one is older than it
    static volatile bool told;       // announcements arrive
    static long asked;               // Stopwatch time of the last answer
    static long lockedAt;            // Stopwatch time of the latest lock announcement or wake-up (see SigningIn)
    static int naps;                 // counts the moments the PC went to sleep or woke up
    static volatile bool asleep;     // between "goes to sleep" and "woke up"
    static readonly WndProc proc = Announced;   // kept alive: Windows calls these as long as the program runs
    static readonly PowerProc power = Power;
    static readonly AutoResetEvent changed = new AutoResetEvent(false);
    // set while this program owns no screen; the PC waits for it before it sleeps
    public static readonly ManualResetEvent Free = new ManualResetEvent(true);
    // run the moment the PC is unlocked, before anything else (see Pix.Home)
    public static volatile Action Unlocking;

    static Session() {
        Thread t = new Thread(() => {
            WNDCLASS c = new WNDCLASS(); c.proc = proc; c.name = "LockMonitor.Session";
            if (RegisterClass(ref c) == 0) return;
            IntPtr h = CreateWindowEx(0, c.name, null, 0, 0, 0, 0, 0, new IntPtr(-3), IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);   // -3 = HWND_MESSAGE
            if (h == IntPtr.Zero || !WTSRegisterSessionNotification(h, 0)) return;   // 0 = this session only
            told = true;
            MSG m; while (GetMessage(out m, IntPtr.Zero, 0, 0) > 0) DispatchMessage(ref m);
        });
        t.IsBackground = true; t.Start();
        SUBSCRIBE s = new SUBSCRIBE(); s.proc = power;
        IntPtr p = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(SUBSCRIBE)));   // never freed: Windows may read it as long as the program runs
        Marshal.StructureToPtr(s, p, false);
        IntPtr reg; PowerRegisterSuspendResumeNotification(2, p, out reg);   // 2 = DEVICE_NOTIFY_CALLBACK
    }
    static IntPtr Announced(IntPtr h, uint msg, IntPtr w, IntPtr l) {
        if (msg == 0x2B1) {   // WM_WTSSESSION_CHANGE: 7 = locked, 8 = unlocked; anything else (sign-out, remote connect...): ask Windows
            int what = w.ToInt32();
            Action a = Unlocking;
            // a picture taken meanwhile treats the windows as during the sign-in: it would call them back otherwise
            if (what == 8) Interlocked.Exchange(ref signing, Stopwatch.GetTimestamp());
            if (what == 8 && a != null) try { a(); } catch (Exception) { }   // must not end this thread
            if (what == 7) { Interlocked.Exchange(ref lockedAt, Stopwatch.GetTimestamp()); curtain = false; }
            if (what == 8) asleep = false;   // awake, whatever the power notices said (not at a lock: one comes with a sleep)
            flag = what == 7 ? 0 : what == 8 ? 1 : -1; news++; Interlocked.Exchange(ref asked, Stopwatch.GetTimestamp());
            changed.Set();
        }
        return DefWindowProc(h, msg, w, l);
    }
    // Display objects from before a sleep cannot be trusted after it (the graphics adapter was switched off), so the
    // screen is given up before the PC sleeps, and owned afresh once it woke up.
    static uint Power(IntPtr context, uint type, IntPtr setting) {
        if (type == 4 || type == 0x12) {   // PBT_APMSUSPEND: about to sleep; PBT_APMRESUMEAUTOMATIC: woke up
            asleep = type == 4; Interlocked.Increment(ref naps);
            if (!asleep) Interlocked.Exchange(ref lockedAt, Stopwatch.GetTimestamp());   // a wake-up may pass through the sign-in desktop as a lock does (found in review)
            changed.Set();
            if (asleep) Free.WaitOne(1500);   // Windows allows about 2 s for this answer
        }
        return 0;
    }
    static int Flag() {
        long now = Stopwatch.GetTimestamp();
        if (!told || flag == -1 || now - Interlocked.Read(ref asked) > 2 * Stopwatch.Frequency) {
            int before = news, f = Common.SessionFlag();
            if (before == news) { flag = f; Interlocked.Exchange(ref asked, now); }
        }
        return flag;
    }
    public static bool Locked() { return Flag() == 0; }
    public static bool Unlocked() { return Flag() == 1; }
    // A screen saver is up that locks the PC when it ends ("On resume, display logon screen": the user's setting, or the
    // organization's policy, which wins), longer than its grace period, within which Windows lets the user back without
    // the password (ScreenSaverGracePeriod: 5 s unless set otherwise; 1 s more here). Windows locks the PC only at its
    // end (measured, Windows 10: no lock while it ran; the key that ended it locked the PC). Asked every 0.7 s.
    [DllImport("user32.dll")] static extern bool SystemParametersInfo(uint action, uint param, out int value, uint flags);
    static readonly long grace = ((long)GraceSeconds() + 1) * Stopwatch.Frequency;
    static long saverFrom;   // Stopwatch time it was first seen up; 0: not up
    // shortcut: whether Settings' screen saver preview counts as running is not checked (a preview longer than the grace
    // period would lock the PC); if it does, also require the input desktop to be the screen saver's own ("Screen-saver").
    public static bool Saver() {
        int on, secure;
        bool up = SystemParametersInfo(0x72, 0, out on, 0) && on != 0;   // SPI_GETSCREENSAVERRUNNING
        if (up) {
            object p = Registry.GetValue(@"HKEY_CURRENT_USER\Software\Policies\Microsoft\Windows\Control Panel\Desktop", "ScreenSaverIsSecure", null);
            up = p != null ? p.ToString() == "1" : SystemParametersInfo(0x76, 0, out secure, 0) && secure != 0;   // SPI_GETSCREENSAVESECURE
        }
        long now = Stopwatch.GetTimestamp();
        if (!up) saverFrom = 0; else if (saverFrom == 0) saverFrom = now;
        return up && now - saverFrom >= grace;
    }
    static int GraceSeconds() {
        try {
            object g = Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon", "ScreenSaverGracePeriod", null);
            int s; return g != null && int.TryParse(g.ToString(), out s) && s >= 0 ? s : 5;
        } catch (Exception) { return 5; }
    }
    // The sign-in screen is up, so the PC is about to be unlocked. Windows shows it on a desktop of its own, which this
    // program may not open (measured: refused from the moment the password box appears until the unlock; the lock
    // screen's picture before that is on the user's own desktop). And for 2 s after: at the unlock the sign-in screen
    // goes a moment before Windows says the PC is unlocked (measured). Not in the first 3 s of a lock: the lock itself
    // passes through that desktop (measured: for 0.7 s).
    static long signing;   // Stopwatch time the sign-in screen was last seen, or the unlock announced
    static volatile bool curtain;   // the lock screen's own picture was up during this lock
    public static bool SigningIn() {
        long now = Stopwatch.GetTimestamp(), at = Interlocked.Read(ref lockedAt);
        if (now - at >= 3 * Stopwatch.Frequency) {
            IntPtr d = OpenInputDesktop(0, false, 0x0001);   // DESKTOP_READOBJECTS
            if (d == IntPtr.Zero) Interlocked.Exchange(ref signing, now); else { CloseDesktop(d); curtain = true; }
        }
        return NearUnlock && Interlocked.Read(ref signing) > at;   // not the unlock before this lock (locked again at once)
    }
    // The user is back: the sign-in screen came up over the lock screen's own picture. Not a sign-in screen that is up
    // all through the lock, as with the policy "Do not display the lock screen" (found in review): it is the lock screen.
    public static bool UserBack() { return SigningIn() && curtain; }
    // the same as last said, without asking Windows: true from the unlock announcement on, also amid a picture
    public static bool NearUnlock { get { return Stopwatch.GetTimestamp() - Interlocked.Read(ref signing) < 2 * Stopwatch.Frequency; } }
    public static int Naps { get { return Thread.VolatileRead(ref naps); } }
    // between "about to sleep" and "woke up" (or the next unlock, should the wake-up go unsaid)
    public static bool Asleep { get { return asleep; } }
    // Sleeps up to ms; returns early at a lock, unlock, sleep or wake-up.
    public static void Wait(int ms) { changed.WaitOne(ms); }
}

public static class Pwr {   // ES_CONTINUOUS 0x80000000 | ES_SYSTEM_REQUIRED 1 | ES_DISPLAY_REQUIRED 2; holds for the calling thread
    [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint f);
    // Windows has one display-power switch for all screens and blanks them a minute after locking: while a picture is
    // shown, the PC is kept awake and the displays on (measured: the request holds through the lock). false = refused.
    public static bool Keep(bool on) { return SetThreadExecutionState(on ? 0x80000003u : 0x80000000u) != 0; }
    // That request only keeps them on: when the PC locked by itself after its displays had gone dark, they stayed dark
    // (measured). Asked once, without ES_CONTINUOUS, it switches them on again (measured; a display power request and
    // SC_MONITORPOWER did not).
    public static void Wake() { SetThreadExecutionState(2); }
}

// One picture, kept as a plain Windows bitmap (DIB section): window pictures are copied into it by Windows' own bitmap
// routines and the GPU reads it from there, with no conversions in between. Gdi is a System.Drawing view of the same
// memory, for text; made when first asked for, as it loads GDI+, which the windows' pictures do not need.
public class Frame : IDisposable {
    [StructLayout(LayoutKind.Sequential)] struct BITMAPINFOHEADER { public int size, width, height; public short planes, bitCount; public int compression, sizeImage, xppm, yppm, clrUsed, clrImportant; }
    [DllImport("gdi32.dll")] static extern IntPtr CreateDIBSection(IntPtr hdc, ref BITMAPINFOHEADER bmi, uint usage, out IntPtr bits, IntPtr section, uint offset);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr obj);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern bool PatBlt(IntPtr dc, int x, int y, int w, int h, uint rop);
    [DllImport("gdi32.dll")] static extern bool GdiFlush();

    public readonly int W, H, Stride;
    public readonly IntPtr Bits, Dc;
    IntPtr dib, old; Bitmap gdi; ulong[] sums; bool gone;

    public Frame(int w, int h) {
        W = w; H = h; Stride = w * 4;
        BITMAPINFOHEADER bi = new BITMAPINFOHEADER(); bi.size = 40; bi.width = w; bi.height = -h; bi.planes = 1; bi.bitCount = 32;   // negative height: first row on top
        dib = CreateDIBSection(IntPtr.Zero, ref bi, 0, out Bits, IntPtr.Zero, 0);
        if (dib == IntPtr.Zero) throw new OutOfMemoryException("no memory for a " + w + "x" + h + " picture");
        Dc = CreateCompatibleDC(IntPtr.Zero); old = SelectObject(Dc, dib);
    }
    public Bitmap Gdi { get { return gdi ?? (gdi = new Bitmap(W, H, Stride, PixelFormat.Format32bppRgb, Bits)); } }
    public void Clear() { PatBlt(Dc, 0, 0, W, H, 0x42); }   // 0x42 = BLACKNESS

    // The rows that differ from the picture at the previous call, as [top, bottom); false when none do (the first call
    // reports all rows); only these rows need to go to the GPU. Each row is known by a fingerprint of its pixels, 8 bytes
    // instead of a copy of the row (a copy of the whole picture: 8 MB at 1920x1080, 32 MB at 3840x2160). Measured,
    // 1920x1080, Intel UHD 630 PC: 0.75 ms a picture whatever changed (comparing with a copy: 0.70 ms when nothing
    // changed, 0.77 for a band of rows, 0.44 when all rows did); the windows' pictures take 10 to 50 ms.
    public unsafe bool Changed(out int top, out int bottom) {
        GdiFlush();   // Windows may still be holding drawing back; the memory is read directly below
        bool all = sums == null;
        if (all) sums = new ulong[H];
        top = H; bottom = 0;
        byte* row = (byte*)Bits;
        for (int y = 0; y < H; y++, row += Stride) {
            ulong s = Sum(row, Stride);
            if (all || s != sums[y]) { sums[y] = s; if (top == H) top = y; bottom = y + 1; }
        }
        return top < bottom;
    }
    // A fingerprint of n bytes (n a multiple of 4): eight chains of x = turned(x ^ the next 8 bytes) * an odd number, side
    // by side so that the processor works on them at once (four were twice as slow, measured). Every step can be undone,
    // so a change of any single 8-byte piece always changes the fingerprint. The half turn carries changes of high bits
    // into the low ones, which a multiplication alone never does (without it, two changes of a top bit in one chain
    // cancelled out, found in review), so that several changes cancel out with a chance of about 1 in 2^64.
    static unsafe ulong Sum(byte* p, int n) {
        const ulong K = 0x9E3779B97F4A7C15;
        ulong* q = (ulong*)p; int words = n >> 3, i = 0;
        ulong a = 1, b = 2, c = 3, d = 4, e = 5, f = 6, g = 7, h = 8;
        for (; i + 8 <= words; i += 8) {
            a ^= q[i]; b ^= q[i + 1]; c ^= q[i + 2]; d ^= q[i + 3]; e ^= q[i + 4]; f ^= q[i + 5]; g ^= q[i + 6]; h ^= q[i + 7];
            a = (a << 32 | a >> 32) * K; b = (b << 32 | b >> 32) * K; c = (c << 32 | c >> 32) * K; d = (d << 32 | d >> 32) * K;
            e = (e << 32 | e >> 32) * K; f = (f << 32 | f >> 32) * K; g = (g << 32 | g >> 32) * K; h = (h << 32 | h >> 32) * K;
        }
        for (; i < words; i++) { a ^= q[i]; a = (a << 32 | a >> 32) * K; }
        if ((n & 4) != 0) { b ^= *(uint*)(p + n - 4); b = (b << 32 | b >> 32) * K; }
        a ^= e; b ^= f; c ^= g; d ^= h;   // a change in one chain still changes the result: the others stay as they were
        return a ^ (b << 16 | b >> 48) ^ (c << 32 | c >> 32) ^ (d << 48 | d >> 16);
    }

    public void Dispose() {
        if (gone) return; gone = true;
        if (gdi != null) gdi.Dispose();
        SelectObject(Dc, old); DeleteDC(Dc); DeleteObject(dib);
    }
}

public static class Pix {
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("psapi.dll")] static extern bool EmptyWorkingSet(IntPtr process);

    // ---- windows: finding them and getting their live picture ----
    [StructLayout(LayoutKind.Sequential)] internal struct RECT { public int l, t, r, b; public bool Is(RECT o) { return l == o.l && t == o.t && r == o.r && b == o.b; } }
    delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")] internal static extern int GetWindowLong(IntPtr h, int index);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindowAsync(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hgt, uint flags);
    [StructLayout(LayoutKind.Sequential)] internal struct PLACEMENT { public int length, flags, showCmd, minX, minY, maxX, maxY; public RECT normal; }   // WINDOWPLACEMENT
    [DllImport("user32.dll")] static extern bool GetWindowPlacement(IntPtr h, ref PLACEMENT p);
    [DllImport("user32.dll")] static extern bool SetWindowPlacement(IntPtr h, ref PLACEMENT p);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
    [DllImport("shcore.dll")] static extern int GetDpiForMonitor(IntPtr hmon, int type, out uint dpiX, out uint dpiY);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int size);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int v, int size);
    [DllImport("gdi32.dll")] static extern bool BitBlt(IntPtr dst, int x, int y, int w, int h, IntPtr src, int sx, int sy, uint rop);
    [DllImport("gdi32.dll")] static extern int SetStretchBltMode(IntPtr dc, int mode);
    [DllImport("gdi32.dll")] static extern bool SetBrushOrgEx(IntPtr dc, int x, int y, IntPtr prev);
    [DllImport("gdi32.dll")] static extern bool StretchBlt(IntPtr dst, int x, int y, int w, int h, IntPtr src, int sx, int sy, int sw, int sh, uint rop);
    [DllImport("gdi32.dll")] static extern bool GdiFlush();

    // sizes and pictures in real pixels on every screen, whatever its scaling (-4 = per-monitor aware v2; older Windows lacks it)
    public static void DpiAware() {
        try { if (!SetProcessDpiAwarenessContext(new IntPtr(-4))) SetThreadDpiAwarenessContext(new IntPtr(-4)); } catch (EntryPointNotFoundException) { }
    }

    // The part of a window that is really visible, in screen pixels. Windows adds an invisible resize border around
    // windows; the compositor knows the true outline (9 = DWMWA_EXTENDED_FRAME_BOUNDS). Asking it is by far the dearest
    // call here (measured: 62 us, the window's own rectangle 0.1 us), so whole and seen come in as the last answer for
    // this window and the compositor is asked again only when the window's rectangle is no longer the same.
    static bool Outline(IntPtr hwnd, ref RECT whole, ref RECT seen) {
        RECT now;
        if (!GetWindowRect(hwnd, out now) || now.r <= now.l || now.b <= now.t) return false;
        if (now.Is(whole) && seen.r > seen.l) return true;
        whole = now; RECT f;
        if (DwmGetWindowAttribute(hwnd, 9, out f, 16) == 0 && f.r > f.l && f.b > f.t) {
            seen.l = Math.Max(f.l, now.l); seen.t = Math.Max(f.t, now.t); seen.r = Math.Min(f.r, now.r); seen.b = Math.Min(f.b, now.b);
            if (seen.r > seen.l && seen.b > seen.t) return true;
        }
        seen = now; return true;
    }
    public static Rectangle Visible(IntPtr hwnd) { RECT w = new RECT(), s = new RECT(); return Outline(hwnd, ref w, ref s) ? Rectangle.FromLTRB(s.l, s.t, s.r, s.b) : Rectangle.Empty; }

    // What was on the screen: its windows, top-most first, in the screen's own pixels (noted while unlocked).
    // Left, Top: where the screen was on the desktop. Scale: the screen's display scaling in percent; OtherScale: that of
    // another desktop screen when it differs, else 0. Check: not a lock but the setup's test.
    public class Snap {
        public string Device; public int Left, Top, W, H, Scale, OtherScale; public List<Win> Wins = new List<Win>(); public bool Check;
        internal Win Find(IntPtr h) { foreach (Win w in Wins) if (w.H == h) return w; return null; }   // a handful of windows: a list is quicker than a table
    }
    // One window: noted place and size (and Windows' own record of it, for PutBack); and, set anew for every picture, how
    // it is right now and where it goes.
    public class Win {
        public IntPtr H; public int X, Y, W, Hgt, Asked; public string Title;
        internal PLACEMENT place;
        internal RECT whole, seen; internal int bx, by, bw, bh; internal bool live, minimized, done; internal long askedAt;
        // drawn pixel for pixel: its visible part is exactly the size of its place in the picture
        internal bool Exact { get { return seen.r - seen.l == bw && seen.b - seen.t == bh; } }
        // its visible part has the noted size (as of the last Outline)
        internal bool Sized { get { return seen.r - seen.l == W && seen.b - seen.t == Hgt; } }
        // drawn exactly over all of o's place, so o's picture would not show
        internal bool Covers(Win o) { return live && Exact && bx <= o.bx && by <= o.by && bx + bw >= o.bx + o.bw && by + bh >= o.by + o.bh; }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct MONITORINFOEX { public int cbSize; public RECT mon, work; public uint flags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string device; }
    delegate bool MonProc(IntPtr hm, IntPtr dc, IntPtr rc, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, MonProc cb, IntPtr data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr hm, ref MONITORINFOEX mi);

    static readonly int InfoSize = Marshal.SizeOf(typeof(MONITORINFOEX));
    static bool Info(IntPtr hm, out MONITORINFOEX mi) { mi = new MONITORINFOEX(); mi.cbSize = InfoSize; return GetMonitorInfo(hm, ref mi); }
    // The screens of the desktop: handle and description of each.
    static List<KeyValuePair<IntPtr, MONITORINFOEX>> Monitors() {
        List<KeyValuePair<IntPtr, MONITORINFOEX>> all = new List<KeyValuePair<IntPtr, MONITORINFOEX>>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (hm, dc, rc, d) => {
            MONITORINFOEX mi; if (Info(hm, out mi)) all.Add(new KeyValuePair<IntPtr, MONITORINFOEX>(hm, mi));
            return true;
        }, IntPtr.Zero);
        return all;
    }

    // The highest-numbered screen of the desktop (\\.\DISPLAYn) and the app windows on it; before: the previous note, whose
    // window outlines are taken over where the windows have not moved (see Outline). null when the desktop has a single
    // screen: there is nothing to keep then.
    public static Snap Snapshot(Snap before) {
        List<KeyValuePair<IntPtr, MONITORINFOEX>> all = Monitors();
        if (all.Count < 2) return null;
        IntPtr best = IntPtr.Zero; int bestN = -1; MONITORINFOEX bm = new MONITORINFOEX();
        Dictionary<IntPtr, int> scale = new Dictionary<IntPtr, int>();
        foreach (KeyValuePair<IntPtr, MONITORINFOEX> m in all) {
            uint dx, dy; scale[m.Key] = GetDpiForMonitor(m.Key, 0, out dx, out dy) == 0 ? (int)Math.Round(dx * 100.0 / 96) : 0;   // 0 = effective DPI; 96 is 100%
            int n = Common.Number(m.Value.device); if (n > bestN) { bestN = n; best = m.Key; bm = m.Value; }
        }
        if (best == IntPtr.Zero) return null;
        Snap s = new Snap(); s.Device = bm.device; s.Left = bm.mon.l; s.Top = bm.mon.t; s.W = bm.mon.r - bm.mon.l; s.H = bm.mon.b - bm.mon.t; s.Scale = scale[best];
        foreach (int other in scale.Values) if (other != s.Scale && other != 0 && s.Scale != 0) s.OtherScale = other;
        StringBuilder text = new StringBuilder(256);
        EnumWindows((h, p) => {   // cheapest tests first: most of the hundreds of top-level windows fall out on the first line
            if (!IsWindowVisible(h) || IsIconic(h) || MonitorFromWindow(h, 0) != best) return true;
            if ((GetWindowLong(h, -20) & 0x20) != 0) return true;   // WS_EX_TRANSPARENT: click-through overlays (GPU vendor overlays, screen dimmers) are not content
            int cloaked; if (DwmGetWindowAttribute(h, 14, out cloaked, 4) == 0 && cloaked != 0) return true;   // hidden by Windows (other virtual desktop, suspended app)
            text.Length = 0; GetClassName(h, text, 256); string cls = text.ToString();
            if (cls == "Progman" || cls == "WorkerW" || cls == "Shell_TrayWnd" || cls == "Shell_SecondaryTrayWnd") return true;   // wallpaper and taskbars
            text.Length = 0; GetWindowText(h, text, 256); if (text.Length == 0) return true;
            Win w = new Win(), was = before == null ? null : before.Find(h); w.H = h;
            if (was != null) { w.whole = was.whole; w.seen = was.seen; }
            if (!Outline(h, ref w.whole, ref w.seen)) return true;
            w.X = w.seen.l - bm.mon.l; w.Y = w.seen.t - bm.mon.t; w.W = w.seen.r - w.seen.l; w.Hgt = w.seen.b - w.seen.t; w.Title = text.ToString();
            Place(w); s.Wins.Add(w); return true;
        }, IntPtr.Zero);
        return s;
    }

    // When the screen leaves the desktop, Windows moves its windows onto another screen, and shrinks or un-maximizes them
    // there (measured: a maximized browser arrived in its smaller, restored size; enlarged to fit, it looked like a lower
    // resolution). So a window that has another size than noted is asked to take its noted size again, in the corner of
    // the screen it is on now (measured: a browser will not reach past the screen's edge from where Windows put it);
    // nobody sees the desktop while the PC is locked. Nobody but the user who unlocks it: Windows shows the screens behind
    // its "Welcome" before the unlock (measured: the kept screen's windows flashed there). So while the sign-in screen is
    // up (hide), they are asked out of sight instead, beside every screen, and put into their place once their screen is
    // back (see Agent.Loop). Not out of sight all through the lock: there most windows stop drawing (measured on Windows 10:
    // a classic window, and a Chrome that draws without the GPU). It asks without waiting (0x4000), so a window that does
    // not answer cannot hold the pictures up; at least half a second apart so that a slow app has the time to answer, and
    // for its size at most 3 times: one that will not take it is fitted instead. Calling one back from out of sight (the
    // sign-in screen went without an unlock) is no such ask: it is never given up.
    static readonly long Half = Stopwatch.Frequency / 2;
    static void Arrange(Win w, Snap s, bool hide) {
        // on no screen: out of sight, or left so when the PC was locked again before its screen was back (it would not draw)
        bool lost = MonitorFromWindow(w.H, 0) == IntPtr.Zero;
        if (hide ? lost : (!lost && w.Sized) || Session.NearUnlock) return;   // not called back amid the unlock: Away just sent it off
        long now = Stopwatch.GetTimestamp();
        if ((!hide && !lost && w.Asked >= 3) || now - w.askedAt < Half) return;
        w.askedAt = now;
        MONITORINFOEX mi;
        if (hide) Move(w.H, Beside(s), s.Top + w.Y, w.W, w.Hgt, w.whole, w.seen);
        else if (Info(MonitorFromWindow(w.H, 2), out mi)) { if (!lost) w.Asked++; Move(w.H, mi.mon.l, mi.mon.t, w.W, w.Hgt, w.whole, w.seen); }   // 2 = the nearest screen
    }
    // right of every screen, the kept one included: still out of sight when it is back (measured: 100 px off on it, before)
    static int Beside(Snap s) { return Math.Max(GetSystemMetrics(76) + GetSystemMetrics(78), s.Left + s.W) + 100; }   // SM_XVIRTUALSCREEN + SM_CXVIRTUALSCREEN
    // The same while the screen is freed but not handed over yet (Windows takes half a second for that, measured): the
    // windows have their size back by the first picture.
    public static void Fit(Snap s, bool hide) {
        foreach (Win w in s.Wins) if (IsWindowVisible(w.H) && !IsIconic(w.H) && Outline(w.H, ref w.whole, ref w.seen)) Arrange(w, s, hide);
    }
    // Asks a window, without waiting, for its visible part (seen, inside whole: Windows adds an invisible border) to be at
    // x, y and w x hgt. A maximized window refuses another place and size (measured: Windows kept one maximized on the
    // other screen, 1280x800 there against 1280x752 noted): it is un-maximized first, without being activated
    // (4 = SW_SHOWNOACTIVATE), and the request queues behind that (measured: both done in one go). 4 = same stacking,
    // 0x10 = no focus.
    static void Move(IntPtr h, int x, int y, int w, int hgt, RECT whole, RECT seen) {
        if (IsZoomed(h)) ShowWindowAsync(h, 4);
        SetWindowPos(h, IntPtr.Zero, x - (seen.l - whole.l), y - (seen.t - whole.t),
            w + (whole.r - whole.l) - (seen.r - seen.l), hgt + (whole.b - whole.t) - (seen.b - seen.t), 0x4000 | 0x4 | 0x10);
    }
    // At the latest the moment Windows says the PC is unlocked (measured: 16 ms before the user's desktop is back), every
    // noted window is asked out of sight while its screen is not back: the sign-in screen was too short for that, say. Not
    // straight into its place where the screen was: its invisible border reaches into the screen beside that place, and
    // Chrome was then fitted into that screen at the unlock (measured).
    public static void Away(Snap s) { Home(s, Beside(s)); }
    // Every noted window into its noted place and size, or at x if given; on whatever thread hears of the unlock, so with
    // outlines of its own: the pictures may be looking at the same windows. Into its place, one that is maximized already
    // is left so (measured: Windows 11 had maximized it there again); PutBack sees to one maximized elsewhere. One that is
    // there already is not asked again: this runs every quarter second behind the sign-in screen (see Agent.Loop).
    public static void Home(Snap s, int x = int.MinValue) {
        foreach (Win w in s.Wins) {
            RECT whole = new RECT(), seen = new RECT();
            if (!IsWindowVisible(w.H) || IsIconic(w.H) || (x == int.MinValue && IsZoomed(w.H)) || !Outline(w.H, ref whole, ref seen)) continue;
            int left = x == int.MinValue ? s.Left + w.X : x, top = s.Top + w.Y;
            if (seen.l != left || seen.t != top || seen.r - seen.l != w.W || seen.b - seen.t != w.Hgt) Move(w.H, left, top, w.W, w.Hgt, whole, seen);
        }
    }
    // The screen is on the desktop (again).
    public static bool Listed(string device) { foreach (KeyValuePair<IntPtr, MONITORINFOEX> m in Monitors()) if (m.Value.device == device) return true; return false; }

    // After the screen was held (a lock, or the setup's test), once the helper has put it back: every noted window goes
    // into its noted place at once, then every one that is not on that screen, or not maximized again although it was,
    // is put back as Windows itself recorded it when it was noted. Windows 11 maximizes them again itself, on Windows 10
    // this does (measured: Windows 10 leaves windows where they are when a screen returns, 19045). That second step 1.5 s
    // after the screen is back: its return is several changes of the desktop in a row, each with new screen handles
    // (measured), Windows 11 puts windows back meanwhile, and Windows gives the focus back to the window that had it
    // (measured: maximized at once, the window took the focus). When the screen does not return within 10 s (unplugged,
    // switched off: the helper's own retries take as long), a window still out of sight would be on no screen: put back
    // the same way, Windows moves it onto one (SetWindowPlacement does that for a place that is off every screen). A
    // window Windows minimized when its screen left (Windows 11 until the sign-out the setup asks for: found in review)
    // comes back too; one minimized after the unlock stays so. Gives up when the PC is locked again.
    public static void PutBack(Snap s) {
        if (s.Device == null || s.Wins.Count == 0) return;
        foreach (Win w in s.Wins) { w.minimized = IsIconic(w.H); w.done = false; }   // before the user can minimize anything
        bool back = false;
        for (int i = 0; i < 100 && !back; i++) {   // on the desktop again: the helper's note goes a second later (measured)
            if (Session.Locked()) return;
            back = Listed(s.Device);
            if (!back) Thread.Sleep(100);
        }
        if (back) { Home(s); SleepWhile(() => !Session.Locked(), 1500); }   // into their place at once; maximized again once the desktop has settled
        if (Session.Locked()) return;   // locked again meanwhile: that lock comes first
        int put = 0, waiting = 0;
        for (int round = 0; ; round++) {   // again every half second, up to 10 s, while a window waits for its app to leave the front (see MayMaximize)
            waiting = 0;
            foreach (Win w in s.Wins) {
                if (w.done || !IsWindowVisible(w.H)) continue;   // done, or hidden by its app meanwhile: left so
                bool iconic = IsIconic(w.H);
                if (iconic && !w.minimized) {   // minimized after the unlock (Win+D, say): so it stays, but un-minimized it returns to its noted place, not out of sight
                    PLACEMENT p = w.place; p.flags = 4 | (p.showCmd == 3 ? 2 : 0); p.showCmd = 7;   // 2 = WPF_RESTORETOMAXIMIZED, 7 = SW_SHOWMINNOACTIVE
                    if (p.length != 0 && SetWindowPlacement(w.H, ref p)) put++;
                    w.done = true; continue;
                }
                IntPtr on = MonitorFromWindow(w.H, 0);   // 0 = none when it is on no screen
                MONITORINFOEX mi; bool here = !iconic && back && on != IntPtr.Zero && Info(on, out mi) && mi.device == s.Device;
                if (!iconic && !(back ? !here || (w.place.showCmd == 3 && !IsZoomed(w.H)) : on == IntPtr.Zero)) continue;
                if (Restore(w, here)) { w.done = true; put++; }
                else if (w.place.showCmd == 3 && !MayMaximize(w.H)) waiting++;
            }
            if (waiting == 0 || round == 20 || !SleepWhile(() => !Session.Locked(), 500)) break;
        }
        if (back) Restack(s);
        if (put > 0) Agent.Log(back ? "put " + put + " window(s) back on " + s.Device : s.Device + " did not return: " + put + " of its window(s) moved onto another screen");
        if (waiting > 0) Agent.Log(waiting + " window(s) on " + s.Device + " left un-maximized, in their place: maximizing them would have taken the keyboard focus from their own app, which was in front");
    }
    // Maximizing a window brings it to the top (measured: a small window on a maximized browser was behind it then; Windows
    // 11 maximizes them too), so the noted windows are stacked as they were again, each right below the one above it;
    // without moving, sizing or activating any (0x4000 = without waiting, 0x10 = no focus, 2 + 1 = place and size kept).
    // Never an ordinary window right below an always-on-top one (WS_EX_TOPMOST, 8): above the others, the taskbar among
    // them, it would become one itself (Windows' rule); it is below them all anyway.
    internal static void Restack(Snap s) {
        for (int i = 1; i < s.Wins.Count; i++) {
            IntPtr up = s.Wins[i - 1].H, h = s.Wins[i].H;
            if (IsWindowVisible(h) && IsWindowVisible(up) && ((GetWindowLong(up, -20) & 8) == 0 || (GetWindowLong(h, -20) & 8) != 0))
                SetWindowPos(h, up, 0, 0, 0, 0, 0x4000 | 0x10 | 0x2 | 0x1);
        }
    }
    internal static void Place(Win w) { w.place.length = Marshal.SizeOf(typeof(PLACEMENT)); if (!GetWindowPlacement(w.H, ref w.place)) w.place.length = 0; }

    // Windows this program asked out of sight and could not put back because it ended meanwhile: visible, not minimized,
    // on no screen, their visible part exactly where Beside puts them (100 px right of all screens, once the kept one is
    // back), and only there: a window an app keeps off the screens itself is left alone. Asked onto a screen when the
    // program starts (SetWindowPlacement moves a window whose place is off every screen onto one). Returns how many.
    public static int Rescue() {
        int at = GetSystemMetrics(76) + GetSystemMetrics(78) + 100, n = 0;
        EnumWindows((h, p) => {
            RECT whole = new RECT(), seen = new RECT(); PLACEMENT pl = new PLACEMENT(); pl.length = Marshal.SizeOf(typeof(PLACEMENT));
            if (IsWindowVisible(h) && !IsIconic(h) && MonitorFromWindow(h, 0) == IntPtr.Zero && Outline(h, ref whole, ref seen) && seen.l == at && GetWindowPlacement(h, ref pl)) {
                pl.flags = 4; pl.showCmd = 4;   // without waiting, not activated
                if (SetWindowPlacement(h, ref pl)) n++;
            }
            return true;
        }, IntPtr.Zero);
        return n;
    }

    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("advapi32.dll")] static extern int RegQueryInfoKey(SafeRegistryHandle key, IntPtr c, IntPtr cl, IntPtr r, IntPtr sk, IntPtr skl, IntPtr cll, IntPtr v, IntPtr vnl, IntPtr vl, IntPtr sd, out long lastWrite);
    // Chrome and Edge take their setting "keep drawing while the PC is locked" (policy WindowOcclusionEnabled = 0, made
    // by the setup) only when they start. Measured on Windows 10: set while Chrome ran, Chrome froze at the next lock, its
    // page dark (3 pictures in a minute; a user saw it as a black graph); restarted, it drew on. Said once per lock for
    // such a browser on the kept screen, after the lock, as a hint: one that started while an earlier setup's setting was in place
    // draws fine although the setting was written again since (measured), and from outside the two look the same.
    public static void BrowserHint(Snap s) {
        string[][] browsers = { new[] { "chrome", @"SOFTWARE\Policies\Google\Chrome", "Chrome", "chrome://restart" }, new[] { "msedge", @"SOFTWARE\Policies\Microsoft\Edge", "Edge", "edge://restart" } };
        foreach (string[] b in browsers) {
            DateTime set = PolicySince(b[1]);
            if (set == DateTime.MinValue) continue;
            foreach (Win w in s.Wins) {
                uint pid; GetWindowThreadProcessId(w.H, out pid);
                try {
                    using (Process p = Process.GetProcessById((int)pid))
                        if (string.Equals(p.ProcessName, b[0], StringComparison.OrdinalIgnoreCase) && p.StartTime < set) {
                            Agent.Log(b[2] + " has been running since " + p.StartTime.ToString("G") + ", longer than its setting to keep drawing while the PC is locked (made " + set.ToString("G") + "): if its page was dark or frozen during the lock, restart it once (" + b[3] + " in its address bar)");
                            break;
                        }
                } catch (Exception) { }   // closed meanwhile, or a process this program may not ask about
            }
        }
    }
    // When the browser's policy WindowOcclusionEnabled = 0 was last written (its key's time); MinValue if it is not set.
    static DateTime PolicySince(string key) {
        using (RegistryKey hklm = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64))
        using (RegistryKey k = hklm.OpenSubKey(key)) {
            long t;
            if (k == null || !Equals(k.GetValue("WindowOcclusionEnabled"), 0)
                || RegQueryInfoKey(k.Handle, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, out t) != 0) return DateTime.MinValue;
            return DateTime.FromFileTime(t);
        }
    }
    // Into its noted place without the focus (4 = SW_SHOWNOACTIVATE), then maximized there if it was (3). In two steps:
    // a window that Windows left maximized on another screen takes no new place in one (measured on Windows 10). A window
    // that is in its place already (here) is maximized where it is instead, and given its noted un-maximized place after
    // that, which a maximized window keeps for later: it does not show its smaller size on the way (measured: it did, for
    // a quarter of a second). Not maximized while MayMaximize says no: false then, the window waiting in its place (here)
    // or put there un-maximized. The flag 4 = WPF_ASYNCWINDOWPLACEMENT: asked without waiting, so a window that does not
    // answer cannot hold this program up.
    internal static bool Restore(Win w, bool here) {
        if (w.place.length == 0) return false;
        bool max = w.place.showCmd == 3, may = !max || MayMaximize(w.H);
        PLACEMENT p = w.place, now = new PLACEMENT(); p.flags = 4; now.length = p.length;
        if (here && max) {
            if (!may || !GetWindowPlacement(w.H, ref now)) return false;
            now.flags = 4; now.showCmd = 3;
            if (!SetWindowPlacement(w.H, ref now)) return false;
            p.showCmd = 8;   // SW_SHOWNA: left as it is (maximized), not activated
            return SetWindowPlacement(w.H, ref p);
        }
        p.showCmd = 4;
        if (!SetWindowPlacement(w.H, ref p) || !may) return false;
        if (!max) return true;
        p.showCmd = 3;
        return SetWindowPlacement(w.H, ref p);
    }
    // Maximizing activates a window (SW_SHOWMAXIMIZED). Windows lets that through, and the keyboard focus with it, when the
    // window in front belongs to the same thread (an app with windows on both screens, in front at the unlock: found in
    // review), or when no window is in front; else the focus stays where it is (measured: maximized 1.5 s after the
    // unlock, the window did not take it). One that has the focus already may be maximized.
    static bool MayMaximize(IntPtr h) {
        IntPtr fg = GetForegroundWindow(); uint pid;
        return fg == h || (fg != IntPtr.Zero && GetWindowThreadProcessId(fg, out pid) != GetWindowThreadProcessId(h, out pid));
    }

    static Frame scratch;
    // Draw a window's visible part into its place in dst: pixel for pixel when the sizes match, else fitted into its place,
    // keeping its proportions. false when the window has no picture.
    // 2 = PW_RENDERFULLCONTENT: the picture comes from the window compositor, so GPU-drawn apps (Chrome) work and the
    // window may be covered by others. Measured: it keeps delivering fresh pictures while locked. Measured too: it
    // always draws the whole window at the top-left corner of the bitmap, ignoring the DC's origin and clipping. Hence
    // the detour through a bitmap of its own, from which the visible part is copied into place; only a window without
    // invisible borders that is exactly the whole picture (a full-screen browser) can be drawn straight into it.
    static bool Blit(Win win, Frame dst) {
        int x = win.bx, y = win.by, w = win.bw, h = win.bh;
        RECT whole = win.whole, seen = win.seen;
        int ww = whole.r - whole.l, wh = whole.b - whole.t, fx = seen.l - whole.l, fy = seen.t - whole.t, fw = seen.r - seen.l, fh = seen.b - seen.t;
        bool exact = fw == w && fh == h;
        if (exact && fw == ww && fh == wh && x == 0 && y == 0 && w == dst.W && h == dst.H) return PrintWindow(win.H, dst.Dc, 2);
        if (scratch == null || scratch.W < ww || scratch.H < wh) {   // kept between pictures, grown when a bigger window comes along
            int nw = Math.Max(ww, scratch == null ? 0 : scratch.W), nh = Math.Max(wh, scratch == null ? 0 : scratch.H);
            Frame old = scratch; scratch = null; if (old != null) old.Dispose();   // never left pointing at a freed bitmap, should the new one fail
            scratch = new Frame(nw, nh);
        }
        if (!PrintWindow(win.H, scratch.Dc, 2)) return false;
        if (exact) return BitBlt(dst.Dc, x, y, w, h, scratch.Dc, fx, fy, 0x00CC0020);   // SRCCOPY
        double k = Math.Min((double)w / fw, (double)h / fh);
        int tw = Math.Max(1, (int)Math.Round(fw * k)), th = Math.Max(1, (int)Math.Round(fh * k));
        SetStretchBltMode(dst.Dc, 4); SetBrushOrgEx(dst.Dc, 0, 0, IntPtr.Zero);   // 4 = HALFTONE: averages pixels when shrinking
        return StretchBlt(dst.Dc, x + (w - tw) / 2, y + (h - th) / 2, tw, th, scratch.Dc, fx, fy, fw, fh, 0x00CC0020);
    }

    // Redraw the noted screen: every window's live picture at the place it had, stacked as it was. Returns how many were
    // drawn. Windows moved these windows to another screen when this one left the desktop; they are drawn where they were.
    // Each window is looked at once per picture. A window completely behind another one is not captured at all (on the
    // screen it was hidden too), and a window drawn over the whole picture leaves nothing below it to draw or to clear.
    // hide: the sign-in screen is up (see Arrange).
    public static int CaptureWindows(Snap s, Frame dst, bool hide = false) {
        double k = Math.Min((double)dst.W / s.W, (double)dst.H / s.H);   // one factor for both directions: nothing gets stretched
        double ox = (dst.W - s.W * k) / 2, oy = (dst.H - s.H * k) / 2;
        int full = -1;   // the top-most window drawn over the whole picture, if there is one
        for (int i = 0; i < s.Wins.Count; i++) {   // top-most first: how every window is right now
            Win w = s.Wins[i];
            w.bx = (int)Math.Round(ox + w.X * k); w.by = (int)Math.Round(oy + w.Y * k); w.bw = (int)Math.Round(w.W * k); w.bh = (int)Math.Round(w.Hgt * k);
            // not drawn: a window closed, minimized or hidden by its app meanwhile (a hidden one could cover those below it)
            w.live = w.bw > 0 && w.bh > 0 && IsWindowVisible(w.H) && !IsIconic(w.H) && Outline(w.H, ref w.whole, ref w.seen);
            if (!w.live) continue;
            Arrange(w, s, hide);
            if (full < 0 && w.Exact && w.bx <= 0 && w.by <= 0 && w.bx + w.bw >= dst.W && w.by + w.bh >= dst.H) full = i;
        }
        if (full < 0) dst.Clear();
        int drawn = 0;
        for (int i = full >= 0 ? full : s.Wins.Count - 1; i >= 0; i--) {   // bottom-most first
            if (!s.Wins[i].live || Hidden(s, i)) continue;
            if (Blit(s.Wins[i], dst)) drawn++;
        }
        GdiFlush();
        return drawn;
    }
    static bool Hidden(Snap s, int i) { for (int j = 0; j < i; j++) if (s.Wins[j].Covers(s.Wins[i])) return true; return false; }

    public static void Notice(Frame b, string text) {
        using (Graphics g = Graphics.FromImage(b.Gdi))
        using (Font f = new Font("Segoe UI", b.H / 28f, GraphicsUnit.Pixel))
        using (Brush w = new SolidBrush(Color.FromArgb(200, 200, 200))) {
            g.Clear(Color.FromArgb(16, 24, 40));
            g.DrawString(text + "\n" + DateTime.Now.ToString("HH:mm:ss"), f, w, 40, 40);
        }
    }

    static Snap noted, latest;
    // Sleeps while the PC is unlocked, noting every 0.7 s what is on the last screen, and returns the note at once when
    // the PC gets locked: the note from one round earlier, because the newest one may already contain the lock screen.
    // Nothing is noted while the helper holds a screen off the desktop (the "last" screen would be the wrong one).
    // With mayCheck it also returns, as a note with Check set, when the setup asks for its test (see Agent.Check).
    // A screen saver that locks the PC when it ends covers the kept screen too, and Windows hands no screen to this
    // program while it is up (measured: refused for as long as it ran, at once when the PC was locked). Past its grace
    // period (see Session.Saver) only the password leads back to the desktop: the PC is locked then, as it would be at
    // the screen saver's end, and the kept screen shows its windows. Once per screen saver; not with a single screen.
    [DllImport("user32.dll")] static extern bool LockWorkStation();
    public static Snap WaitForLock(bool mayCheck) {
        GC.Collect(); EmptyWorkingSet(GetCurrentProcess());   // this wait lasts hours: hand back the memory the last lock used
        int kept = 0; bool saverLocked = false;
        while (!Session.Locked()) {
            string held = Common.Taken();
            if (held == null) { kept = 0; noted = latest; latest = Snapshot(latest); }
            else if (mayCheck && Common.Note("Check") != null) {   // with the windows noted before the test took the screen, for PutBack
                Snap c = new Snap(), n = noted ?? latest; c.Check = true; if (n != null) { c.Device = n.Device; c.Left = n.Left; c.Top = n.Top; c.W = n.W; c.H = n.H; c.Wins = n.Wins; }
                return c;
            }
            else if (++kept >= 8 && Session.Unlocked() && AskToGiveBack(held)) kept = -7;   // asked: allow 10 s before asking again
            if (!Session.Saver()) saverLocked = false;
            else if (!saverLocked && held == null && latest != null) {
                saverLocked = true;
                Agent.Log("a screen saver that locks the PC when it ends has been up for its grace period: " + (LockWorkStation() ? "locked the PC now, so that " + latest.Device + " shows its windows" : "Windows refused to lock the PC now"));
            }
            Session.Wait(700);
        }
        return noted ?? latest ?? new Snap();
    }

    // The PC has been unlocked for 5 s and the helper still holds the screen: it was unplugged or switched off at the
    // moment of unlocking, so it could not be put back, and Windows remembers "off the desktop" for it (measured: it
    // would stay unused until the next unlock). Once it is connected again, ask Windows to run the give-back task.
    // true when asked.
    static bool AskToGiveBack(string held) {
        try { return Common.OffDesktop(held) == true && Agent.RunTask("LockMonitor-Give"); }   // where the screen is now, also after a restart
        catch (Exception) { return false; }   // a note this program cannot read: the next unlock puts the screen back
    }
    // The newest note may have been made while the lock was already starting: go on from the one known to be good.
    // And do not sit on a screen-sized bitmap until the next lock.
    public static void LockEnded() { latest = noted; if (scratch != null) { scratch.Dispose(); scratch = null; } }

    // Sleeps ms, but returns false as soon as go says stop: at an unlock the screen must go back without delay (an
    // unlock, a sleep or a wake-up end the wait at once; go is looked at every 250 ms besides).
    public static bool SleepWhile(Func<bool> go, int ms) {
        long end = Stopwatch.GetTimestamp() + ms * Stopwatch.Frequency / 1000;
        for (;;) {
            if (!go()) return false;
            long left = (end - Stopwatch.GetTimestamp()) * 1000 / Stopwatch.Frequency;
            if (left <= 0) return true;
            Session.Wait((int)Math.Min(250, left));
        }
    }
}

// D3D11 on the adapter that owns the screen. COM is called through raw vtable slots (no SDK needed to build this);
// the self-test exercises every slot used.
public class Gfx : IDisposable {
    [StructLayout(LayoutKind.Sequential)] struct TexDesc { public uint W, H, Mips, ArraySize, Format, SampCount, SampQuality, Usage, Bind, Cpu, Misc; }
    [StructLayout(LayoutKind.Sequential)] struct Mapped { public IntPtr Data; public uint RowPitch, DepthPitch; }
    [StructLayout(LayoutKind.Sequential)] struct QDesc { public uint Query, Misc; }
    [StructLayout(LayoutKind.Sequential)] struct Box { public uint Left, Top, Front, Right, Bottom, Back; }
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
    delegate void FnUpdate(IntPtr self, IntPtr res, uint sub, ref Box box, IntPtr data, uint rowPitch, uint depthPitch);
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
        IntPtr factory = IntPtr.Zero, adapter = IntPtr.Zero; int level;
        try {
            Check(CreateDXGIFactory1(ref iidFactory4, out factory), "CreateDXGIFactory1");
            Check(Slot<FnByLuid>(factory, 26)(factory, ((long)luidHigh << 32) | luidLow, ref iidAdapter, out adapter), "EnumAdapterByLuid");
            AdapterDesc ad; Check(Slot<FnDesc>(adapter, 8)(adapter, out ad), "GetDesc"); AdapterName = ad.Name;
            Check(D3D11CreateDevice(adapter, 0, IntPtr.Zero, 0x20, IntPtr.Zero, 0, 7, out dev, out level, out ctx), "D3D11CreateDevice");
        } finally { Release(adapter); Release(factory); }
        try {   // a half-made device is let go of here: nobody else can, the constructor did not finish
            Check(Slot<FnQI>(dev, 0)(dev, ref iidDev1, out dev1), "ID3D11Device1");
            open1 = Slot<FnOpen1>(dev1, 48); createTex = Slot<FnTex>(dev, 5);
            update = Slot<FnUpdate>(ctx, 48); copy = Slot<FnCopy>(ctx, 47); map = Slot<FnMap>(ctx, 14); unmap = Slot<FnUnmap>(ctx, 15);
            end = Slot<FnEnd>(ctx, 28); getData = Slot<FnData>(ctx, 29);
            QDesc q = new QDesc(); q.Query = 0;   // D3D11_QUERY_EVENT (0): lets the CPU wait until the GPU finished the upload
            Check(Slot<FnQuery>(dev, 24)(dev, ref q, out query), "CreateQuery");
        } catch { Dispose(); throw; }
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

    // Rows [top, bottom) of the picture into the texture of the same size. Returns once the GPU has them, so they can be shown.
    public void Upload(IntPtr tex, Frame f, int top, int bottom) {
        if (bottom <= top) return;
        Box b = new Box(); b.Top = (uint)top; b.Right = (uint)f.W; b.Bottom = (uint)bottom; b.Back = 1;
        update(ctx, tex, 0, ref b, f.Bits + top * f.Stride, (uint)f.Stride, 0);
        end(ctx, query);
        long t0 = Stopwatch.GetTimestamp(); int done, hr;
        while ((hr = getData(ctx, query, out done, 4, 0)) != 0) {
            if (hr < 0) throw new COMException("the GPU was lost during an upload, HRESULT 0x" + hr.ToString("X8"), hr);
            long ms = (Stopwatch.GetTimestamp() - t0) * 1000 / Stopwatch.Frequency;
            if (ms > 2000) throw new TimeoutException("the GPU did not finish an upload");
            if (ms < 5) Thread.Yield(); else Thread.Sleep(1);   // it takes a millisecond or two: do not sleep a whole 15 ms timer tick for that
        }
    }

    // A known colour into the texture, then one pixel of another colour as a one-row upload, and both read back: the proof
    // that the texture takes whole pictures and changed rows. w and h: the texture's size.
    public bool RoundTrip(IntPtr tex, int w, int h, out string seen) {
        using (Frame f = new Frame(w, h)) {
            using (Graphics g = Graphics.FromImage(f.Gdi)) g.Clear(Color.FromArgb(10, 20, 30));
            Upload(tex, f, 0, h);
            f.Gdi.SetPixel(5, 7, Color.FromArgb(200, 100, 50));
            Upload(tex, f, 7, 8);
        }
        int p0 = ReadPixel(tex, 0, 0) & 0xFFFFFF, p1 = ReadPixel(tex, 5, 7) & 0xFFFFFF;
        seen = "pixels 0x" + p0.ToString("X6") + " / 0x" + p1.ToString("X6");
        return p0 == 0x0A141E && p1 == 0xC86432;
    }

    // the same with a texture shared by NT handle, as a display surface is
    public bool SelfTest(out string seen) {
        TexDesc d = new TexDesc(); d.W = 64; d.H = 32; d.Mips = 1; d.ArraySize = 1; d.Format = 87; d.SampCount = 1; d.Bind = 0x20; d.Misc = 0x2 | 0x800;
        IntPtr tex, res1, h;
        Check(createTex(dev, ref d, IntPtr.Zero, out tex), "CreateTexture2D");
        Guid iidRes1 = new Guid("30961379-4609-4a41-998e-54fe567ee0c1");
        Check(Slot<FnQI>(tex, 0)(tex, ref iidRes1, out res1), "IDXGIResource1");
        Check(Slot<FnShare>(res1, 13)(res1, IntPtr.Zero, 0x80000001, IntPtr.Zero, out h), "IDXGIResource1.CreateSharedHandle");
        IntPtr opened = OpenHandle(h); CloseHandle(h);
        try { return RoundTrip(opened, 64, 32, out seen); } finally { Release(opened); Release(res1); Release(tex); }
    }

    // What kind of texture this is (ID3D11Texture2D::GetDesc, slot 10).
    public string Describe(IntPtr tex) {
        TexDesc d; Slot<FnTexDesc>(tex, 10)(tex, out d);
        return d.W + "x" + d.H + " format " + d.Format + " usage " + d.Usage + " bind 0x" + d.Bind.ToString("X") + " misc 0x" + d.Misc.ToString("X");
    }

    // One pixel of a texture, read back through a staging copy.
    int ReadPixel(IntPtr tex, int x, int y) {
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
    static string Code(Exception e) { return e == null ? "" : " (0x" + e.HResult.ToString("X8") + ")"; }   // Windows' own error number, when it gives one
    static Exception Refused(string what, DisplayManagerResultWithState r) {
        string text = what + ": " + r.ErrorCode + Code(r.ExtendedErrorCode);
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
    // the first of them (given the mode and adapter). framesTo (test): the pictures go to PNG files in that folder and
    // the screen is only owned. Throws NotReady when Windows is still busy with the screen, anything else when it really
    // cannot be done.
    public static void Pictures(string held, Pix.Snap noted, string notice, string framesTo, Func<bool> go, Func<string, string> firstLine, ref int shown) {
        Session.Free.Reset();
        try { if (go()) Run(held, noted, notice, framesTo, go, firstLine, ref shown); }   // asked after the reset: a sleep announced just before it is seen
        // every display object is let go of the moment the pictures stop: the helper is waiting to put the screen back
        finally { GC.Collect(); GC.WaitForPendingFinalizers(); Session.Free.Set(); }
    }

    static void Run(string held, Pix.Snap noted, string notice, string framesTo, Func<bool> go, Func<string, string> firstLine, ref int shown) {
        uint lo, id; int hi; Common.Address(held, out lo, out hi, out id);   // where the screen is now, also after a restart
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
            if (applied.Status != DisplayStateOperationStatus.Success) throw new InvalidOperationException("the screen's mode could not be set: " + applied.Status + Code(applied.ExtendedErrorCode));
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
            int i = 0, still = 0, top, bottom; bool first = true, said = false;
            int[] staleTop = { 0, 0 }, staleBottom = { hgt, hgt };   // the rows each of the two surfaces still lacks: all of them at first
            while (go()) {
                int drawn = noted != null && noted.Wins.Count > 0 ? Pix.CaptureWindows(noted, frame, Session.SigningIn()) : 0;
                if (drawn == 0) {   // say why the screen is empty, on the screen itself and once in the log
                    string why = notice != null ? notice
                        : noted.Wins.Count == 0 ? "Nothing was open on this screen when the PC was locked"
                        : "The windows of this screen cannot be shown: they were closed, or Windows minimized them\nwhen the screen left the desktop. If they were minimized (Windows 11): sign out and back in\nonce. The setup changed a Windows setting for that, and it takes effect only at sign-in.";
                    Pix.Notice(frame, why);
                    if (!said && notice == null && noted.Wins.Count > 0) { said = true; Agent.Log("no window picture: " + why.Replace('\n', ' ')); }
                }
                if (frame.Changed(out top, out bottom)) {   // an unchanged picture is neither uploaded nor shown again
                    still = 0;
                    if (framesTo != null) { if (shown % 8 == 0) frame.Gdi.Save(Path.Combine(framesTo, "frame-" + shown.ToString("0000") + ".png"), ImageFormat.Png); }
                    else {
                        // the pictures alternate between two surfaces, so each one gets every row changed since it was last shown
                        for (int k = 0; k < 2; k++) { staleTop[k] = Math.Min(staleTop[k], top); staleBottom[k] = Math.Max(staleBottom[k], bottom); }
                        gfx.Upload(tex[i], frame, staleTop[i], staleBottom[i]);
                        staleTop[i] = hgt; staleBottom[i] = 0;
                        DisplayTask task = pool.CreateTask(); task.SetScanout(scan[i]);
#pragma warning disable 618   // Windows 11 marks ExecuteTask as superseded; it is the call Windows 10 has too, and the one proven on real hardware
                        pool.ExecuteTask(task);
#pragma warning restore 618
                        Let(task);   // one per picture: not left to the garbage collector through a lock of hours
                        dev.WaitForVBlank(src);
                        i = 1 - i;
                    }
                    shown++;
                    if (first) {
                        first = false; Agent.Log(firstLine(w + "x" + hgt + (gfx == null ? ", to files" : " on " + gfx.AdapterName)));
                        // Measured, and nothing this program can change: while the screen is off the desktop its windows live on
                        // another screen, and each app draws its window for the scaling of the screen it is on.
                        if (noted != null && noted.OtherScale != 0 && !toldScaling) {
                            toldScaling = true;
                            Agent.Log("the picture is larger or smaller than it was on the screen: this screen is scaled " + noted.Scale + "%, another one " + noted.OtherScale
                                + "%, and while this one is off the desktop its windows are drawn for the other. The same scaling on all screens (Settings > System > Display > Scale) gives an identical picture");
                        }
                    }
                } else still++;
                // windows have to be asked for their picture: 4 times a second while it changes, once a second after 2 s
                // without change, and once a second when nothing can be drawn (the notice changes with its clock only)
                if (!Pix.SleepWhile(go, still >= 8 || drawn == 0 ? 1000 : 250)) break;
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

    // A few lines per lock at most (see Common.Log); on the console for -selftest.
    public static void Log(string m) { if (logFile == null) Console.WriteLine(m); else Common.Log(logFile, m); }

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
            int lost = Pix.Rescue();
            if (lost > 0) Log(lost + " window(s) left out of sight at an earlier unlock moved onto a screen");
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
            if (noted.Check) { checkedOnce = true; Check(framesTo); Pix.PutBack(noted); continue; }
            // since: the lock, or the PC's latest wake-up during it; quiet: how long Windows' "not ready" goes unsaid (below)
            Stopwatch locked = Stopwatch.StartNew(), since = Stopwatch.StartNew(), quiet = Stopwatch.StartNew();
            // gaveAt: when the screen was given back for the sign-in screen (below), -1 when it was not
            int naps = Session.Naps, fails = 0, shown = 0, dozes = 0; bool freed = false, woke = false, asked = false; double freedAt = -1, look = 3, gaveAt = -1;
            while (Session.Locked()) {
                if (naps != Session.Naps) {   // the PC is about to sleep, or woke up: from the start again (Show lets go of the screen meanwhile)
                    naps = Session.Naps; since.Restart(); fails = 0; dozes = 0; woke = true; asked = false; freedAt = -1; look = 3; gaveAt = -1;
                    foreach (Pix.Win w in noted.Wins) w.Asked = 0;   // the screens may have changed sizes meanwhile
                }
                // Nothing while the PC goes to sleep: at most 30 waits, counted rather than timed, should the wake-up go
                // unsaid (measured in the VMs: the clock also counts the time asleep)
                if (Session.Asleep && dozes++ < 30) { Session.Wait(1000); continue; }
                string held = Common.Taken();
                if (held != null && freedAt < 0) {
                    freedAt = since.Elapsed.TotalSeconds; quiet.Restart(); freed = true;
                    // a lock that came while the displays were dark (an automatic one) would leave them so (see Pwr); not
                    // after a wake-up, which Windows also makes by itself (for updates at night, say), with nobody there
                    if (!woke) Pwr.Wake();
                    // at the unlock the windows go out of sight until their screen is back, unless it is back already
                    // (below) or no longer connected: it will not come back then, and they stay where they are
                    string note = held;
                    Session.Unlocking = () => { if (Common.OffDesktop(note) == true) Pix.Away(noted); };
                }
                // The user is back, the sign-in screen up: the screen goes back to the desktop now, behind it, not after the unlock.
                // Its return makes Windows drop the taskbar's room on the other screens for a moment, so that their
                // maximized windows change size: three times in a row when it came back after the unlock, once behind
                // the sign-in screen and once at the unlock (measured; Windows gives the room back only then). Its windows
                // go into their place once it is on the desktop, out of sight until then. Not when it is no longer
                // connected: it could not come back.
                if (Session.UserBack()) {
                    if (held != null && gaveAt < 0 && Common.OffDesktop(held) == true) { gaveAt = since.Elapsed.TotalSeconds; RunTask("LockMonitor-Give"); }
                    if (noted.Device != null && Pix.Listed(noted.Device)) Pix.Home(noted);
                    else if (gaveAt >= 0) Pix.Fit(noted, true);
                    Session.Wait(250); continue;
                }
                if (gaveAt >= 0) {   // given back for a sign-in screen that went without an unlock
                    if (held != null && since.Elapsed.TotalSeconds - gaveAt < 12) { Session.Wait(250); continue; }   // still being put back (the helper allows 10 s)
                    gaveAt = -1;
                    if (held == null) {   // taken again, as at a lock (freedAt, fails: found in review); the displays may have gone dark meanwhile
                        asked = RunTask("LockMonitor-Take"); Pwr.Wake(); freedAt = -1; fails = 0;
                        Log("the sign-in screen went without an unlock: " + (asked ? "asked the helper to take " + noted.Device + " again" : "the helper could not be started"));
                    }
                }
                if (held == null) {
                    // The helper frees the screen within a second of a lock. Not so 3 s after a lock or a wake-up, although
                    // the screen is on the desktop (the lock came with a sleep, say, and the helper ran before the screen
                    // was back): ask Windows to run the helper again, once, and once more whenever the screen comes back
                    // (a monitor that took long to wake up, or was switched on). Looked at once a second.
                    if (noted.Device != null && since.Elapsed.TotalSeconds >= look) {
                        look = Math.Floor(since.Elapsed.TotalSeconds) + 1;
                        bool here = Takeable(noted.Device);
                        if (here && !asked) {
                            asked = true;
                            Log(noted.Device + " is on the desktop but was not freed " + since.Elapsed.TotalSeconds.ToString("0") + " s after " + (woke ? "waking up" : "the lock")
                                + (RunTask("LockMonitor-Take") ? ": asked the helper again" : ", and the helper could not be started"));
                        }
                        if (!here) asked = false;
                    }
                    // a monitor that is off stays so for a night, say: after half a minute the note is looked at once a second
                    Session.Wait(since.Elapsed.TotalSeconds < 30 ? 50 : 1000);
                    continue;
                }
                Stopwatch ran = Stopwatch.StartNew();
                int n = naps;
                Func<bool> go = () => Session.Locked() && Session.Naps == n && !Session.UserBack();
                Pix.Fit(noted, Session.SigningIn());
                try {
                    Show.Pictures(held, noted, null, framesTo, go, d => "showing " + noted.Wins.Count + " window(s) of " + noted.Device + ", "
                        + since.Elapsed.TotalSeconds.ToString("0.0") + " s after " + (woke ? "waking up" : "the lock") + " (freed after " + freedAt.ToString("0.0") + " s; " + d + ")", ref shown);
                } catch (Exception e) {
                    if (ran.Elapsed.TotalSeconds > 60) { fails = 0; quiet.Restart(); }   // it had been working: a new problem, not the old one again
                    // ask again at once for the first 20 s, without a word: Windows answers so at nearly every lock for a moment
                    // (measured, Windows 10 and 11); the delay shows in the "showing" line. After that, and for real refusals,
                    // after 2 s, 4 s, ... at most a minute, each logged: no busy loop, no flood in the log
                    if (e is NotReady && quiet.Elapsed.TotalSeconds < 20) { Session.Wait(50); continue; }
                    fails++; Log(e is NotReady || e is InvalidOperationException ? e.Message : e.GetType().Name + ": " + e.Message);
                    Pix.SleepWhile(go, 1000 * Math.Min(60, 2 * fails));
                }
            }
            Session.Unlocking = null;
            if (noted.Device != null || freed)   // on a single-screen desktop there is nothing to say
                Log("lock over after " + locked.Elapsed.TotalSeconds.ToString("0") + " s, " + (shown > 0 ? shown + " picture(s)"
                    : freed ? "no picture: Windows never handed the screen over" : "no picture: the helper did not free the screen (its reasons are in switch.log next to it)"));
            Pix.LockEnded();
            Pix.PutBack(noted);   // also after a lock that never freed the screen: windows left out of sight by the one before come back
            if (shown > 0) Pix.BrowserHint(noted);   // afterwards: it asks Windows about processes, which takes milliseconds, and the first picture comes first
        }
    }

    // The noted screen is on the desktop, with the monitor the helper keeps on it (or none is chosen yet): the helper
    // would take it now.
    static bool Takeable(string device) {
        string keep = Common.Note("Keep") as string;
        foreach (Common.Screen s in Common.Screens())
            if (s.Device == device) return keep == null || Common.MonitorPath(s.Lo, s.Hi, s.Id) == keep;
        return false;
    }
    // Have Windows run one of the setup's scheduled tasks now: the user may start them, and they do what this program has
    // no rights to do. true when asked.
    public static bool RunTask(string name) {
        try {
            ProcessStartInfo p = new ProcessStartInfo(Environment.SystemDirectory + @"\schtasks.exe", "/run /tn " + name);
            p.UseShellExecute = false; p.CreateNoWindow = true;
            using (Process.Start(p)) { }
            return true;
        } catch (Exception) { return false; }
    }

    // The setup's test, once per start of this program: while the PC is unlocked, the setup has the helper take the
    // screen and leaves the note "Check" (only administrators can). Show a text on the screen for a few seconds, the
    // same way as at a lock, and say in the log how it went. No window is shown. The setup then puts the screen back.
    static void Check(string framesTo) {
        Stopwatch t = Stopwatch.StartNew(); int shown = 0; string why = "the screen was not freed";
        while (shown == 0 && t.Elapsed.TotalSeconds < 12) {
            string held = Common.Taken(); if (held == null) break;
            Stopwatch on = Stopwatch.StartNew();
            try {
                Show.Pictures(held, null, "LockMonitor test picture\nWhen the PC is locked, this screen keeps showing its windows.", framesTo,
                    () => on.Elapsed.TotalSeconds < 4 && Common.Taken() != null, d => "check: the test picture is on the screen (" + d + ")", ref shown);
            } catch (Exception e) { why = e.Message; Session.Wait(e is NotReady ? 50 : 1000); }
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
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
    // x is somewhere above y in the stacking of the desktop's windows (2 = GW_HWNDNEXT: the next one down)
    static bool Above(IntPtr x, IntPtr y) { for (IntPtr h = GetWindow(x, 2); h != IntPtr.Zero; h = GetWindow(h, 2)) if (h == y) return true; return false; }
    static readonly Color Orange = Color.FromArgb(200, 100, 50), Blue = Color.FromArgb(40, 60, 200), Green = Color.FromArgb(30, 160, 60);
    static Forms.Form TestWindow(int x, int y, int w, int h, Color c, bool framed) {
        Forms.Form f = new Forms.Form();
        f.Text = "LockMonitor self-test"; f.StartPosition = Forms.FormStartPosition.Manual; f.ShowInTaskbar = false; f.BackColor = c;
        if (!framed) f.FormBorderStyle = Forms.FormBorderStyle.None;
        f.SetBounds(x, y, w, h);
        ShowWindow(f.Handle, 4);   // shown without taking the focus
        return f;
    }
    static Pix.Win Noted(Forms.Form f, int x, int y, Rectangle v) { Pix.Win w = new Pix.Win(); w.H = f.Handle; w.X = x; w.Y = y; w.W = v.Width; w.Hgt = v.Height; return w; }
    // Windows needs a moment before a newly shown window has a picture: until then it is captured black, for more than
    // 0.4 s right after other windows were closed (measured). Wait until its centre is no longer black, at most 3 s.
    static void Settle(Forms.Form f) {
        for (int i = 0; i < 30; i++) {
            Forms.Application.DoEvents(); Thread.Sleep(100);
            Rectangle v = Pix.Visible(f.Handle);
            Pix.Snap s = new Pix.Snap(); s.W = v.Width; s.H = v.Height; s.Wins.Add(Noted(f, 0, 0, v));
            using (Frame t = new Frame(v.Width, v.Height))
                if (Pix.CaptureWindows(s, t) == 1 && (t.Gdi.GetPixel(v.Width / 2, v.Height / 2).ToArgb() & 0xFFFFFF) != 0) return;
        }
    }

    static int SelfTest() {
        Console.WriteLine("LockMonitor " + Version + " self-test. Nothing is changed.");
        using (DisplayManager dm = DisplayManager.Create(DisplayManagerOptions.None)) {
            DisplayTarget any = null;
            foreach (DisplayTarget t in dm.GetCurrentTargets()) {
                if (!t.IsConnected) continue;
                if (any == null) any = t;
                DisplayAdapterId a = t.Adapter.Id;
                Console.WriteLine("screen " + (t.UsageKind + ", target " + t.AdapterRelativeId).PadRight(45) + ": " + Common.Describe(a.LowPart, a.HighPart, t.AdapterRelativeId));
            }
            if (any == null) { Console.WriteLine("no screen is connected"); return 1; }
            DisplayAdapterId id = any.Adapter.Id;
            using (Gfx g = new Gfx(id.LowPart, id.HighPart)) {
                Console.WriteLine("graphics adapter".PadRight(52) + ": " + g.AdapterName);
                string seen;
                Line("picture to a shared GPU texture and back", g.SelfTest(out seen), seen);
                // a real display surface, allocated but never shown, must open as a texture, take pictures and give them back
                try {
                    Direct3DMultisampleDescription ms = new Direct3DMultisampleDescription(); ms.Count = 1;
                    DisplayPrimaryDescription desc = new DisplayPrimaryDescription(256, 128, DirectXPixelFormat.B8G8R8A8UIntNormalized, DirectXColorSpace.RgbFullG22NoneP709, false, ms);
                    DisplayDevice dev = dm.CreateDisplayDevice(any.Adapter);
                    IntPtr tex = g.OpenSurface(dev, dev.CreatePrimary(any, desc));
                    try { Line("picture to a display surface and back", g.RoundTrip(tex, 256, 128, out seen), seen + ", surface " + g.Describe(tex)); }
                    finally { Gfx.Free(tex); }
                } catch (Exception e) { Line("picture to a display surface and back", false, e.Message.Trim() + ". This display driver cannot give a screen to a program"); }
            }
        }
        Console.WriteLine("not testable here".PadRight(52) + ": owning a screen and showing on it; the setup tests that live");

        Show.Mode[] m = new Show.Mode[4];
        m[0].W = 1920; m[0].H = 1080; m[0].Hz = 60; m[1].W = 1920; m[1].H = 1200; m[1].Hz = 75; m[2].W = 1920; m[2].H = 1200; m[2].Hz = 0; m[3].W = 1920; m[3].H = 1200; m[3].Hz = 59.94;
        Line("choice of the screen mode", Show.Choose(m) == 3 && Show.Choose(new Show.Mode[0]) == -1, "");
        bool kept = Pwr.Keep(true); Pwr.Keep(false);
        Line("request to keep PC and displays on", kept, "");

        // the picture path, against windows of our own in known colours
        using (Forms.Form a = TestWindow(60, 60, 320, 200, Orange, true), b = TestWindow(120, 100, 120, 90, Blue, true))
        using (Frame shot = new Frame(640, 400)) {
            Settle(a); Settle(b);
            Rectangle va = Pix.Visible(a.Handle);
            Pix.Snap note = new Pix.Snap(); note.W = 640; note.H = 400;
            Pix.Win wa = Noted(a, 100, 50, va); note.Wins.Add(wa);
            int drawn = Pix.CaptureWindows(note, shot), top, bottom;
            Color inside = shot.Gdi.GetPixel(100 + va.Width / 2, 50 + va.Height - 12), left = shot.Gdi.GetPixel(96, 50 + va.Height - 12), below = shot.Gdi.GetPixel(100 + va.Width / 2, 50 + va.Height + 4);
            Line("window redrawn in its place, pixel for pixel", drawn == 1 && Near(inside, 200, 100, 50) && Near(left, 0, 0, 0) && Near(below, 0, 0, 0), "inside " + Rgb(inside) + ", left " + Rgb(left) + ", below " + Rgb(below));
            Line("an unchanged picture is recognised", shot.Changed(out top, out bottom) && Pix.CaptureWindows(note, shot) == 1 && !shot.Changed(out top, out bottom), "");
            shot.Gdi.SetPixel(10, 123, Color.White);
            bool band = shot.Changed(out top, out bottom) && top == 123 && bottom == 124;
            string rows = "rows " + top + " to " + bottom;
            Line("only the changed rows are reported", band && !shot.Changed(out top, out bottom), rows);
            note.Wins.Add(Noted(b, 130, 80, Pix.Visible(b.Handle)));   // below the first window, inside its place
            drawn = Pix.CaptureWindows(note, shot);
            Line("a window hidden behind another is not captured", drawn == 1, "drawn " + drawn);
            note.Wins.RemoveAt(1);
            // at the unlock out of sight, beside every screen; in its noted place again once its screen is back
            Rectangle vb = Pix.Visible(b.Handle), at = vb;
            Pix.Snap trip = new Pix.Snap(); trip.Left = vb.X - 20; trip.Top = vb.Y - 30; trip.W = 640; trip.H = 400; trip.Wins.Add(Noted(b, 20, 30, vb));   // noted where it is
            int right = Forms.SystemInformation.VirtualScreen.Right;
            Pix.Away(trip);
            for (int i = 0; i < 20 && at.X < right; i++) { Forms.Application.DoEvents(); Thread.Sleep(50); at = Pix.Visible(b.Handle); }
            Rectangle away = at;
            int found = Pix.Rescue();   // as if the program had ended there: found at its next start, and onto a screen
            for (int i = 0; i < 20 && at.X >= right; i++) { Forms.Application.DoEvents(); Thread.Sleep(50); at = Pix.Visible(b.Handle); }
            Rectangle rescued = at;
            Pix.Home(trip);
            for (int i = 0; i < 20 && at != vb; i++) { Forms.Application.DoEvents(); Thread.Sleep(50); at = Pix.Visible(b.Handle); }
            Line("at the unlock out of sight, then in its place again", away.X > right && away.Size == vb.Size && at == vb,
                "away at " + away.X + "," + away.Y + ", back at " + at.X + "," + at.Y + ", noted " + vb.X + "," + vb.Y);
            Line("one left out of sight is brought back at the start", found >= 1 && rescued.Right <= right && rescued.Size == vb.Size, "found " + found + ", now at " + rescued.X + "," + rescued.Y);
            wa.W = va.Width - 40; wa.Hgt = va.Height - 30;   // as if Windows had resized it on another screen: it is asked for the noted size
            Pix.CaptureWindows(note, shot); Forms.Application.DoEvents();
            Rectangle now = Pix.Visible(a.Handle);
            Line("a window of another size is given back its size", now.Width == wa.W && now.Height == wa.Hgt, "now " + now.Width + "x" + now.Height + ", asked " + wa.W + "x" + wa.Hgt);
            wa.W = 200; wa.Hgt = 300; wa.Asked = 3;   // one that will not take its size: fitted into its place, proportions kept
            drawn = Pix.CaptureWindows(note, shot);
            Color fit = shot.Gdi.GetPixel(200, 215), outside = shot.Gdi.GetPixel(200, 60);
            Line("a window of another size is fitted into its place", drawn == 1 && Near(fit, 200, 100, 50) && Near(outside, 0, 0, 0), "inside " + Rgb(fit) + ", outside " + Rgb(outside));
            Pix.Place(wa); Rectangle was = Pix.Visible(a.Handle);
            a.SetBounds(300, 250, 200, 150); Forms.Application.DoEvents();   // as if Windows had moved it to another screen
            bool asked = Pix.Restore(wa, false); Rectangle back = Pix.Visible(a.Handle);
            for (int i = 0; i < 20 && back != was; i++) { Forms.Application.DoEvents(); Thread.Sleep(50); back = Pix.Visible(a.Handle); }
            Line("a window moved away is put back in its place", asked && back == was, "now " + back.X + "," + back.Y + " " + back.Width + "x" + back.Height + ", was " + was.X + "," + was.Y + " " + was.Width + "x" + was.Height);
            ShowWindow(a.Handle, 3); Forms.Application.DoEvents(); Pix.Place(wa);   // noted maximized
            Rectangle maxed = a.Bounds;
            ShowWindow(a.Handle, 4); Forms.Application.DoEvents(); a.Bounds = maxed;   // un-maximized during a lock, and in its place at the unlock, not maximized
            int detour = 0; EventHandler sized = (o, e) => { if (a.Width < maxed.Width) detour++; }; a.SizeChanged += sized;
            asked = Pix.Restore(wa, true);
            for (int i = 0; i < 20 && a.WindowState != Forms.FormWindowState.Maximized; i++) { Forms.Application.DoEvents(); Thread.Sleep(50); }
            a.SizeChanged -= sized;
            Pix.Win rec = Noted(a, 0, 0, maxed); Pix.Place(rec);   // Windows' record: un-maximized later, it goes to its own smaller place
            Line("a maximized window is maximized again, directly", asked && a.WindowState == Forms.FormWindowState.Maximized && detour == 0 && rec.place.normal.Is(wa.place.normal),
                a.WindowState + ", smaller on the way " + detour + " time(s), un-maximized place " + rec.place.normal.l + "," + rec.place.normal.t + " to " + rec.place.normal.r + "," + rec.place.normal.b);
            Pix.Snap z = new Pix.Snap(); z.Wins.Add(Noted(b, 0, 0, vb)); z.Wins.Add(wa);   // noted with the small window on top
            bool raised = Above(a.Handle, b.Handle);
            Pix.Restack(z); Forms.Application.DoEvents();
            Line("windows are stacked as they were again", Above(b.Handle, a.Handle), "the maximized one on top before: " + raised);
            b.TopMost = true; Pix.Restack(z); Forms.Application.DoEvents();   // below an always-on-top one: it must not become one
            Line("an ordinary window is not made always-on-top", (Pix.GetWindowLong(a.Handle, -20) & 8) == 0, "");
            b.TopMost = false;
            a.Close(); b.Close();
            Line("a closed window is left out", Pix.CaptureWindows(note, shot) == 0, "");
        }
        using (Forms.Form c = TestWindow(0, 0, 640, 400, Green, false)) {   // borderless, like a full-screen browser
            Settle(c);
            Rectangle vc = Pix.Visible(c.Handle);
            using (Frame shot = new Frame(vc.Width, vc.Height)) {
                Pix.Snap note = new Pix.Snap(); note.W = vc.Width; note.H = vc.Height; note.Wins.Add(Noted(c, 0, 0, vc));
                Pix.Notice(shot, "under the window");   // something in the picture already: the window must cover all of it
                int drawn = Pix.CaptureWindows(note, shot);
                Color p1 = shot.Gdi.GetPixel(2, 2), p2 = shot.Gdi.GetPixel(vc.Width - 3, vc.Height - 3);
                Line("a window over the whole picture fills it", drawn == 1 && Near(p1, 30, 160, 60) && Near(p2, 30, 160, 60), "corners " + Rgb(p1) + " / " + Rgb(p2));
            }
        }
        Pix.Snap s = Pix.Snapshot(null);
        Console.WriteLine("screen that would be kept".PadRight(52) + ": " + (s == null ? "none: the desktop has a single screen" : s.Device + " " + s.W + "x" + s.H + ", " + s.Wins.Count + " window(s) on it now"));
        Console.WriteLine("held by the helper now / PC locked".PadRight(52) + ": " + (Common.Taken() ?? "nothing") + " / " + Common.Locked());
        Console.WriteLine(failed == 0 ? "All checks passed." : failed + " check(s) FAILED.");
        return failed == 0 ? 0 : 1;
    }
}
