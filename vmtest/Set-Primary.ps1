<#
Test-VM helper (logged-on session): make one screen of a two-screen desktop the primary display, or only list them.
  .\Set-Primary.ps1                          list: device, position, size, primary
  .\Set-Primary.ps1 -Device \\.\DISPLAY2     make it the primary (it moves to 0,0; the other screen goes to its left)
#>
param([string]$Device, [string]$Out = 'C:\locktest\primary.txt')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class Disp {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    public struct DEVMODE {
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
    [DllImport("user32.dll", CharSet = CharSet.Ansi, EntryPoint = "ChangeDisplaySettingsEx")] static extern int Apply(string dev, IntPtr dm, IntPtr hwnd, uint flags, IntPtr p);
    // place a screen; primary = it becomes the primary display. Staged in the registry (1 = UPDATEREGISTRY, 0x10000000 = NORESET, 0x10 = SET_PRIMARY).
    public static int Place(string dev, int x, int y, bool primary) {
        DEVMODE dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        if (!EnumDisplaySettings(dev, -1, ref dm)) return -99;   // -1 = ENUM_CURRENT_SETTINGS
        dm.dmFields = 0x20; dm.dmPositionX = x; dm.dmPositionY = y;   // 0x20 = DM_POSITION
        return ChangeDisplaySettingsEx(dev, ref dm, IntPtr.Zero, 1u | 0x10000000u | (primary ? 0x10u : 0u), IntPtr.Zero);
    }
    public static int Commit() { return Apply(null, IntPtr.Zero, IntPtr.Zero, 0, IntPtr.Zero); }
}
'@
$all = [Windows.Forms.Screen]::AllScreens
$r = @()
if ($Device) {
    $other = $all | Where-Object { $_.DeviceName -ne $Device } | Select-Object -First 1
    $r += "place $Device at 0,0 as primary: $([Disp]::Place($Device, 0, 0, $true))"
    if ($other) { $r += "place $($other.DeviceName) to its left: $([Disp]::Place($other.DeviceName, -$other.Bounds.Width, 0, $false))" }
    $r += "commit: $([Disp]::Commit())   (0 = done)"
    Start-Sleep 3
}
$r += [Windows.Forms.Screen]::AllScreens | ForEach-Object { '{0} at {1},{2} {3}x{4} primary={5}' -f $_.DeviceName, $_.Bounds.X, $_.Bounds.Y, $_.Bounds.Width, $_.Bounds.Height, $_.Primary }
Set-Content $Out $r
