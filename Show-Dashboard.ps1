<#
Keeps a live picture on ONE monitor while the PC is locked. That monitor is one Windows has taken off the desktop
("specialized display"), so the lock never covers it. Winlogon, LogonUI and the sign-in path are not modified; the
monitors that are still on the desktop get the genuine lock screen as always. The monitor shows pictures only: it has
no cursor, no focus and no input.

Two ways to use it.
A) Automatic (Install-Auto.ps1, one-time setup): all your screens stay normal desktop screens. At Win+L the
   highest-numbered one is taken off the desktop and this script (-Auto, already waiting in the background) redraws on
   it, live, the windows that were on it; at unlock the screen and its windows return. You only press Win+L.
   It is always the same monitor: if that one is off or unplugged at Win+L, nothing stays on (see Install-Auto.ps1).
B) A permanently dedicated monitor, started by hand or at logon, showing one of:

What it shows (B):
  -Window <text>  a live copy of an existing window whose title contains <text>: any app. The window stays where it is
                  on your desktop, may be covered, must not be minimized. The app must keep drawing while locked:
                  classic apps do; Chrome/Edge pause themselves unless started with
                  --disable-backgrounding-occluded-windows (measured in the test VM: frozen without, live with).
  -Url <page>     the page in a Chrome of its own (private pipe, no TCP port, separate profile), started so that it
                  keeps drawing while locked. Hidden by default; -ShowBrowser makes it a normal window you can
                  browse in, and whatever its tab shows is what the monitor shows.
  -Pattern        a clock and counter, for testing.

One-time setup for B, per monitor: Settings > System > Display > Advanced display > pick the monitor >
"Remove display from desktop" On (administrator). Undo: same switch Off. Windows refuses it for the last desktop monitor.
(A flips that same switch by itself at lock and unlock.)
Needs Windows 10 2004+ / 11 Enterprise, Pro for Workstations or IoT Enterprise, and a current (WDDM 2.x) display driver.

Win+L is not intercepted: the genuine lock runs. Power: Windows has one display-power switch for the whole PC, and it
blanks the displays 60 s after locking. This script therefore holds a "keep displays on" request, so the picture stays;
the other monitors then stay lit too, showing the lock screen. -LetDisplaysSleep drops the request (try it: if your
picture survives Windows blanking the displays, the other monitors can sleep). The PC is kept from sleeping either way.

Measured in a test VM (vmtest\, real Win+L key presses, real password unlock): while locked, Windows keeps handing a
user-session program fresh pictures of ordinary windows; the display request holds through the lock; taking ownership
of the monitor works unelevated; and the whole of A runs by itself: screen freed a second after Win+L, live redraw of
its windows in place, screen and windows back after unlock. NOT measured anywhere yet: the final scan-out on a real GPU
with a second monitor (the VM's virtual GPU is too old a driver model, so there the pictures were written to files).

  .\Show-Dashboard.ps1 -Info                       read-only: monitors, which are off the desktop, is the feature available
  .\Show-Dashboard.ps1 -SelfTest                   GPU, window capture and Chrome checks; takes no monitor
  .\Show-Dashboard.ps1 -Pattern -Seconds 300       clock on the dedicated monitor: the Win+L test
  .\Show-Dashboard.ps1 -Window Grafana             mirror that window until stopped
  .\Show-Dashboard.ps1 -Url 'http://grafana:3000/d/<uid>/<slug>?kiosk&refresh=10s' [-ShowBrowser]
  ... -Install                                     optional: also start it at every logon (a scheduled task; nothing is
                                                   installed into Windows). Remove: Unregister-ScheduledTask LockMonitor-Dashboard
Only monitors that are off the desktop are ever taken; a normal monitor is never touched.
#>
[CmdletBinding()]
param(
    [string]$Window,      # mirror an existing window: any part of its title, e.g. 'Grafana'
    [string]$Url,         # or: show this page in a hidden Chrome of its own
    [switch]$ShowBrowser, # with -Url: make that Chrome a normal visible window you can browse in; whatever its tab shows is mirrored
    [switch]$Auto,        # background mode set up by Install-Auto.ps1: at Win+L, keep showing what is on the highest-numbered screen
    [string]$FramesTo,    # test only: write the pictures to this folder instead of the monitor (for GPUs that cannot scan out)
    [switch]$Info, [switch]$SelfTest, [switch]$Pattern, [switch]$Install,
    [switch]$LetDisplaysSleep,   # do not hold the displays on (see header): only if the dashboard survives Windows' display-off
    [string]$Monitor,     # StableMonitorId from -Info, when more than one specialized display is connected
    [string]$Chrome,
    [int]$Seconds = 0     # 0 = run until stopped; a positive value also disables the retry loop (for tests)
)
$ErrorActionPreference = 'Stop'
$dir = "$env:LOCALAPPDATA\LockMonitor"
$null = New-Item -ItemType Directory -Force $dir
function Log($m) {
    $f = "$dir\log.txt"
    if ((Test-Path $f) -and (Get-Item $f).Length -gt 1MB) { Set-Content $f (Get-Content $f -Tail 500) }   # this runs for months: keep the log small
    Add-Content $f ('{0:s} dashboard: {1}' -f (Get-Date), $m)
}

if ($Install) {   # optional convenience: start by itself at logon. Nothing is installed into Windows; without it, run the script by hand.
    if (-not $Url -and -not $Window) { throw '-Window or -Url is required with -Install.' }
    Copy-Item $PSCommandPath $dir -Force   # the task runs this private copy, not a folder other users may write to
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $what = if ($Window) { "-Window `"$Window`"" } else { "-Url `"$Url`"$(if ($ShowBrowser) { ' -ShowBrowser' })" }
    # through "conhost --headless": where Windows Terminal is the console host, -WindowStyle Hidden alone leaves a terminal window open (measured).
    # Full paths: a task that is stored and started at every logon must not depend on the search path.
    $sys = [Environment]::GetFolderPath('System')
    $act = New-ScheduledTaskAction -Execute "`"$sys\conhost.exe`"" -Argument "--headless `"$sys\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dir\Show-Dashboard.ps1`" $what$(if ($LetDisplaysSleep) { ' -LetDisplaysSleep' })"
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 99 -RestartInterval (New-TimeSpan -Minutes 1)
    $who = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited   # normal token, in the user's session
    Register-ScheduledTask LockMonitor-Dashboard -Force -Action $act -Trigger (New-ScheduledTaskTrigger -AtLogOn -User $me) -Principal $who -Settings $set | Out-Null
    'Registered LockMonitor-Dashboard (starts at logon). Start it now: Start-ScheduledTask LockMonitor-Dashboard. Log: {0}\log.txt' -f $dir
    return
}

Add-Type -ReferencedAssemblies System.Drawing, System.Web.Extensions -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using Microsoft.Win32;

// windows.devices.display.core.interop.h: derives from IUnknown (not IInspectable), so CreateSharedHandle is slot 3.
[ComImport, Guid("64338358-366A-471B-BD56-DD8EF48E439B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IDisplayDeviceInterop {
    [PreserveSig] int CreateSharedHandle([MarshalAs(UnmanagedType.IUnknown)] object o, IntPtr sa, uint access, IntPtr name, out IntPtr handle);
    [PreserveSig] int OpenSharedHandle(IntPtr h, ref Guid riid, [MarshalAs(UnmanagedType.IUnknown)] out object o);
}

public static class Spec {   // DisplayConfigGetDeviceInfo(GET_MONITOR_SPECIALIZATION = 12): read-only
    [StructLayout(LayoutKind.Sequential)] struct Req { public int type, size; public uint lo; public int hi; public uint id, flags; }
    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref Req r);
    public static string Get(uint lo, int hi, uint id) {
        Req r = new Req(); r.type = 12; r.size = Marshal.SizeOf(typeof(Req)); r.lo = lo; r.hi = hi; r.id = id;
        int rc = DisplayConfigGetDeviceInfo(ref r);
        if (rc != 0) return "unknown (error " + rc + ")";
        return "enabled=" + (r.flags & 1) + " availableForMonitor=" + ((r.flags >> 1) & 1) + " availableForSystem=" + ((r.flags >> 2) & 1);
    }
    public static bool Off(uint lo, int hi, uint id) {   // true when that monitor is connected and off the desktop
        Req r = new Req(); r.type = 12; r.size = Marshal.SizeOf(typeof(Req)); r.lo = lo; r.hi = hi; r.id = id;
        return DisplayConfigGetDeviceInfo(ref r) == 0 && (r.flags & 1) != 0;
    }
}

public static class Pwr {   // ES_CONTINUOUS 0x80000000 | ES_SYSTEM_REQUIRED 1 | ES_DISPLAY_REQUIRED 2; held only while the calling thread lives
    [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint f);
    public static bool Keep(bool system, bool display) { return SetThreadExecutionState(0x80000000u | (system ? 1u : 0u) | (display ? 2u : 0u)) != 0; }   // 0 = Windows refused
}

// One picture, kept as a plain Windows bitmap (DIB section): window pictures are copied into it by Windows' own
// bitmap routines and the GPU reads it from there, with no conversions in between. Gdi is a System.Drawing view of
// the same memory, for text and JPEG drawing.
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
    // ---- the session: locked or not, and the screen the elevated helper holds ----
    [DllImport("wtsapi32.dll")] static extern bool WTSQuerySessionInformation(IntPtr server, int session, int infoClass, out IntPtr buf, out int bytes);
    [DllImport("wtsapi32.dll")] static extern void WTSFreeMemory(IntPtr p);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("psapi.dll")] static extern bool EmptyWorkingSet(IntPtr process);
    // Windows' own lock flag: WTSSessionInfoEx (25), SessionFlags at offset 16, 0 = locked, 1 = unlocked. Whether the input
    // desktop can be opened is no test: Windows draws the lock-screen picture on the user's own desktop (measured in the test VM).
    static int Flags() { IntPtr p; int n; if (!WTSQuerySessionInformation(IntPtr.Zero, -1, 25, out p, out n)) return -1; int f = Marshal.ReadInt32(p, 16); WTSFreeMemory(p); return f; }
    // Both are definite answers: when Windows cannot say (the query fails, or the flag is neither), the PC counts as
    // neither locked nor unlocked, and whoever asks carries on as before.
    public static bool Locked() { return Flags() == 0; }
    public static bool Unlocked() { return Flags() == 1; }
    public static string SessionState() { int f = Flags(); return f == 0 ? "LOCKED" : f == 1 ? "unlocked" : "unknown"; }

    [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize, dwTime; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO i);
    // Seconds since keyboard or mouse were last used. It also counts input made on the lock screen (measured in the test
    // VM), so at an unlock it tells a typed password or PIN from a sign-in without typing (face, fingerprint).
    public static double IdleSeconds() {
        LASTINPUTINFO i = new LASTINPUTINFO(); i.cbSize = 8;
        return GetLastInputInfo(ref i) ? unchecked((uint)Environment.TickCount - i.dwTime) / 1000.0 : 0;
    }

    // The screen Switch-LastScreen.exe holds off the desktop right now, as "adapterLow|adapterHigh|target|device|monitor path"; null if none.
    public static string Taken() {
        using (RegistryKey hklm = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64))
        using (RegistryKey k = hklm.OpenSubKey(@"SOFTWARE\LockMonitor")) { return k == null ? null : k.GetValue("Taken") as string; }
    }

    // ---- windows: finding them and getting their live picture. Read-only: nothing is ever sent to a window. ----
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
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int size);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int v, int size);
    [DllImport("gdi32.dll")] static extern bool BitBlt(IntPtr dst, int x, int y, int w, int h, IntPtr src, int sx, int sy, uint rop);
    [DllImport("gdi32.dll")] static extern int SetStretchBltMode(IntPtr dc, int mode);
    [DllImport("gdi32.dll")] static extern bool SetBrushOrgEx(IntPtr dc, int x, int y, IntPtr prev);
    [DllImport("gdi32.dll")] static extern bool StretchBlt(IntPtr dst, int x, int y, int w, int h, IntPtr src, int sx, int sy, int sw, int sh, uint rop);
    [DllImport("gdi32.dll")] static extern bool GdiFlush();

    public static void ShowNoActivate(IntPtr h) { ShowWindow(h, 4); }
    // sizes and pictures in real pixels on every screen, whatever its scaling (-4 = per-monitor aware v2; older Windows lacks it)
    public static void DpiAware() { try { SetThreadDpiAwarenessContext(new IntPtr(-4)); } catch (EntryPointNotFoundException) { } }

    public static IntPtr FindWindow(string titlePart) {   // first visible top-level window whose title contains the text
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, p) => {
            if (!IsWindowVisible(h)) return true;
            StringBuilder s = new StringBuilder(512); GetWindowText(h, s, 512);
            if (s.ToString().IndexOf(titlePart, StringComparison.OrdinalIgnoreCase) < 0) return true;
            found = h; return false;
        }, IntPtr.Zero);
        return found;
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
    // 2 = PW_RENDERFULLCONTENT: the picture comes from the window compositor, so GPU-drawn apps (Chrome, Electron) work and
    // the window may be covered by others. Measured in the test VM: it keeps delivering fresh pictures while locked.
    // Measured too: it always draws the whole window at the top-left corner of the bitmap, ignoring the DC's origin and
    // clipping. Hence the detour through a bitmap of its own, from which the visible part is copied into place.
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
        return StretchBlt(dst.Dc, x + (w - tw) / 2, y + (h - th) / 2, tw, th, scratch.Dc, fx, fy, fw, fh, 0x00CC0020);   // SRCCOPY
    }

    // -Window: the whole picture is one window, fitted. "ok", or why not: "gone", "minimized" (Windows stops drawing those), "failed"
    public static string CaptureWindow(IntPtr hwnd, Frame dst) {
        if (!IsWindow(hwnd)) return "gone";
        if (IsIconic(hwnd)) return "minimized";
        dst.Clear();
        bool ok = Blit(hwnd, dst, 0, 0, dst.W, dst.H);
        GdiFlush();
        return ok ? "ok" : "failed";
    }

    // ---- automatic mode (-Auto): note what is on the highest-numbered screen, later redraw it from live window pictures ----
    public class Win { public IntPtr H; public int X, Y, W, Hgt; public string Title; }
    public class Snap { public string Device; public int W, H; public List<Win> Wins = new List<Win>(); }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct MONITORINFOEX { public int cbSize; public RECT mon, work; public uint flags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string device; }
    delegate bool MonProc(IntPtr hm, IntPtr dc, IntPtr rc, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, MonProc cb, IntPtr data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr hm, ref MONITORINFOEX mi);

    // The highest-numbered screen of the desktop (\\.\DISPLAYn) and the app windows on it, top-most first.
    // null when the desktop has a single screen: there is nothing to keep then.
    public static Snap Snapshot() {
        IntPtr best = IntPtr.Zero; int bestN = -1, count = 0; MONITORINFOEX bm = new MONITORINFOEX();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (hm, dc, rc, d) => {
            MONITORINFOEX mi = new MONITORINFOEX(); mi.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
            if (!GetMonitorInfo(hm, ref mi)) return true;
            count++;
            int p = mi.device.Length; while (p > 0 && char.IsDigit(mi.device[p - 1])) p--;
            int n; if (int.TryParse(mi.device.Substring(p), out n) && n > bestN) { bestN = n; best = hm; bm = mi; }
            return true;
        }, IntPtr.Zero);
        if (best == IntPtr.Zero || count < 2) return null;
        Snap s = new Snap(); s.Device = bm.device; s.W = bm.mon.r - bm.mon.l; s.H = bm.mon.b - bm.mon.t;
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

    static Snap noted, latest;
    // Sleeps while the PC is unlocked, noting every 0.7 s what is on the last screen, and returns the note when the PC
    // gets locked: the note from one round earlier, because the newest one may already contain the lock screen.
    // Nothing is noted while the helper still holds a screen off the desktop (the "last" screen would be the wrong one).
    // null when timeoutMs (0 = none) passes first.
    public static Snap WaitForLock(int timeoutMs) {
        GC.Collect(); EmptyWorkingSet(GetCurrentProcess());   // this wait lasts hours: hand back the memory the last lock used
        Stopwatch sw = Stopwatch.StartNew(); int kept = 0;
        while (!Locked()) {
            if (timeoutMs > 0 && sw.ElapsedMilliseconds >= timeoutMs) return null;
            string held = Taken();
            if (held == null) { kept = 0; noted = latest; latest = Snapshot(); }
            else if (++kept >= 8 && Unlocked() && AskToGiveBack(held)) kept = -7;   // asked: allow 10 s before asking again
            Thread.Sleep(700);
        }
        return noted ?? latest ?? new Snap();
    }

    // The PC has been unlocked for 5 s and the helper still holds the screen: it was unplugged or switched off at the
    // moment of unlocking, so it could not be put back, and Windows remembers "off the desktop" for it (measured in
    // the test VM: it would stay unused until the next unlock). Once it is connected again, ask Windows to run the
    // give-back task; this program has no rights to do that itself. true when asked.
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

    // Sleeps ms, but returns false at once when the PC has been unlocked: the screen must go back without delay.
    public static bool SleepWhileLocked(int ms) {
        for (int left = ms; ; left -= 100) {
            if (Unlocked()) return false;
            if (left <= 0) return true;
            Thread.Sleep(Math.Min(100, left));
        }
    }

    // ---- other picture sources ----
    public static void Decode(byte[] jpeg, Frame dst) {
        using (MemoryStream ms = new MemoryStream(jpeg))
        using (Image img = Image.FromStream(ms, false, false))   // no colour management, no validation pass
        using (Graphics g = Graphics.FromImage(dst.Gdi)) {
            g.CompositingMode = CompositingMode.SourceCopy; g.PixelOffsetMode = PixelOffsetMode.Half;
            g.InterpolationMode = (img.Width == dst.W && img.Height == dst.H) ? InterpolationMode.NearestNeighbor : InterpolationMode.HighQualityBilinear;   // same size (the usual case): a plain copy
            g.DrawImage(img, new Rectangle(0, 0, dst.W, dst.H), 0, 0, img.Width, img.Height, GraphicsUnit.Pixel);
        }
    }
    public static void Notice(Frame b, string text) {
        using (Graphics g = Graphics.FromImage(b.Gdi))
        using (Font f = new Font("Segoe UI", b.H / 28f, GraphicsUnit.Pixel))
        using (Brush w = new SolidBrush(Color.FromArgb(200, 200, 200))) {
            g.Clear(Color.FromArgb(16, 24, 40));
            g.DrawString(text + "\n" + DateTime.Now.ToString("HH:mm:ss"), f, w, 40, 40);
        }
    }
    public static void Pattern(Frame b, long n, string state) {
        using (Graphics g = Graphics.FromImage(b.Gdi)) {
            g.Clear(Color.FromArgb(16, 24, 40));
            using (Font big = new Font("Segoe UI", b.H / 8f, FontStyle.Bold, GraphicsUnit.Pixel))
            using (Font small = new Font("Segoe UI", b.H / 24f, GraphicsUnit.Pixel))
            using (Brush w = new SolidBrush(Color.White))
            using (Brush c = new SolidBrush(Color.FromArgb(80, 200, 120))) {
                g.DrawString(DateTime.Now.ToString("HH:mm:ss"), big, w, 40, 40);
                g.DrawString("frame " + n + "    session: " + state, small, c, 44, b.H / 8f + 80);
                g.FillRectangle(c, (int)((n * 12) % b.W), b.H - 60, 60, 20);   // moving bar: stops if updates stop
            }
        }
    }
}

// D3D11 on the adapter that owns the display target. COM is called through raw vtable slots (no SDK, no NuGet); SelfTest() exercises every slot used.
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
            if (ms > 2000) throw new TimeoutException("GPU did not finish the upload");
            if (ms < 5) Thread.Yield(); else Thread.Sleep(1);   // it takes a millisecond or two: do not sleep a whole 15 ms timer tick for that
        }
    }
    public void Upload(IntPtr tex, Bitmap bmp) {
        BitmapData bd = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try { Upload(tex, bd.Scan0, bd.Stride); } finally { bmp.UnlockBits(bd); }
    }

    // texture shared by NT handle (as a DisplaySurface is) -> upload two known pixels -> read back through a staging texture
    public string SelfTest() {
        TexDesc d = new TexDesc(); d.W = 64; d.H = 32; d.Mips = 1; d.ArraySize = 1; d.Format = 87; d.SampCount = 1; d.Bind = 0x20; d.Misc = 0x2 | 0x800;
        IntPtr tex, res1, h;
        Check(createTex(dev, ref d, IntPtr.Zero, out tex), "CreateTexture2D");
        Guid iidRes1 = new Guid("30961379-4609-4a41-998e-54fe567ee0c1");
        Check(Slot<FnQI>(tex, 0)(tex, ref iidRes1, out res1), "IDXGIResource1");
        Check(Slot<FnShare>(res1, 13)(res1, IntPtr.Zero, 0x80000001, IntPtr.Zero, out h), "IDXGIResource1.CreateSharedHandle");
        IntPtr opened = OpenHandle(h); CloseHandle(h);
        using (Bitmap b = new Bitmap(64, 32, PixelFormat.Format32bppArgb)) {
            using (Graphics g = Graphics.FromImage(b)) g.Clear(Color.FromArgb(255, 10, 20, 30));
            b.SetPixel(5, 7, Color.FromArgb(255, 200, 100, 50));
            Upload(opened, b);
        }
        int p0 = ReadPixel(opened, 0, 0), p1 = ReadPixel(opened, 5, 7);
        Release(opened); Release(res1); Release(tex);
        bool ok = p0 == unchecked((int)0xFF0A141E) && p1 == unchecked((int)0xFFC86432);
        return (ok ? "OK" : "FAILED") + " (pixels 0x" + p0.ToString("X8") + " / 0x" + p1.ToString("X8") + ")";
    }

    // What kind of texture this is (ID3D11Texture2D::GetDesc, slot 10): for the log, when a display surface misbehaves.
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

// Headless Chrome on a private pipe (--remote-debugging-pipe): no TCP listener for other local accounts to reach.
public class Cdp : IDisposable {
    readonly Process proc;
    readonly AnonymousPipeServerStream toChrome, fromChrome;
    readonly object gate = new object(), wlock = new object();
    readonly Dictionary<int, Dictionary<string, object>> replies = new Dictionary<int, Dictionary<string, object>>();
    readonly Dictionary<int, bool> waiting = new Dictionary<int, bool>();
    readonly JavaScriptSerializer json = new JavaScriptSerializer();
    readonly List<string> unacked = new List<string>();
    byte[] latest; bool dead; int nextId; string session; long frames;
    public string LastError;
    public long Frames { get { lock (gate) { return frames; } } }
    public int ProcessId { get { return proc.Id; } }

    public Cdp(string chrome, string profile, string url, int w, int h, bool show) {   // show = a normal visible Chrome window instead of headless
        json.MaxJsonLength = int.MaxValue;
        toChrome = new AnonymousPipeServerStream(PipeDirection.Out, HandleInheritability.Inheritable);
        fromChrome = new AnonymousPipeServerStream(PipeDirection.In, HandleInheritability.Inheritable);
        string args = (show ? "" : "--headless=new ") + "--remote-debugging-pipe --remote-debugging-io-pipes=" + toChrome.GetClientHandleAsString() + "," + fromChrome.GetClientHandleAsString()
            + " --user-data-dir=\"" + profile + "\" --no-first-run --no-default-browser-check --disable-background-networking --disable-component-update --disable-sync --mute-audio --hide-scrollbars"
            + " --disable-renderer-backgrounding --disable-background-timer-throttling --disable-backgrounding-occluded-windows --force-device-scale-factor=1 --window-size=" + w + "," + h + " about:blank";
        ProcessStartInfo psi = new ProcessStartInfo(chrome, args);
        psi.UseShellExecute = false; psi.CreateNoWindow = true;
        proc = Process.Start(psi);
        toChrome.DisposeLocalCopyOfClientHandle(); fromChrome.DisposeLocalCopyOfClientHandle();
        Thread t = new Thread(ReadLoop); t.IsBackground = true; t.Start();
        try {
            string target = (string)Result(Call("Target.createTarget", "{\"url\":\"about:blank\"}", false))["targetId"];
            session = (string)Result(Call("Target.attachToTarget", "{\"targetId\":\"" + target + "\",\"flatten\":true}", false))["sessionId"];
            Call("Page.enable", "{}", true);
            Call("Emulation.setDeviceMetricsOverride", "{\"width\":" + w + ",\"height\":" + h + ",\"deviceScaleFactor\":1,\"mobile\":false}", true);
            Call("Page.startScreencast", "{\"format\":\"jpeg\",\"quality\":85,\"maxWidth\":" + w + ",\"maxHeight\":" + h + ",\"everyNthFrame\":1}", true);
            Call("Page.navigate", "{\"url\":" + json.Serialize(url) + "}", true);
        } catch { Dispose(); throw; }
    }

    static Dictionary<string, object> Result(Dictionary<string, object> reply) { return (Dictionary<string, object>)reply["result"]; }

    void Send(int id, string method, string prm, bool inSession) {
        string msg = "{\"id\":" + id + ",\"method\":\"" + method + "\",\"params\":" + prm + (inSession ? ",\"sessionId\":\"" + session + "\"" : "") + "}";
        byte[] b = Encoding.UTF8.GetBytes(msg + "\0");
        lock (wlock) { toChrome.Write(b, 0, b.Length); toChrome.Flush(); }
    }

    Dictionary<string, object> Call(string method, string prm, bool inSession) {
        int id = Interlocked.Increment(ref nextId);
        lock (gate) { waiting[id] = true; }   // registered before sending: fire-and-forget replies (frame acks) are dropped, not collected
        Send(id, method, prm, inSession);
        lock (gate) {
            DateTime until = DateTime.UtcNow.AddSeconds(20);
            while (!replies.ContainsKey(id)) {
                if (dead) throw new InvalidOperationException("Chrome closed the DevTools pipe during " + method + " (does this Chrome build support --remote-debugging-io-pipes?)");
                double left = (until - DateTime.UtcNow).TotalMilliseconds;
                if (left <= 0) throw new TimeoutException("Chrome did not answer " + method);
                Monitor.Wait(gate, (int)left);
            }
            Dictionary<string, object> r = replies[id]; replies.Remove(id); waiting.Remove(id);
            if (r.ContainsKey("error")) throw new InvalidOperationException(method + ": " + json.Serialize(r["error"]));
            return r;
        }
    }

    void ReadLoop() {
        try {
            MemoryStream ms = new MemoryStream(); byte[] buf = new byte[65536]; int n;
            while ((n = fromChrome.Read(buf, 0, buf.Length)) > 0) {
                int start = 0;
                while (start < n) {
                    int z = Array.IndexOf(buf, (byte)0, start, n - start);
                    if (z < 0) { ms.Write(buf, start, n - start); break; }
                    ms.Write(buf, start, z - start);
                    string msg = Encoding.UTF8.GetString(ms.GetBuffer(), 0, (int)ms.Length); ms.SetLength(0);
                    try { Handle(msg); } catch (Exception e) { LastError = e.Message; }   // one bad message must not kill the stream
                    start = z + 1;
                }
            }
        } catch (Exception) { }
        lock (gate) { dead = true; Monitor.PulseAll(gate); }
    }

    void Handle(string msg) {
        Dictionary<string, object> m = (Dictionary<string, object>)json.DeserializeObject(msg);
        object id;
        if (m.TryGetValue("id", out id)) { lock (gate) { int k = Convert.ToInt32(id); if (waiting.ContainsKey(k)) { replies[k] = m; Monitor.PulseAll(gate); } } return; }
        object method;
        if (!m.TryGetValue("method", out method) || (string)method != "Page.screencastFrame") return;
        Dictionary<string, object> p = (Dictionary<string, object>)m["params"];
        byte[] jpg = Convert.FromBase64String((string)p["data"]);
        lock (gate) { latest = jpg; unacked.Add(p["sessionId"].ToString()); frames++; Monitor.PulseAll(gate); }
    }

    // Newest frame, or null after timeoutMs without one (page unchanged); throws when Chrome is gone.
    // Chrome holds further frames back until the ones it sent are acknowledged, and that happens here, when a frame is
    // taken: a page that animates 60 times a second is therefore encoded and parsed only about as fast as the monitor
    // loop shows it. Every frame received is acknowledged, also the ones a newer one replaced: Chrome counts them.
    public byte[] NextJpeg(int timeoutMs) {
        byte[] j; string[] acks;
        lock (gate) {
            if (latest == null && !dead) Monitor.Wait(gate, timeoutMs);
            if (dead || proc.HasExited) throw new InvalidOperationException("Chrome exited");
            j = latest; latest = null; acks = unacked.ToArray(); unacked.Clear();
        }
        foreach (string a in acks) Send(Interlocked.Increment(ref nextId), "Page.screencastFrameAck", "{\"sessionId\":" + a + "}", true);
        return j;
    }

    public void Dispose() {
        try {
            if (!proc.HasExited) {
                ProcessStartInfo k = new ProcessStartInfo("taskkill", "/PID " + proc.Id + " /T /F"); k.CreateNoWindow = true; k.UseShellExecute = false;
                Process.Start(k).WaitForExit(5000);
            }
        } catch (Exception) { }
        try { toChrome.Dispose(); fromChrome.Dispose(); } catch (Exception) { }
    }
}
'@

$null = [Windows.Devices.Display.Core.DisplayManager, Windows.Devices.Display.Core, ContentType=WindowsRuntime]
$null = [Windows.Devices.Display.DisplayMonitor, Windows.Devices.Display, ContentType=WindowsRuntime]
$null = [Windows.Graphics.DirectX.DirectXColorSpace, Windows.Graphics.DirectX, ContentType=WindowsRuntime]
$null = [Windows.Graphics.DirectX.Direct3D11.Direct3DMultisampleDescription, Windows.Graphics.DirectX.Direct3D11, ContentType=WindowsRuntime]

if (-not $Chrome) {
    $Chrome = "$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe", "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe" |
        Where-Object { Test-Path $_ } | Select-Object -First 1
}

function Stop-OurChrome($profile) {   # an earlier run that died hard can leave headless Chrome holding the profile
    Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -like "*$profile*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Select-Mode($modes) {   # largest resolution, then the rate closest to 60 Hz; an unspecified rate (denominator 0) sorts last instead of throwing
    $modes | Sort-Object @{ Expression = { -($_.SourceResolution.Width * $_.SourceResolution.Height) } },
        @{ Expression = { $v = $_.PresentationRate.VerticalSyncRate; if ($v.Denominator) { [math]::Abs($v.Numerator / $v.Denominator - 60) } else { [double]::MaxValue } } } | Select-Object -First 1
}

if ($Info) {
    $dm = [Windows.Devices.Display.Core.DisplayManager]::Create('None')
    $spec = 0
    foreach ($t in $dm.GetCurrentTargets() | Where-Object IsConnected) {
        $m = $t.TryGetMonitor()
        '{0,-12} {1,-14} id={2}  luid={3}:{4}  specialization: {5}' -f $t.UsageKind, $m.DisplayName, $t.StableMonitorId, $t.Adapter.Id.HighPart, $t.Adapter.Id.LowPart,
            [Spec]::Get($t.Adapter.Id.LowPart, $t.Adapter.Id.HighPart, $t.AdapterRelativeId)
        if ($t.UsageKind -ne 'Standard') { $spec++ }
    }
    $dm.Dispose()
    if ($spec) { "READY: $spec specialized display(s). Run -Pattern, then -Window or -Url." }
    else { 'NOT READY: no connected specialized display. Settings > System > Display > Advanced display > pick the monitor > "Remove display from desktop" On (needs availableForMonitor=1 availableForSystem=1 above).' }
    return
}

if ($SelfTest) {
    function Near($c, $r, $g, $b) { [math]::Abs($c.R - $r) -le 3 -and [math]::Abs($c.G - $g) -le 3 -and [math]::Abs($c.B - $b) -le 3 }
    function Verdict($ok, $detail) { if ($ok) { 'OK' } else { "FAILED ($detail)" } }
    $dm = [Windows.Devices.Display.Core.DisplayManager]::Create('None')
    $t = $dm.GetCurrentTargets() | Where-Object IsConnected | Select-Object -First 1   # only for its adapter: nothing is acquired
    $g = New-Object Gfx($t.Adapter.Id.LowPart, $t.Adapter.Id.HighPart)
    'GPU           : ' + $g.AdapterName
    'D3D11 + shared texture upload/readback: ' + $g.SelfTest()
    try {   # a real DisplaySurface, allocated but not owned and never scanned out, must open as a D3D11 texture and accept a picture
        $ms = New-Object Windows.Graphics.DirectX.Direct3D11.Direct3DMultisampleDescription; $ms.Count = 1
        $desc = [Windows.Devices.Display.Core.DisplayPrimaryDescription]::new([uint32]256, [uint32]128, 'B8G8R8A8UIntNormalized', [Windows.Graphics.DirectX.DirectXColorSpace]::RgbFullG22NoneP709, $false, $ms)
        $dev = $dm.CreateDisplayDevice($t.Adapter)
        $tex = $g.OpenSurface($dev, $dev.CreatePrimary($t, $desc))
        $f = New-Object Frame(256, 128)
        $gr = [Drawing.Graphics]::FromImage($f.Gdi); $gr.Clear([Drawing.Color]::FromArgb(200, 100, 50)); $gr.Dispose()
        $g.Upload($tex, $f.Bits, $f.Stride)
        $px = $g.ReadPixel($tex, 100, 60)   # the picture must really be in the display surface, not merely have been sent
        'DisplaySurface -> D3D11 texture -> upload -> readback: ' + (Verdict (($px -band 0xFFFFFF) -eq 0xC86432) ('pixel 0x{0:X8}' -f $px)) + '   (surface: ' + $g.Describe($tex) + ')'
        [Gfx]::Free($tex); $f.Dispose()
        'not testable here: acquire/apply/scanout need an owned specialized display (first checked by -Pattern)'
    } catch { 'DisplaySurface -> D3D11 texture -> upload: FAILED ' + $_.Exception.Message.Trim() + '  => this display driver cannot scan out for this script (it takes a current WDDM 2.x driver; VMware''s virtual GPU fails here)' }
    $mk = { param($w, $h, $n, $d) [pscustomobject]@{ SourceResolution = [pscustomobject]@{ Width = $w; Height = $h }; PresentationRate = [pscustomobject]@{ VerticalSyncRate = [pscustomobject]@{ Numerator = $n; Denominator = $d } } } }
    $pick = Select-Mode @((& $mk 1920 1080 60 1), (& $mk 1920 1200 75 1), (& $mk 1920 1200 0 0), (& $mk 1920 1200 59940 1000))
    'mode selection (synthetic modes, incl. a zero rate): ' + (Verdict ($pick.SourceResolution.Height -eq 1200 -and [math]::Round($pick.PresentationRate.VerticalSyncRate.Numerator / $pick.PresentationRate.VerticalSyncRate.Denominator) -eq 60) 'wrong mode')
    $g.Dispose(); $dm.Dispose()
    'power request (keep PC + displays on): ' + $(if ([Pwr]::Keep($true, $true)) { 'accepted' } else { 'REFUSED' }); $null = [Pwr]::Keep($false, $false)

    # the picture paths, against a small window of our own in a known colour
    Add-Type -AssemblyName System.Windows.Forms
    [Pix]::DpiAware()
    $title = "LockMonitor self-test $PID"
    $form = New-Object Windows.Forms.Form -Property @{ Text = $title; Width = 320; Height = 200; StartPosition = 'Manual'; Left = 60; Top = 60; BackColor = [Drawing.Color]::FromArgb(200, 100, 50); ShowInTaskbar = $false }
    [Pix]::ShowNoActivate($form.Handle); [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 400; [Windows.Forms.Application]::DoEvents()
    $shot = New-Object Frame(640, 400)
    $st = [Pix]::CaptureWindow([Pix]::FindWindow($title), $shot); $px = $shot.Gdi.GetPixel(320, 300)
    'window mirror (find, capture, fit to the screen)   : ' + (Verdict ($st -eq 'ok' -and (Near $px 200 100 50)) "$st, pixel $($px.R),$($px.G),$($px.B)")
    $v = [Pix]::Visible($form.Handle)
    $note = New-Object Pix+Snap -Property @{ W = 640; H = 400 }
    $note.Wins.Add((New-Object Pix+Win -Property @{ H = $form.Handle; X = 100; Y = 50; W = $v.Width; Hgt = $v.Height }))
    $drawn = [Pix]::CaptureWindows($note, $shot)   # same size as noted: copied into its place pixel for pixel
    $in = $shot.Gdi.GetPixel(100 + [int]($v.Width / 2), 50 + $v.Height - 12); $left = $shot.Gdi.GetPixel(96, 50 + $v.Height - 12); $below = $shot.Gdi.GetPixel(100 + [int]($v.Width / 2), 50 + $v.Height + 4)
    'screen redraw, window unchanged in size (in place)  : ' + (Verdict ($drawn -eq 1 -and (Near $in 200 100 50) -and ($left.R + $left.G + $left.B) -eq 0 -and ($below.R + $below.G + $below.B) -eq 0) "drawn $drawn, inside $($in.R),$($in.G),$($in.B), left $($left.R),$($left.G),$($left.B), below $($below.R),$($below.G),$($below.B)")
    'unchanged picture is recognised                     : ' + (Verdict ($shot.Changed() -and [Pix]::CaptureWindows($note, $shot) -eq 1 -and -not $shot.Changed()) 'a still window looked changed')
    $note.Wins[0].W = 200; $note.Wins[0].Hgt = 300   # other size than noted (Windows resized it on another screen): fitted into its place, proportions kept
    $drawn = [Pix]::CaptureWindows($note, $shot); $in = $shot.Gdi.GetPixel(200, 215); $out = $shot.Gdi.GetPixel(200, 60)
    'screen redraw, window changed in size (fitted)      : ' + (Verdict ($drawn -eq 1 -and (Near $in 200 100 50) -and ($out.R + $out.G + $out.B) -eq 0 -and $shot.Changed()) "drawn $drawn, inside $($in.R),$($in.G),$($in.B), outside $($out.R),$($out.G),$($out.B)")
    $s = [Pix]::Snapshot()
    'highest-numbered screen                             : ' + $(if ($s) { "$($s.Device) $($s.W)x$($s.H), $($s.Wins.Count) window(s) on it" } else { 'single-screen desktop: -Auto has nothing to keep here' })
    'screen held by the helper / PC locked               : ' + $(if ([Pix]::Taken()) { [Pix]::Taken() } else { 'none' }) + ' / ' + [Pix]::Locked()
    $h = $form.Handle; $form.Close()
    'window mirror, window gone                          : ' + (Verdict ([Pix]::CaptureWindow($h, $shot) -eq 'gone' -and [Pix]::FindWindow($title) -eq [IntPtr]::Zero) 'a closed window was still found')
    $shot.Dispose()

    if (-not $Chrome) { throw 'Chrome not found; pass -Chrome.' }
    $prof = "$dir\chrome-profile-selftest"; Stop-OurChrome $prof
    $page = 'data:text/html,<body style="margin:0;background:navy"><h1 id=t style="color:white;font:120px sans-serif"></h1><script>setInterval(()=>t.textContent=performance.now().toFixed(0),50)</script>'   # no # in a data: URL, it starts the fragment
    $c = New-Object Cdp($Chrome, $prof, $page, 800, 480, $false)
    try {
        $frame = New-Object Frame(800, 480)
        $sums = @{}; $end = (Get-Date).AddSeconds(6); $lastAt = Get-Date
        while ((Get-Date) -lt $end) {   # taken at the monitor loop's pace: Chrome must neither run ahead nor stop sending
            $j = $c.NextJpeg(1000)
            if ($j) { [Pix]::Decode($j, $frame); $sums[[BitConverter]::ToString((New-Object Security.Cryptography.SHA1Managed).ComputeHash($j))] = 1; $lastAt = Get-Date; Start-Sleep -Milliseconds 80 }
        }
        $bg = $frame.Gdi.GetPixel(700, 400)
        'Chrome frames : {0} sent, {1} distinct shown in 6 s at the monitor loop''s pace (page changes every 50 ms); still coming at the end {2}; decoded picture {3} {4}' -f $c.Frames, $sums.Count,
            (Verdict (((Get-Date) - $lastAt).TotalSeconds -lt 1.5) 'the stream stalled'), (Verdict (Near $bg 0 0 128) "background $($bg.R),$($bg.G),$($bg.B)"), $c.LastError
        $pids = @($c.ProcessId) + @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -like "*$prof*" } | ForEach-Object ProcessId) | Select-Object -Unique
        'unelevated    : ' + (-not ((whoami /groups) -match 'S-1-16-12288'))
        'TCP listeners : ' + @(Get-NetTCPConnection -State Listen -OwningProcess $pids -ErrorAction SilentlyContinue).Count + ' (want 0)'
        'visible windows: ' + @(Get-Process -Id $pids -ErrorAction SilentlyContinue | Where-Object MainWindowHandle -ne 0).Count + ' (want 0)'
        $frame.Dispose()
    } finally { $c.Dispose(); Start-Sleep 1; Remove-Item $prof -Recurse -Force -ErrorAction SilentlyContinue }
    return
}

if (-not $Pattern -and -not $Url -and -not $Window -and -not $Auto) { throw 'Give -Auto, -Window <part of a window title>, -Url <page>, or -Pattern for the test pattern (see the header).' }
if ($Url -and -not $Pattern -and -not $Window -and -not $Auto -and -not $Chrome) { throw 'Chrome not found; pass -Chrome.' }
if ($Window) { [Pix]::DpiAware() }

function Run {
    # Every display object is let go of the moment the pictures stop, not whenever .NET gets round to it: the helper is
    # waiting to put the screen back on the desktop, and in -Auto this runs again at every lock for months.
    try { Show-Pictures } finally { [GC]::Collect(); [GC]::WaitForPendingFinalizers() }
}

function Show-Pictures {
    $dm = [Windows.Devices.Display.Core.DisplayManager]::Create('None')
    $cdp = $null; $gfx = $null; $frame = $null; $tex = @()
    try {
        # Whichever connected monitor Windows has taken off the desktop; in -Auto exactly the one the helper took. Standard monitors are never candidates.
        $want = if ($Auto -and $held) { $held -split '\|' }
        $t = $dm.GetCurrentTargets() | Where-Object {
            $_.IsConnected -and $_.UsageKind -ne 'Standard' -and (-not $Monitor -or $_.StableMonitorId -eq $Monitor) -and
            (-not $want -or ($_.Adapter.Id.LowPart -eq [uint32]$want[0] -and $_.Adapter.Id.HighPart -eq [int]$want[1] -and $_.AdapterRelativeId -eq [uint32]$want[2]))
        } | Select-Object -First 1
        if (-not $t) { throw 'No connected specialized display. Run -Info.' }

        $list = New-Object 'System.Collections.Generic.List[Windows.Devices.Display.Core.DisplayTarget]'; $list.Add($t)
        $r = $dm.TryAcquireTargetsAndCreateEmptyState($list)
        if ($r.ErrorCode -ne 'Success') { throw "Acquire failed: $($r.ErrorCode) $($r.ExtendedErrorCode.Message)" }
        $state = $r.State
        $path = $state.ConnectTarget($t)
        $path.IsInterlaced = $false
        $path.Scaling = 'Identity'
        $path.SourcePixelFormat = 'B8G8R8A8UIntNormalized'
        $modes = @($path.FindModes('OnlyPreferredResolution')); if (-not $modes) { $modes = @($path.FindModes('None')) }
        if ($Auto -and $noted -and $noted.W) {   # the size this screen had on the desktop, if the monitor offers it: the redraw is then pixel for pixel
            $same = @($path.FindModes('None') | Where-Object { $_.SourceResolution.Width -eq $noted.W -and $_.SourceResolution.Height -eq $noted.H })
            if ($same) { $modes = $same }
        }
        $best = Select-Mode $modes
        if (-not $best) { throw 'The display reports no usable mode for BGRA8 / identity scaling.' }
        $path.ApplyPropertiesFromMode($best)
        $a = $state.TryApply('None')
        if ($a.Status -ne 'Success') { throw "Apply failed: $($a.Status) $($a.ExtendedErrorCode.Message)" }
        $r = $dm.TryAcquireTargetsAndReadCurrentState($list)   # re-read: the state that was really applied
        if ($r.ErrorCode -ne 'Success') { throw "Re-read failed: $($r.ErrorCode) $($r.ExtendedErrorCode.Message)" }
        $path = $r.State.GetPathForTarget($t)
        $res = $path.SourceResolution; $w = [int]$res.Width; $h = [int]$res.Height

        if ($FramesTo) {   # test mode for GPUs that cannot scan out (the VM): everything as usual, but the pictures go to files
            $null = New-Item -ItemType Directory -Force $FramesTo
            Log ('acquired {0} ({1}x{2}); test mode, pictures go to {3} instead of the screen' -f $t.StableMonitorId, $w, $h, $FramesTo)
        } else {
            $dev = $dm.CreateDisplayDevice($t.Adapter)
            try { $src = $dev.CreateScanoutSource($t) }
            catch { throw "This display driver cannot scan out through Windows.Devices.Display.Core ($($_.Exception.Message.Trim())). It takes a current WDDM 2.x driver; VMware's virtual GPU (WDDM 1.2) fails exactly here." }
            $pool = $dev.CreateTaskPool()
            $ms = New-Object Windows.Graphics.DirectX.Direct3D11.Direct3DMultisampleDescription; $ms.Count = 1
            $desc = [Windows.Devices.Display.Core.DisplayPrimaryDescription]::new([uint32]$w, [uint32]$h, $path.SourcePixelFormat, [Windows.Graphics.DirectX.DirectXColorSpace]::RgbFullG22NoneP709, $false, $ms)
            $gfx = New-Object Gfx($t.Adapter.Id.LowPart, $t.Adapter.Id.HighPart)
            $surf = foreach ($i in 0, 1) { $dev.CreatePrimary($t, $desc) }
            $scan = foreach ($s in $surf) { $dev.CreateSimpleScanout($src, $s, 0, 1) }
            foreach ($s in $surf) { $tex += $gfx.OpenSurface($dev, $s) }
            Log ('acquired {0} ({1}x{2}) on {3}; surface {4}' -f $t.StableMonitorId, $w, $h, $gfx.AdapterName, $gfx.Describe($tex[0]))
        }

        if ($Url -and -not $Pattern -and -not $Window -and -not $Auto) {
            $prof = "$dir\chrome-profile"; Stop-OurChrome $prof
            $cdp = New-Object Cdp($Chrome, $prof, $Url, $w, $h, [bool]$ShowBrowser)
        }
        $hwnd = [IntPtr]::Zero
        # never let the PC sleep under the dashboard; hold the displays on unless told otherwise (see header)
        if (-not [Pwr]::Keep($true, -not $LetDisplaysSleep)) { Log 'Windows refused the power request: the dashboard may go dark when the displays sleep' }
        $frame = New-Object Frame($w, $h)
        $end = if ($Auto) { $stopAt } elseif ($Seconds) { (Get-Date).AddSeconds($Seconds) } else { [datetime]::MaxValue }
        $beatEvery = if ($Pattern -or $FramesTo) { 1 } else { 10 }   # the heartbeat file is for tests; in daily use do not write to disk every second
        $i = 0; $n = 0; $still = 0; $said = $false; $beat = [datetime]::MinValue
        while ((Get-Date) -lt $end) {
            if ($cdp) {   # Chrome reports a new picture by itself, only when the page changed
                $j = $cdp.NextJpeg(1000); $fresh = [bool]$j
                if ($fresh) { [Pix]::Decode($j, $frame) }
            } else {
                if ($Auto) {
                    $drawn = if ($noted.Wins.Count) { [Pix]::CaptureWindows($noted, $frame) } else { 0 }
                    if (-not $drawn) {   # say why the screen is empty, on the screen itself and once in the log
                        $why = if (-not $noted.Wins.Count) { 'Nothing was open on this screen when the PC was locked' }
                               else { "The windows of this screen cannot be shown:`nWindows minimized them when the screen left the desktop, or they were closed.`nIf they were minimized: sign out and back in once. The setup changed a Windows`nsetting for that, and it takes effect only at sign-in." }
                        [Pix]::Notice($frame, $why)
                        if (-not $said) { $said = $true; Log ('auto: no window picture ({0} window(s) noted): {1}' -f $noted.Wins.Count, ($why -replace "`n", ' ')) }
                    }
                } elseif ($Window -and -not $Pattern) {
                    if ($hwnd -eq [IntPtr]::Zero) { $hwnd = [Pix]::FindWindow($Window) }
                    $st = if ($hwnd -eq [IntPtr]::Zero) { 'gone' } else { [Pix]::CaptureWindow($hwnd, $frame) }
                    if ($st -eq 'gone') { $hwnd = [IntPtr]::Zero }   # closed or not open yet: keep looking
                    if ($st -ne 'ok') { [Pix]::Notice($frame, "Waiting for a window with '$Window' in its title ($st)") }
                } else { [Pix]::Pattern($frame, $n, [Pix]::SessionState()) }
                $fresh = $frame.Changed()   # an unchanged picture is neither uploaded nor shown again
                if ($fresh) { $still = 0 } else { $still++ }
            }
            if ($fresh) {
                if ($FramesTo) { if ($n % 8 -eq 0) { $frame.Gdi.Save(('{0}\frame-{1:0000}-{2}.png' -f $FramesTo, $n, [Pix]::SessionState()), [System.Drawing.Imaging.ImageFormat]::Png) } }
                else {
                    $gfx.Upload($tex[$i], $frame.Bits, $frame.Stride)
                    $task = $pool.CreateTask(); $task.SetScanout($scan[$i]); $pool.ExecuteTask($task)
                    $dev.WaitForVBlank($src)
                    $i = 1 - $i
                }
                $n++
            }
            if ((Get-Date) -gt $beat) {   # read by Test-Locked.ps1: 'time' proves the loop lives, 'frames' proves new pictures
                Set-Content "$dir\dashboard.heartbeat" ('time={0:HH:mm:ss} frames={1}' -f (Get-Date), $n)
                $beat = (Get-Date).AddSeconds($beatEvery)
            }
            if ($cdp) { if ($fresh) { Start-Sleep -Milliseconds 80 } }   # at most about 10 pictures a second, however fast the page animates
            else {
                # windows have to be asked for their picture: 4 times a second while it changes, once a second after 2 s without change
                $pause = if ($still -ge 8) { 1000 } else { 250 }
                if (-not $Auto) { Start-Sleep -Milliseconds $pause } elseif (-not [Pix]::SleepWhileLocked($pause)) { break }   # unlocked: let go of the screen at once
            }
        }
    } finally {
        if ($Auto -and $n) { Log "auto: $n picture(s) shown" }
        $null = [Pwr]::Keep($false, $false)
        if ($cdp) { $cdp.Dispose() }
        foreach ($x in $tex) { [Gfx]::Free($x) }
        if ($gfx) { $gfx.Dispose() }
        if ($frame) { $frame.Dispose() }
        $dm.Dispose()   # revokes ownership of the target
    }
}

if ($Auto) {
    # Waits in the background and holds nothing. While the PC is unlocked it only notes which windows are on the
    # highest-numbered screen. At Win+L, Switch-LastScreen.exe (elevated, started by Windows' own lock event) takes that
    # screen off the desktop; as soon as it has, Run redraws the noted windows on it, live, until the PC is unlocked.
    # Then the helper puts the screen back.
    [Pix]::DpiAware()
    $stopAt = if ($Seconds) { (Get-Date).AddSeconds($Seconds) } else { [datetime]::MaxValue }
    try { Log 'auto: waiting for the PC to be locked' } catch { }
    while ((Get-Date) -lt $stopAt) {
        try {
            $noted = [Pix]::WaitForLock($(if ($Seconds) { [int][math]::Min([int]::MaxValue, [math]::Max(1, ($stopAt - (Get-Date)).TotalMilliseconds)) } else { 0 }))
            if (-not $noted) { break }   # only with -Seconds: time is up
            Log ('auto: locked; {0} window(s) noted on {1} {2}x{3}' -f $noted.Wins.Count, $noted.Device, $noted.W, $noted.H)
            $fails = 0; $early = @{}; $since = $null; $lockedAt = Get-Date
            while (-not [Pix]::Unlocked() -and (Get-Date) -lt $stopAt) {
                $held = [Pix]::Taken()
                # nothing to do until the helper has freed the screen (it never does on a single-screen desktop): wait cheaply
                if (-not $held) { Start-Sleep -Milliseconds 250; continue }
                if (-not $since) { $since = [Diagnostics.Stopwatch]::StartNew() }
                $ran = [Diagnostics.Stopwatch]::StartNew()
                try { Run }
                catch {
                    if ($ran.Elapsed.TotalSeconds -gt 60) { $fails = 0; $early.Clear(); $since.Restart() }   # it had been working: a new problem, not the old one again
                    # For the first moments after the screen left the desktop Windows is still rearranging things: the screen is not
                    # listed yet, still held by Windows, or changed again while it was being taken (Windows' own status for that is
                    # "retry"). Seen in the test VM and on a laptop with a TV. Ask again at once; each kind goes into the log once.
                    if ("$_" -match 'No connected specialized display|TargetAccessDenied|TargetStale|SystemStateChanged' -and $since.Elapsed.TotalSeconds -lt 20) {
                        if (-not $early["$_"]) { $early["$_"] = 1; Log "auto: not ready yet, asking again: $_" }
                        Start-Sleep -Milliseconds 200; continue
                    }
                    $fails++; Log "auto: $_"
                    $null = [Pix]::SleepWhileLocked(1000 * [math]::Min(60, 2 * $fails))   # try again after 2 s, 4 s, ... at most a minute: no busy loop, no flood in the log
                }
            }
            # how the lock ended belongs in the log: a lock that is over within seconds never gets as far as a picture
            $lasted = ((Get-Date) - $lockedAt).TotalSeconds; $idle = [Pix]::IdleSeconds()
            Log ('auto: unlocked after {0:N0} s; {1}' -f $lasted, $(if ($idle -ge $lasted) { 'keyboard and mouse were not used during the lock, so the sign-in was not typed (face, fingerprint or similar)' } else { 'keyboard or mouse were used during the lock' }))
            [Pix]::LockEnded()
        } catch {
            # Nothing outside restarts this program: it is started through a console host that hides its exit code from
            # Windows (see Install-Auto.ps1). So it has to survive its own errors, a log file that cannot be written for a
            # moment included, and start over.
            try { Log "auto: starting over after an error: $_" } catch { }
            Start-Sleep 10
        }
    }
    return
}
if ($Seconds) { Run; return }
while ($true) {   # sleep/resume, session switch, driver reset or a Chrome crash all surface as an exception: start over
    try { Run } catch { Log "restarting in 10 s: $_"; Start-Sleep 10 }
}
