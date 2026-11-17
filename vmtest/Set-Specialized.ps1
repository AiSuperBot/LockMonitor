<#
Test-VM helper: switch Windows' "Remove display from desktop" (specialized display) for one monitor through the API
(DisplayConfigSetDeviceInfo, DISPLAYCONFIG_DEVICE_INFO_SET_MONITOR_SPECIALIZATION) instead of clicking through Settings.
Microsoft documents the structure but not which GUIDs it expects, so this is for the VM only until proven.
  .\Set-Specialized.ps1                          list connected monitors and their state
  .\Set-Specialized.ps1 -Index 1 -On [-Type <guid>] [-SubType <guid>] [-App <name>]
  .\Set-Specialized.ps1 -Index 1 -Off
Prints the Win32 result code: 0 = success, 5 = access denied (needs elevation), 87 = invalid parameter.
#>
param([int]$Index = -1, [switch]$On, [switch]$Off, [guid]$Type = [guid]::Empty, [guid]$SubType = [guid]::Empty, [string]$App = '')
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class SpecApi {
    [StructLayout(LayoutKind.Sequential)] struct GetReq { public int type, size; public uint lo; public int hi; public uint id, flags; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct SetReq { public int type, size; public uint lo; public int hi; public uint id, flags; public Guid specType, specSubType;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string app; }
    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref GetReq r);
    [DllImport("user32.dll")] static extern int DisplayConfigSetDeviceInfo(ref SetReq r);
    public static string Get(uint lo, int hi, uint id) {
        GetReq r = new GetReq(); r.type = 12; r.size = Marshal.SizeOf(typeof(GetReq)); r.lo = lo; r.hi = hi; r.id = id;
        int rc = DisplayConfigGetDeviceInfo(ref r);
        return rc != 0 ? "error " + rc : "enabled=" + (r.flags & 1) + " availableForMonitor=" + ((r.flags >> 1) & 1) + " availableForSystem=" + ((r.flags >> 2) & 1);
    }
    public static int Set(uint lo, int hi, uint id, bool on, Guid type, Guid subType, string app) {
        SetReq r = new SetReq(); r.type = 13; r.size = Marshal.SizeOf(typeof(SetReq)); r.lo = lo; r.hi = hi; r.id = id;
        r.flags = on ? 1u : 0u; r.specType = type; r.specSubType = subType; r.app = app ?? "";
        return DisplayConfigSetDeviceInfo(ref r);
    }
    public static int SetSize { get { return Marshal.SizeOf(typeof(SetReq)); } }
}
'@
$null = [Windows.Devices.Display.Core.DisplayManager, Windows.Devices.Display.Core, ContentType=WindowsRuntime]
$dm = [Windows.Devices.Display.Core.DisplayManager]::Create('None')
$targets = @($dm.GetCurrentTargets() | Where-Object IsConnected)
for ($i = 0; $i -lt $targets.Count; $i++) {
    $t = $targets[$i]; $m = $t.TryGetMonitor()
    '[{0}] {1,-12} {2,-16} id={3} relId={4}  {5}' -f $i, $t.UsageKind, $(if ($m) { $m.DisplayName } else { '?' }), $t.StableMonitorId, $t.AdapterRelativeId, [SpecApi]::Get($t.Adapter.Id.LowPart, $t.Adapter.Id.HighPart, $t.AdapterRelativeId)
}
if ($Index -ge 0 -and ($On -or $Off)) {
    $t = $targets[$Index]
    $rc = [SpecApi]::Set($t.Adapter.Id.LowPart, $t.Adapter.Id.HighPart, $t.AdapterRelativeId, [bool]$On, $Type, $SubType, $App)
    'set [{0}] {1}: result {2} (struct {3} bytes, type {4}, subType {5}, app "{6}")' -f $Index, $(if ($On) { 'ON' } else { 'OFF' }), $rc, [SpecApi]::SetSize, $Type, $SubType, $App
    Start-Sleep 2
    'after: ' + [SpecApi]::Get($t.Adapter.Id.LowPart, $t.Adapter.Id.HighPart, $t.AdapterRelativeId)
}
$dm.Dispose()
