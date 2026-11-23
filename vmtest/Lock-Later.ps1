<#
Test-VM helper (logged-on session): after -After seconds, lock the PC the way an automatic lock does, with no key
pressed (a key press would also switch the screens back on); the moment goes to C:\locktest\lock-later.log. Pair it
with a short display-off timeout (powercfg /change monitor-timeout-ac 1) to see a lock that comes while the screens are
already dark.
#>
param([int]$After = 100)
Start-Sleep $After
Add-Content C:\locktest\lock-later.log ('{0:HH:mm:ss.fff} locking' -f (Get-Date))
& "$env:SystemRoot\System32\rundll32.exe" user32.dll,LockWorkStation
