<#
Test-VM helper (logged-on session): after -After seconds, put the PC to sleep, as it does by itself when idle; the
moments go to C:\locktest\sleep.log. Start it before a lock to have the PC sleep while locked (commands cannot be
started while locked). Wake the VM with a key press (Vm-Key). The test VMs offer standby S1 only (powercfg /a).
#>
param([int]$After = 0)
Start-Sleep $After
Add-Type -AssemblyName System.Windows.Forms
Add-Content C:\locktest\sleep.log ('{0:HH:mm:ss.fff} going to sleep' -f (Get-Date))
$ok = [Windows.Forms.Application]::SetSuspendState('Suspend', $false, $false)
Add-Content C:\locktest\sleep.log ('{0:HH:mm:ss.fff} back (asked: {1})' -f (Get-Date), $ok)
