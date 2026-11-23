<#
Test-VM helper (logged-on session): after -After seconds (let the displays time out first), try one way of switching
the displays back on without any input, and hold it for -Hold seconds; the moments go to C:\locktest\wake.log.
  a  SetThreadExecutionState(ES_DISPLAY_REQUIRED), once, without ES_CONTINUOUS
  b  SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED), as the agent holds it
  c  PowerCreateRequest + PowerSetRequest(PowerRequestDisplayRequired)
  d  WM_SYSCOMMAND SC_MONITORPOWER -1 (on) to a window of its own
#>
param([ValidateSet('a', 'b', 'c', 'd')][string]$Method = 'a', [int]$After = 90, [int]$Hold = 20)
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class Wake {
    [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct REASON { public uint Version, Flags; public string Text; }
    [DllImport("kernel32.dll")] public static extern IntPtr PowerCreateRequest(ref REASON r);
    [DllImport("kernel32.dll")] public static extern bool PowerSetRequest(IntPtr h, int type);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
}
'@
Add-Type -AssemblyName System.Windows.Forms
Start-Sleep $After
Add-Content C:\locktest\wake.log ('{0:HH:mm:ss.fff} method {1}' -f (Get-Date), $Method)
switch ($Method) {
    'a' { $r = [Wake]::SetThreadExecutionState(0x2) }
    'b' { $r = [Wake]::SetThreadExecutionState(0x80000003) }
    'c' { $why = New-Object Wake+REASON; $why.Version = 0; $why.Flags = 1; $why.Text = 'test'; $h = [Wake]::PowerCreateRequest([ref]$why); $r = [Wake]::PowerSetRequest($h, 0) }
    'd' { $f = New-Object Windows.Forms.Form; $r = [Wake]::SendMessage($f.Handle, 0x112, [IntPtr]0xF170, [IntPtr](-1)) }
}
Add-Content C:\locktest\wake.log ('{0:HH:mm:ss.fff} method {1} returned {2}' -f (Get-Date), $Method, $r)
Start-Sleep $Hold
