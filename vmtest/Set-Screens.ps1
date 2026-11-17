<#
Test-VM helper: after a delay, ask VMware for a guest display layout: 1 = one screen (the second is "unplugged"),
2 = two screens, 3 = three (the third 1024x768). VMware refuses desktop-session commands while the guest is locked,
so start this before the lock (-After) to have it act during the lock.
#>
param([int]$After = 0, [int]$Screens = 2)
Start-Sleep $After
# one screen is asked for in another size than usual: asked for the layout the desktop already has (the second screen being off the desktop), the tool does nothing
$layout = switch ($Screens) { 1 { '0 1 , 0 0 1024 768' } 3 { '0 3 , 0 0 1280 800 , 1280 0 1280 800 , 2560 0 1024 768' } default { '0 2 , 0 0 1280 800 , 1280 0 1280 800' } }
& 'C:\Program Files\VMware\VMware Tools\VMwareResolutionSet.exe' ($layout -split ' ') | Out-Null
Add-Content C:\locktest\screens.log ('{0:HH:mm:ss} asked VMware for {1} screen(s), exit code {2}' -f (Get-Date), $Screens, $LASTEXITCODE)
