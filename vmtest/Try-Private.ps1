<#
Test-VM experiment (ELEVATED, except -StateOnly): take the last connected display target off the desktop with the request
Windows' own Settings helper sends for "Remove display from desktop" (SystemSettingsAdminFlows.exe SpecializeDisplay:
DisplayConfig device-info type -23, 48 bytes: header, GUID_MONITOR_OVERRIDE_PSEUDO_SPECIALIZED, int on/off, a 64-bit
value), and put it back. The value is what Settings computes (found by capturing its command line in the VM): the
case-insensitive X65599 hash (RtlHashUnicodeString) of the monitor's ID from Windows' type -7 report + the GUID in braces,
the first half of the characters giving the low 32 bits and the rest the high 32 bits. -Value overrides it; -Public sends
LockMonitor's documented request (type 13) instead.
Around each step: the -7 report (size -Size), the public type 12 answer, whether the target is part of the desktop, and
which bytes of the -7 report changed.   -StateOnly: only the state now (and the report saved as <Out>-now.bin).   Log: -Out
#>
param([string]$Out = 'C:\locktest\try-private.txt', [string]$Value = 'computed', [int]$Hold = 4, [int]$Size = 940, [switch]$Public, [switch]$StateOnly,
      [ValidateSet('cycle', 'take', 'give', 'state')][string]$Step = 'cycle')   # take/give/state alone: the target is remembered in C:\locktest\held-target.txt
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Text;
public static class Priv {
    [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint np, out uint nm);
    [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint np, byte[] paths, ref uint nm, byte[] modes, IntPtr topo);
    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(byte[] packet);
    [DllImport("user32.dll")] static extern int DisplayConfigSetDeviceInfo(byte[] packet);
    public static byte[] Packet(int type, int size, uint lo, int hi, uint id) {
        byte[] p = new byte[size];
        BitConverter.GetBytes(type).CopyTo(p, 0); BitConverter.GetBytes(size).CopyTo(p, 4);
        BitConverter.GetBytes(lo).CopyTo(p, 8); BitConverter.GetBytes(hi).CopyTo(p, 12); BitConverter.GetBytes(id).CopyTo(p, 16);
        return p;
    }
    static readonly Guid Pseudo = new Guid("f196c02f-f86f-4f9a-aa15-e9cebdfe3b96");
    static uint Hash(string s) { uint h = 0; foreach (char c in s) h = h * 65599 + (uint)char.ToUpperInvariant(c); return h; }
    public static ulong SettingsValue(string monitorId) {
        string s = monitorId + "{" + Pseudo.ToString().ToUpperInvariant() + "}";
        int half = s.Length / 2;
        return ((ulong)Hash(s.Substring(half)) << 32) | Hash(s.Substring(0, half));
    }
    public static string MonitorId(byte[] report) { string s = Encoding.Unicode.GetString(report, 20, 256); int z = s.IndexOf('\0'); return z >= 0 ? s.Substring(0, z) : s; }
    public static int SetPrivate(uint lo, int hi, uint id, bool on, ulong value) {
        byte[] p = Packet(-23, 48, lo, hi, id);
        Pseudo.ToByteArray().CopyTo(p, 20); BitConverter.GetBytes(on ? 1 : 0).CopyTo(p, 36); BitConverter.GetBytes(value).CopyTo(p, 40);
        return DisplayConfigSetDeviceInfo(p);
    }
    public static int SetPublic(uint lo, int hi, uint id, bool on) {   // LockMonitor 0.2.5's request
        byte[] p = Packet(13, 312, lo, hi, id);
        BitConverter.GetBytes(on ? 1 : 0).CopyTo(p, 20); Pseudo.ToByteArray().CopyTo(p, 24); Encoding.Unicode.GetBytes("LockMonitor").CopyTo(p, 56);
        return DisplayConfigSetDeviceInfo(p);
    }
    public static byte[] State(int size, uint lo, int hi, uint id, out int rc) { byte[] p = Packet(-7, size, lo, hi, id); rc = DisplayConfigGetDeviceInfo(p); return p; }
    public static string Name2(uint lo, int hi, uint id) { byte[] p = Packet(2, 420, lo, hi, id); int rc = DisplayConfigGetDeviceInfo(p); if (rc != 0) return "error " + rc; string s = Encoding.Unicode.GetString(p, 164, 256); int z = s.IndexOf('\0'); s = z >= 0 ? s.Substring(0, z) : s; return s.Length == 0 ? "(empty)" : "ok"; }
    public static string Public12(uint lo, int hi, uint id) { byte[] p = Packet(12, 24, lo, hi, id); int rc = DisplayConfigGetDeviceInfo(p); return rc == 0 ? "flags " + BitConverter.ToUInt32(p, 20) : "error " + rc; }
    // target status in Windows' path lists: in the desktop's paths, in all paths, and whether Windows calls it available (connected)
    public static string Topology(uint lo, int hi, uint id) {
        string r = "";
        foreach (uint which in new uint[] { 2, 1 }) {
            uint np, nm; GetDisplayConfigBufferSizes(which, out np, out nm);
            byte[] paths = new byte[np * 72], modes = new byte[nm * 64];
            int rc = QueryDisplayConfig(which, ref np, paths, ref nm, modes, IntPtr.Zero);
            bool found = false, avail = false;
            for (int i = 0; i < np; i++) { int o = i * 72; if (BitConverter.ToUInt32(paths, o + 20) == lo && BitConverter.ToInt32(paths, o + 24) == hi && BitConverter.ToUInt32(paths, o + 28) == id) { found = true; if (BitConverter.ToInt32(paths, o + 60) != 0) avail = true; } }
            r += (which == 2 ? "in desktop paths: " : "; in all paths: ") + found + (which == 1 ? " (available: " + avail + ")" : "") + (rc != 0 ? " [query error " + rc + "]" : "");
        }
        return r;
    }
    // the last target that is or was connected: the highest target id among all paths with an available target
    public static bool Last(out uint lo, out int hi, out uint id) {
        lo = 0; hi = 0; id = 0; bool any = false;
        uint np, nm; GetDisplayConfigBufferSizes(1, out np, out nm);
        byte[] paths = new byte[np * 72], modes = new byte[nm * 64];
        QueryDisplayConfig(1, ref np, paths, ref nm, modes, IntPtr.Zero);
        for (int i = 0; i < np; i++) { int o = i * 72; if (BitConverter.ToInt32(paths, o + 60) == 0) continue; uint t = BitConverter.ToUInt32(paths, o + 28); if (!any || t > id) { any = true; lo = BitConverter.ToUInt32(paths, o + 20); hi = BitConverter.ToInt32(paths, o + 24); id = t; } }
        return any;
    }
}
'@
function Say($m) { Add-Content $Out ('{0:HH:mm:ss} {1}' -f (Get-Date), $m) }   # the log only: Snap must return nothing but its bytes
function Snap($what) { $rc = 0; $s = [Priv]::State($Size, $lo, $hi, $id, [ref]$rc); Say "$what -> type -7: $rc$(if ($rc -eq 0) { ', id ' + [Priv]::MonitorId($s) + (', dword 588: 0x{0:X}' -f [BitConverter]::ToUInt32($s, 588)) }); type 12: $([Priv]::Public12($lo, $hi, $id)); monitor path (type 2): $([Priv]::Name2($lo, $hi, $id)); $([Priv]::Topology($lo, $hi, $id)); screens: $([Windows.Forms.Screen]::AllScreens.Count)"; , $s }
# not "Diff": PowerShell 5.1 has that as an alias of Compare-Object, and aliases win over functions
function Changes($a, $b, $label) { $d = for ($i = 20; $i -lt $Size; $i++) { if ($a[$i] -ne $b[$i]) { '{0}:{1:X2}>{2:X2}' -f $i, $a[$i], $b[$i] } }; Say "$label changed bytes: $(if ($d) { $d -join ' ' } else { 'none' })" }
Add-Type -AssemblyName System.Windows.Forms
Remove-Item $Out -ErrorAction SilentlyContinue
$lo = [uint32]0; $hi = 0; $id = [uint32]0
$mem = 'C:\locktest\held-target.txt'
if ($Step -in 'give', 'state' -and (Test-Path $mem)) { $lo, $hi, $id, $Value = (Get-Content $mem).Split('|'); $lo = [uint32]$lo; $hi = [int]$hi; $id = [uint32]$id }
elseif (-not [Priv]::Last([ref]$lo, [ref]$hi, [ref]$id)) { Say 'no connected target'; Get-Content $Out; return }
if ($Step -ne 'cycle') {
    $s = Snap $Step
    $val = if ($Value -eq 'computed') { [Priv]::SettingsValue([Priv]::MonitorId($s)) } else { [UInt64]$Value }
    if ($Step -eq 'take') { Set-Content $mem "$lo|$hi|$id|$val"; Say "take target $id -> $([Priv]::SetPrivate($lo, $hi, $id, $true, $val))"; Start-Sleep 2; $null = Snap 'after take' }
    if ($Step -eq 'give') { Say "give target $id -> $([Priv]::SetPrivate($lo, $hi, $id, $false, $val))"; Start-Sleep 2; $null = Snap 'after give' }
    Get-Content $Out; return
}
$v = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$before = Snap 'before'
$val = if ($Value -eq 'computed') { [Priv]::SettingsValue([Priv]::MonitorId($before)) } else { [UInt64]$Value }
Say "$($v.EditionID) $($v.CurrentBuild).$($v.UBR); target $id on adapter ${hi}:$lo; request: $(if ($Public) { 'public type 13 (LockMonitor 0.2.5)' } else { "private type -23, value $val" })"
if ($StateOnly) { [IO.File]::WriteAllBytes(($Out -replace '\.txt$', '-now.bin'), $before); Get-Content $Out; return }
$rc = if ($Public) { [Priv]::SetPublic($lo, $hi, $id, $true) } else { [Priv]::SetPrivate($lo, $hi, $id, $true, $val) }
Say "take -> $rc"
Start-Sleep $Hold
$held = Snap 'held'
$rc = if ($Public) { [Priv]::SetPublic($lo, $hi, $id, $false) } else { [Priv]::SetPrivate($lo, $hi, $id, $false, $val) }
Say "give back -> $rc"
Start-Sleep 3
$after = Snap 'after'
Changes $before $held 'before->held'
Changes $held $after 'held->after'
[IO.File]::WriteAllBytes(($Out -replace '\.txt$', '-held.bin'), $held)
Get-Content $Out
