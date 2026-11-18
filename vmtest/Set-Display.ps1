<#
Test-VM helper (logged-on session): change a screen the way Settings > Display does, or list the screens, after an
optional delay. Windows remembers resolution and arrangement per set of screens on the desktop, so to change what one
screen has while another is off the desktop, start this before the lock (-After) and let it act during the lock.
  .\Set-Display.ps1                                           list: device, position, size, primary
  .\Set-Display.ps1 -Device \\.\DISPLAY2 -Primary             make it the primary display (the other one moves to its left)
  .\Set-Display.ps1 -Device \\.\DISPLAY1 -Width 1280 -Height 800 [-After 8]   set its resolution
Writes what it did and the screens afterwards to -Out.
#>
param([string]$Device, [switch]$Primary, [int]$Width, [int]$Height, [int]$After = 0, [string]$Out = 'C:\locktest\display.txt')
Start-Sleep $After
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class Disp {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra; public int dmFields;
        public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels; public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
        public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
    }
    [DllImport("user32.dll", CharSet = CharSet.Ansi)] static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);
    [DllImport("user32.dll", CharSet = CharSet.Ansi)] static extern int ChangeDisplaySettingsEx(string dev, ref DEVMODE dm, IntPtr hwnd, uint flags, IntPtr p);
    [DllImport("user32.dll", CharSet = CharSet.Ansi, EntryPoint = "ChangeDisplaySettingsEx")] static extern int ApplyAll(string dev, IntPtr dm, IntPtr hwnd, uint flags, IntPtr p);
    // Stage a change of one screen: its position (when primary or x/y are given) or its resolution (w, h > 0).
    // 1 = UPDATEREGISTRY | 0x10000000 = NORESET (| 0x10 = SET_PRIMARY); Apply() then makes all staged changes at once.
    public static int Stage(string dev, bool position, int x, int y, bool primary, int w, int h) {
        DEVMODE dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        if (!EnumDisplaySettings(dev, -1, ref dm)) return -99;   // -1 = ENUM_CURRENT_SETTINGS
        dm.dmFields = 0;
        if (position) { dm.dmFields |= 0x20; dm.dmPositionX = x; dm.dmPositionY = y; }   // DM_POSITION
        if (w > 0) { dm.dmFields |= 0x80000 | 0x100000; dm.dmPelsWidth = w; dm.dmPelsHeight = h; }   // DM_PELSWIDTH | DM_PELSHEIGHT
        return ChangeDisplaySettingsEx(dev, ref dm, IntPtr.Zero, 1u | 0x10000000u | (primary ? 0x10u : 0u), IntPtr.Zero);
    }
    public static int Apply() { return ApplyAll(null, IntPtr.Zero, IntPtr.Zero, 0, IntPtr.Zero); }
}
'@
$r = @()
if ($Device) {
    if ($Primary) {
        $other = [Windows.Forms.Screen]::AllScreens | Where-Object { $_.DeviceName -ne $Device } | Select-Object -First 1
        $r += "make $Device the primary display at 0,0: $([Disp]::Stage($Device, $true, 0, 0, $true, 0, 0))"
        if ($other) { $r += "move $($other.DeviceName) to its left: $([Disp]::Stage($other.DeviceName, $true, -$other.Bounds.Width, 0, $false, 0, 0))" }
    }
    if ($Width) { $r += "set $Device to ${Width}x${Height}: $([Disp]::Stage($Device, $false, 0, 0, $false, $Width, $Height))" }
    $r += "apply: $([Disp]::Apply())   (0 = done)"
    Start-Sleep 3
}
# a fresh process lists the screens: this one's list of screens is stale after a change (measured)
$r += powershell -NoProfile -Command "Add-Type -AssemblyName System.Windows.Forms; [Windows.Forms.Screen]::AllScreens | ForEach-Object { '{0} at {1},{2} {3}x{4} primary={5}' -f `$_.DeviceName, `$_.Bounds.X, `$_.Bounds.Y, `$_.Bounds.Width, `$_.Bounds.Height, `$_.Primary }"
Add-Content $Out (@('{0:HH:mm:ss}' -f (Get-Date)) + $r)
