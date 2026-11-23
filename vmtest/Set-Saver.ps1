<#
Test-VM helper (logged-on session): turn the blank screen saver on with "On resume, display logon screen" after
-Timeout seconds, the way an automatic lock is often set up; -Off turns it off again.
#>
param([int]$Timeout = 60, [switch]$Off)
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class Saver { [DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint action, uint param, IntPtr v, uint flags); }
'@
$k = 'HKCU:\Control Panel\Desktop'
if ($Off) {
    [Saver]::SystemParametersInfo(0x11, 0, [IntPtr]::Zero, 3) | Out-Null   # SPI_SETSCREENSAVEACTIVE off; 3 = save and tell the apps
    [Saver]::SystemParametersInfo(0x77, 0, [IntPtr]::Zero, 3) | Out-Null   # SPI_SETSCREENSAVESECURE off
    Remove-ItemProperty $k -Name SCRNSAVE.EXE -ErrorAction SilentlyContinue
} else {
    Set-ItemProperty $k -Name SCRNSAVE.EXE -Value "$env:SystemRoot\System32\scrnsave.scr"
    [Saver]::SystemParametersInfo(0x0F, $Timeout, [IntPtr]::Zero, 3) | Out-Null   # SPI_SETSCREENSAVETIMEOUT
    [Saver]::SystemParametersInfo(0x77, 1, [IntPtr]::Zero, 3) | Out-Null          # SPI_SETSCREENSAVESECURE: lock on resume
    [Saver]::SystemParametersInfo(0x11, 1, [IntPtr]::Zero, 3) | Out-Null          # SPI_SETSCREENSAVEACTIVE
}
Get-ItemProperty $k | Select-Object ScreenSaveActive, ScreenSaveTimeOut, ScreenSaverIsSecure, SCRNSAVE.EXE | Format-List | Out-String
