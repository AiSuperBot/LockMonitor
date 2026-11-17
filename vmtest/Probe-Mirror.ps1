<#
Lock probe for the test VM (run in the logged-on user's session, unelevated).
Question: while the workstation is locked, can a user-session process still read the LIVE picture of ordinary windows?
That decides whether "whatever is open stays visible" (mirroring arbitrary windows) can work at all.
Once per second, per window, it logs:
  wgc   = frames Windows.Graphics.Capture delivered in that second (the modern capture API, fed by DWM)
  dwm   = PrintWindow(PW_RENDERFULLCONTENT): 'new' picture / 'same' / 'black' / 'fail'   (also DWM)
  print = PrintWindow(0), i.e. the app painting itself on request (WM_PRINT): works for classic GDI apps only
Windows: gdi = a WinForms label ticking every 100 ms; chrome = Chrome, default flags; noOcc = Chrome told not to pause
when hidden; the "...Plain" twins are the same but with no capture session on them (wgc=n/a), only the once-a-second
PrintWindow. Compare the rows with locked=True against the rows with locked=False. secure=True marks the moments
the secure desktop owns the screen (just after locking, and while the sign-in box is up).
  .\Probe-Mirror.ps1 -Seconds 120 -Chrome C:\Chrome\chrome.exe        log: C:\locktest\mirror.log
#>
param([int]$Seconds = 120, [string]$Chrome, [string]$Dir = 'C:\locktest', [switch]$Flags)
$ErrorActionPreference = 'Stop'
$null = New-Item -ItemType Directory -Force $Dir
$Log = "$Dir\mirror.log"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;

public static class Probe {
    [ComImport, Guid("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IGraphicsCaptureItemInterop {
        [PreserveSig] int CreateForWindow(IntPtr hwnd, ref Guid iid, out IntPtr result);
    }
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int l, t, r, b; }
    delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("combase.dll")] static extern int RoGetActivationFactory(IntPtr classId, ref Guid iid, out IntPtr factory);
    [DllImport("combase.dll", CharSet = CharSet.Unicode)] static extern int WindowsCreateString(string s, int len, out IntPtr h);
    [DllImport("combase.dll")] static extern int WindowsDeleteString(IntPtr h);
    [DllImport("d3d11.dll")] static extern int D3D11CreateDevice(IntPtr adapter, int driverType, IntPtr software, uint flags, IntPtr levels, uint n, uint sdk, out IntPtr dev, out int level, out IntPtr ctx);
    [DllImport("d3d11.dll")] static extern int CreateDirect3D11DeviceFromDXGIDevice(IntPtr dxgiDevice, out IntPtr graphicsDevice);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out RECT r);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr h);

    [DllImport("wtsapi32.dll")] static extern bool WTSQuerySessionInformation(IntPtr server, int session, int infoClass, out IntPtr buf, out int bytes);
    [DllImport("wtsapi32.dll")] static extern void WTSFreeMemory(IntPtr p);
    // locked = Windows' own flag (WTSSessionInfoEx, SessionFlags 0 = locked); secure = the secure desktop owns the screen
    public static bool Locked() { IntPtr p; int n; if (!WTSQuerySessionInformation(IntPtr.Zero, -1, 25, out p, out n)) return false; int f = Marshal.ReadInt32(p, 16); WTSFreeMemory(p); return f == 0; }   // offset 16: Level, padding, SessionId, SessionState, SessionFlags
    public static bool Secure() { IntPtr h = OpenInputDesktop(0, false, 0x100); if (h == IntPtr.Zero) return true; CloseDesktop(h); return false; }

    public static IntPtr FindWindow(string titlePart) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, p) => {
            if (!IsWindowVisible(h)) return true;
            StringBuilder s = new StringBuilder(256); GetWindowText(h, s, 256);
            if (s.ToString().IndexOf(titlePart, StringComparison.OrdinalIgnoreCase) >= 0) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static object CaptureItem(IntPtr hwnd) {
        string cls = "Windows.Graphics.Capture.GraphicsCaptureItem";
        IntPtr hs; WindowsCreateString(cls, cls.Length, out hs);
        Guid iidInterop = new Guid("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356");
        IntPtr pFactory; int hr = RoGetActivationFactory(hs, ref iidInterop, out pFactory); WindowsDeleteString(hs);
        if (hr < 0) throw new COMException("RoGetActivationFactory", hr);
        IGraphicsCaptureItemInterop interop = (IGraphicsCaptureItemInterop)Marshal.GetObjectForIUnknown(pFactory);
        Guid iidItem = new Guid("79C3F95B-31F7-4EC2-A464-632EF5D30760");
        IntPtr pItem; hr = interop.CreateForWindow(hwnd, ref iidItem, out pItem);
        Marshal.Release(pFactory);
        if (hr < 0) throw new COMException("CreateForWindow", hr);
        object o = Marshal.GetObjectForIUnknown(pItem); Marshal.Release(pItem);
        return o;
    }

    // The D3D device object has no WinRT class name, so it arrives as a bare COM object that PowerShell will not pass
    // to a WinRT method. Reflection does the interface query that PowerShell's binder skips.
    public static object CreatePool(Type poolType, object device, object format, int buffers, object size) {
        return poolType.GetMethod("CreateFreeThreaded").Invoke(null, new object[] { device, format, buffers, size });
    }

    public static string DeviceKind;
    public static object Device() {
        IntPtr dev, ctx; int lvl;
        int hr = D3D11CreateDevice(IntPtr.Zero, 1, IntPtr.Zero, 0x20, IntPtr.Zero, 0, 7, out dev, out lvl, out ctx); DeviceKind = "hardware";
        if (hr < 0) { hr = D3D11CreateDevice(IntPtr.Zero, 5, IntPtr.Zero, 0x20, IntPtr.Zero, 0, 7, out dev, out lvl, out ctx); DeviceKind = "WARP"; }
        if (hr < 0) throw new COMException("D3D11CreateDevice", hr);
        Guid iidDxgi = new Guid("54ec77fa-1377-44e6-8c32-88fd5f44c84c");
        IntPtr dxgi; Marshal.QueryInterface(dev, ref iidDxgi, out dxgi);
        IntPtr gd; hr = CreateDirect3D11DeviceFromDXGIDevice(dxgi, out gd);
        Marshal.Release(dxgi);
        if (hr < 0) throw new COMException("CreateDirect3D11DeviceFromDXGIDevice", hr);
        object o = Marshal.GetObjectForIUnknown(gd); Marshal.Release(gd);
        return o;
    }

    // "ok|fail" : hash of sampled pixels : number of non-black samples
    public static string Snap(IntPtr hwnd, uint flags) {
        RECT r; if (!GetWindowRect(hwnd, out r)) return "fail:0:0";
        int w = r.r - r.l, h = r.b - r.t; if (w <= 0 || h <= 0) return "fail:0:0";
        using (Bitmap bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb)) {
            bool ok;
            using (Graphics g = Graphics.FromImage(bmp)) { IntPtr dc = g.GetHdc(); ok = PrintWindow(hwnd, dc, flags); g.ReleaseHdc(dc); }
            BitmapData bd = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            uint hash = 2166136261; int nonBlack = 0, n = w * h;
            for (int i = 0; i < n; i += 7) { int px = Marshal.ReadInt32(bd.Scan0, i * 4) & 0xFFFFFF; hash = (hash ^ (uint)px) * 16777619; if (px != 0) nonBlack++; }
            bmp.UnlockBits(bd);
            return (ok ? "ok" : "fail") + ":" + hash + ":" + nonBlack;
        }
    }
}
'@
$null = [Windows.Graphics.Capture.GraphicsCaptureItem, Windows.Graphics.Capture, ContentType=WindowsRuntime]
$null = [Windows.Graphics.DirectX.DirectXPixelFormat, Windows.Graphics.DirectX, ContentType=WindowsRuntime]
$null = [Windows.Graphics.DirectX.Direct3D11.IDirect3DDevice, Windows.Graphics.DirectX.Direct3D11, ContentType=WindowsRuntime]

# --- the windows to watch -------------------------------------------------------------------------------------------
$form = New-Object Windows.Forms.Form -Property @{ Text = 'probe-gdi'; Width = 420; Height = 160; StartPosition = 'Manual'; Left = 40; Top = 40; TopMost = $false }
$label = New-Object Windows.Forms.Label -Property @{ Dock = 'Fill'; Font = (New-Object Drawing.Font('Segoe UI', 28)); Text = '0' }
$form.Controls.Add($label)
$timer = New-Object Windows.Forms.Timer -Property @{ Interval = 100 }
$timer.add_Tick({ $label.Text = [Environment]::TickCount.ToString() })
$form.Show(); $timer.Start()

$started = @()
# the same two Chrome set-ups, each once WITH a Windows.Graphics.Capture session on it and once without ("Plain"),
# to tell apart "Chrome keeps drawing by itself" from "Chrome keeps drawing because it is being captured"
$noOcc = '--disable-features=CalculateNativeWinOcclusion --disable-backgrounding-occluded-windows --disable-renderer-backgrounding --disable-background-timer-throttling'
$variants = @(@{ n = 'chrome'; a = ''; wgc = $true }, @{ n = 'chromePlain'; a = ''; wgc = $false }, @{ n = 'noOcc'; a = $noOcc; wgc = $true }, @{ n = 'noOccPlain'; a = $noOcc; wgc = $false })
if ($Flags) {   # second question: which single switch is enough?
    $variants = @(@{ n = 'chrome'; a = ''; wgc = $false }, @{ n = 'occludedSwitch'; a = '--disable-backgrounding-occluded-windows'; wgc = $false }, @{ n = 'featureSwitch'; a = '--disable-features=CalculateNativeWinOcclusion'; wgc = $false }, @{ n = 'noOcc'; a = $noOcc; wgc = $false })
}
if ($Chrome) {
    $top = 200
    foreach ($v in $variants) {
        $html = "$Dir\probe-$($v.n).html"
        Set-Content $html ('<title>probe-{0}-end</title><body style="font:40px sans-serif;background:navy;color:white"><div id=t></div><script>setInterval(()=>t.textContent=Date.now(),100)</script>' -f $v.n)
        Start-Process $Chrome -ArgumentList "--user-data-dir=`"$Dir\prof-$($v.n)`" --no-first-run --no-default-browser-check --disable-sync --disable-background-networking --new-window --window-size=420,200 --window-position=40,$top $($v.a) `"file:///$($html -replace '\\','/')`""
        $started += "$Dir\prof-$($v.n)"; $top += 130
    }
}

function Find($title) { for ($i = 0; $i -lt 80; $i++) { $h = [Probe]::FindWindow($title); if ($h -ne [IntPtr]::Zero) { return $h }; [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 250 }; [IntPtr]::Zero }
$targets = @([pscustomobject]@{ Name = 'gdi'; H = $form.Handle; UseWgc = $true })
if ($Chrome) { foreach ($v in $variants) { $h = Find "probe-$($v.n)-end"; if ($h -ne [IntPtr]::Zero) { $targets += [pscustomobject]@{ Name = $v.n; H = $h; UseWgc = $v.wgc } } else { Add-Content $Log "window probe-$($v.n) not found" } } }

$device = [Probe]::Device()
foreach ($t in $targets) {
    $t | Add-Member Wgc 'n/a'; $t | Add-Member Pool $null; $t | Add-Member Session $null; $t | Add-Member Last @{ 2 = ''; 0 = '' }
    if (-not $t.UseWgc) { continue }
    try {
        $item = [Probe]::CaptureItem($t.H)
        $t.Pool = [Probe]::CreatePool([Windows.Graphics.Capture.Direct3D11CaptureFramePool], $device, [Windows.Graphics.DirectX.DirectXPixelFormat]::B8G8R8A8UIntNormalized, 2, $item.Size)
        $t.Session = $t.Pool.CreateCaptureSession($item)
        $t.Session.StartCapture()
        $t.Wgc = 0
    } catch { Add-Content $Log "WGC setup failed for $($t.Name): $($_.Exception.Message)" }
}
Add-Content $Log ('{0:HH:mm:ss} start: windows={1} d3d={2}' -f (Get-Date), (($targets | ForEach-Object Name) -join ','), [Probe]::DeviceKind)

function Judge($t, $flag) {
    $s = [Probe]::Snap($t.H, $flag); $p = $s -split ':'
    $r = if ($p[0] -ne 'ok') { 'fail' } elseif ($p[2] -eq '0') { 'black' } elseif ($s -eq $t.Last[$flag]) { 'same' } else { 'new' }
    $t.Last[$flag] = $s; $r
}

# --- once per second: what did each capture path deliver? -------------------------------------------------------------
try {
    $end = (Get-Date).AddSeconds($Seconds); $next = (Get-Date).AddSeconds(1)
    while ((Get-Date) -lt $end) {
        [Windows.Forms.Application]::DoEvents()
        foreach ($t in $targets) { if ($t.Pool) { while ($f = $t.Pool.TryGetNextFrame()) { $t.Wgc++; $f.Dispose() } } }
        if ((Get-Date) -ge $next) {
            $next = $next.AddSeconds(1)
            $row = '{0:HH:mm:ss} locked={1,-5} secure={2,-5}' -f (Get-Date), [Probe]::Locked(), [Probe]::Secure()
            foreach ($t in $targets) {
                $row += ' | {0}: wgc={1,-3} dwm={2,-5} print={3,-5}' -f $t.Name, $t.Wgc, (Judge $t 2), (Judge $t 0)
                if ($t.Pool) { $t.Wgc = 0 }
            }
            Add-Content $Log $row
        }
        Start-Sleep -Milliseconds 40
    }
} finally {
    foreach ($t in $targets) { if ($t.Session) { $t.Session.Dispose() }; if ($t.Pool) { $t.Pool.Dispose() } }
    $form.Close()
    foreach ($p in $started) { Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -like "*$p*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } }
    Add-Content $Log ('{0:HH:mm:ss} end' -f (Get-Date))
}
