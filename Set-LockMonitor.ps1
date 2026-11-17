<#
Switches the highest-numbered monitor (\\.\DISPLAYn, found by enumeration, not by port) to a kiosk device's
input while the workstation is locked, and back on unlock. Uses DDC/CI input select (MCCS VCP 0x60).
The Windows lock itself is not touched: this only changes which source the panel shows.

  .\Set-LockMonitor.ps1 -Action Info                              read-only: monitors, current + supported inputs, DDC power-mode support, the one used (*)
  .\Set-LockMonitor.ps1 -Action Lock -KioskInput 0x11 [-WhatIf]   remember the current input, switch to the kiosk input
  .\Set-LockMonitor.ps1 -Action Unlock [-WhatIf]                  restore the remembered input

Typical VCP 0x60 values: 01 VGA, 03 DVI, 0F DisplayPort-1, 10 DisplayPort-2, 11 HDMI-1, 12 HDMI-2. Models differ: trust Info.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateSet('Info', 'Lock', 'Unlock')][string]$Action,
    [uint32]$KioskInput
)
$ErrorActionPreference = 'Stop'
$dir = "$env:LOCALAPPDATA\LockMonitor"
$null = New-Item -ItemType Directory -Force $dir -WhatIf:$false
$StateFile = "$dir\state.json"
# scheduled tasks fail silently: keep a trail. 'break' rethrows, so a failed step never falls through to the next one.
trap { Add-Content "$dir\log.txt" ('{0:s} {1}: {2}' -f (Get-Date), $Action, $_); break }

if (-not ('LockMon' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

public class LockMon {
    public class Panel { public int N; public string Device, Id, Rect; public IntPtr H; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct MONITORINFOEX { public int cbSize; public int l, t, r, b, wl, wt, wr, wb; public uint flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string device; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DISPLAY_DEVICE { public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string name;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string str; public int flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string id;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string key; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct PHYSICAL_MONITOR { public IntPtr h;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string desc; }

    delegate bool EnumProc(IntPtr hm, IntPtr dc, IntPtr rc, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, EnumProc cb, IntPtr data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr hm, ref MONITORINFOEX mi);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplayDevices(string dev, uint i, ref DISPLAY_DEVICE dd, uint flags);
    [DllImport("dxva2.dll")] static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr hm, out uint n);
    [DllImport("dxva2.dll")] static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hm, uint n, [Out] PHYSICAL_MONITOR[] a);
    [DllImport("dxva2.dll")] static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr h, byte code, IntPtr type, out uint cur, out uint max);
    [DllImport("dxva2.dll")] static extern bool SetVCPFeature(IntPtr h, byte code, uint value);
    [DllImport("dxva2.dll")] static extern bool GetCapabilitiesStringLength(IntPtr h, out uint n);
    [DllImport("dxva2.dll")] static extern bool CapabilitiesRequestAndCapabilitiesReply(IntPtr h, StringBuilder s, uint n);

    public static List<Panel> List() {
        var r = new List<Panel>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (hm, dc, rc, d) => {
            var mi = new MONITORINFOEX(); mi.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
            if (!GetMonitorInfo(hm, ref mi)) return true;
            var dd = new DISPLAY_DEVICE(); dd.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
            EnumDisplayDevices(mi.device, 0, ref dd, 1);   // 1 = EDD_GET_DEVICE_INTERFACE_NAME: per-monitor id that survives renumbering
            var p = new Panel { Device = mi.device, Id = string.IsNullOrEmpty(dd.id) ? mi.device : dd.id,
                Rect = (mi.r - mi.l) + "x" + (mi.b - mi.t) + " at " + mi.l + "," + mi.t };
            int.TryParse(Regex.Match(mi.device, @"\d+$").Value, out p.N);
            uint n;
            if (GetNumberOfPhysicalMonitorsFromHMONITOR(hm, out n) && n > 0) {
                var a = new PHYSICAL_MONITOR[n];
                if (GetPhysicalMonitorsFromHMONITOR(hm, n, a)) p.H = a[0].h;   // shortcut: handles never destroyed, process is short-lived; fix if this becomes a service
            }
            r.Add(p);   // listed even without a DDC handle, so a non-DDC monitor is visible instead of silently skipped
            return true;
        }, IntPtr.Zero);
        return r;
    }
    public static long Get(IntPtr h, byte code) { uint cur, max; return GetVCPFeatureAndVCPFeatureReply(h, code, IntPtr.Zero, out cur, out max) ? (long)cur : -1L; }
    public static bool Set(IntPtr h, byte code, uint v) { return SetVCPFeature(h, code, v); }
    public static string Caps(IntPtr h) {
        uint n;
        if (!GetCapabilitiesStringLength(h, out n) || n == 0) return null;
        var s = new StringBuilder((int)n);
        return CapabilitiesRequestAndCapabilitiesReply(h, s, n) ? s.ToString() : null;
    }
}
'@
}

$mons = [LockMon]::List()
$state = if (Test-Path $StateFile) { Get-Content $StateFile -Raw | ConvertFrom-Json }
# Unlock must hit the panel Lock chose, even if the topology changed meanwhile: match the remembered id, not "highest number".
$target = if ($state) { $mons | Where-Object Id -eq $state.Id } else { $mons | Sort-Object N -Descending | Select-Object -First 1 }

if ($Action -eq 'Info') {
    foreach ($m in $mons | Sort-Object N) {
        $cur = [LockMon]::Get($m.H, 0x60)
        $caps = [LockMon]::Caps($m.H)
        $pw = [LockMon]::Get($m.H, 0xD6)   # MCCS power mode (01 on, 04 standby, 05 off): only read here, to show if this monitor could be slept on its own
        '{0} {1}  {2}  input={3}  supported={4}  power={5} ({6})  {7}' -f $(if ($m -eq $target) { '*' } else { ' ' }), $m.Device, $m.Rect,
            $(if ($cur -ge 0) { '0x{0:X2}' -f $cur } else { 'unreadable' }),
            $(if ($caps -match '\b60\(([^)]*)\)') { $Matches[1] } else { '?' }),
            $(if ($pw -ge 0) { '0x{0:X2}' -f $pw } else { 'unreadable' }),
            $(if ($caps -match '\bD6\(([^)]*)\)') { $Matches[1] } elseif ($caps -match '\bD6\b') { 'values not listed' } else { 'not advertised' }), $m.Id
    }
    if ($state) { 'restore pending: {0} -> input 0x{1:X2}' -f $state.Id, $state.Previous }
    return
}

if ($Action -eq 'Unlock' -and -not $state) { return }   # nothing was switched
if (-not $target) { throw "Target monitor not found ($($mons.Count) seen). If a lock was interrupted, delete $StateFile." }

if ($Action -eq 'Lock') {
    if (-not $KioskInput) { throw '-KioskInput <VCP 0x60 value> is required for Lock (see -Action Info).' }
    # a repeated Lock keeps the first remembered input: the panel is probably already on the kiosk input
    $prev = if ($state) { $state.Previous } else { [LockMon]::Get($target.H, 0x60) }
    if ($prev -lt 0) { throw "Cannot read $($target.Device) input (DDC/CI off?). Not switching, so it cannot get stuck on the kiosk input." }
    @{ Id = $target.Id; Previous = $prev } | ConvertTo-Json | Set-Content $StateFile   # saved before switching
    $to = $KioskInput
} else {
    $to = [uint32]$state.Previous
}

if ($PSCmdlet.ShouldProcess($target.Device, ('set input 0x{0:X2}' -f $to))) {
    $ok = $false
    for ($i = 0; $i -lt 3 -and -not $ok; $i++) {   # DDC/CI is flaky right after unlock or wake
        if ($i) { Start-Sleep 2 }
        $ok = [LockMon]::Set($target.H, 0x60, $to)
    }
    if (-not $ok) { throw "Setting input on $($target.Device) failed (monitor ignores DDC/CI on the inactive input?). Use the monitor's own buttons." }
    if ($Action -eq 'Unlock') { Remove-Item $StateFile }
    Add-Content "$dir\log.txt" ('{0:s} {1}: {2} -> input 0x{3:X2}' -f (Get-Date), $Action, $target.Device, $to)
}
