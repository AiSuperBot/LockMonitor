<#
Test-VM helper (logged-on session): after a delay, set one screen's resolution. Windows remembers a resolution per
screen arrangement, so to change what a screen has while the other one is off the desktop, start this before the
lock (-After) and let it act during the lock.
  .\Set-Mode.ps1 -Device \\.\DISPLAY1 -Width 1280 -Height 800 -After 8
#>
param([Parameter(Mandatory)][string]$Device, [int]$Width = 1280, [int]$Height = 800, [int]$After = 0)
Start-Sleep $After
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class Md {
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
    public static string Set(string dev, int w, int h) {
        DEVMODE dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        if (!EnumDisplaySettings(dev, -1, ref dm)) return "cannot read the current mode of " + dev;
        string was = dm.dmPelsWidth + "x" + dm.dmPelsHeight;
        dm.dmFields = 0x80000 | 0x100000; dm.dmPelsWidth = w; dm.dmPelsHeight = h;   // DM_PELSWIDTH | DM_PELSHEIGHT
        return dev + " was " + was + ", set to " + w + "x" + h + ": result " + ChangeDisplaySettingsEx(dev, ref dm, IntPtr.Zero, 1, IntPtr.Zero);   // 1 = remember it
    }
}
'@
Add-Content C:\locktest\screens.log ('{0:HH:mm:ss} {1}' -f (Get-Date), [Md]::Set($Device, $Width, $Height))
