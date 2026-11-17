<#
Dot-source this on the HOST to drive the throwaway test VM (VMware Workstation, D:\Virtual Machines\LockTest).
The VM has no network adapter. It exists so lock behaviour can be tested with real Win+L key presses and screenshots,
without locking the real PC.     . .\vmtest\Vm.ps1
#>
$VmWs  = 'C:\Program Files (x86)\VMware\VMware Workstation'
$VmDir = 'D:\Virtual Machines\LockTest'
$Vmx   = "$VmDir\LockTest.vmx"
$VmPw  = (Get-Content "$VmDir\guest-credentials.txt")[1]
$VmOut = "$VmDir\out"; $null = New-Item -ItemType Directory -Force $VmOut      # shared into the guest as \\vmware-host\Shared Folders\out

function Vm-Run {   # run a program in the guest. -User tester -Interactive = in the logged-on desktop session, unelevated
    param([Parameter(Mandatory)][string]$Exe, [string]$Arguments = '', [string]$User = 'tester', [switch]$Interactive, [switch]$NoWait)
    $a = @('-T', 'ws', '-gu', $User, '-gp', $VmPw, 'runProgramInGuest', $Vmx)
    if ($NoWait) { $a += '-noWait' }
    if ($Interactive) { $a += '-activeWindow', '-interactive' }
    $a += $Exe; if ($Arguments) { $a += $Arguments -split ' +' }   # one argv entry per word: as a single entry the guest program sees one quoted blob. So: no spaces inside an argument.
    $o = & "$VmWs\vmrun.exe" @a 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or $o -match '^Error') { "vmrun: $($o.Trim())" }
}
function Vm-PS {    # run a PowerShell script file that already exists in the guest
    param([Parameter(Mandatory)][string]$File, [string]$Arguments = '', [string]$User = 'tester', [switch]$Interactive, [switch]$NoWait)
    Vm-Run -Exe 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -Arguments "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $File $Arguments" -User $User -Interactive:$Interactive -NoWait:$NoWait
}
function Vm-Cmd {   # run one cmd.exe line in the guest; its output lands in the shared out folder as <name>.txt
    param([Parameter(Mandatory)][string]$Line, [string]$Name = 'cmd', [string]$User = 'tester', [switch]$Interactive)
    $bat = "$VmOut\$Name.cmd"
    Set-Content $bat "@echo off`r`n($Line) > C:\locktest\$Name.txt 2>&1`r`ncopy /y C:\locktest\$Name.txt `"\\vmware-host\Shared Folders\out\$Name.txt`" >nul" -Encoding ASCII
    Vm-CopyTo $bat "C:\locktest\$Name.cmd"
    Vm-Run -Exe 'C:\Windows\System32\cmd.exe' -Arguments "/c C:\locktest\$Name.cmd" -User $User -Interactive:$Interactive
    Get-Content "$VmOut\$Name.txt" -ErrorAction SilentlyContinue
}
function Vm-Elevated {   # run one cmd.exe line ELEVATED inside the logged-on desktop session (a scheduled task with highest privileges, created once)
    param([Parameter(Mandatory)][string]$Line, [string]$Name = 'elev', [int]$WaitSeconds = 15)
    if (-not $script:VmElevatedReady) {
        Vm-Run -Exe 'C:\Windows\System32\schtasks.exe' -Arguments '/create /tn LockTestElevated /tr C:\locktest\elevated.cmd /sc once /st 00:00 /sd 01/01/2030 /ru tester /rl highest /it /f' -User Administrator
        $script:VmElevatedReady = $true
    }
    Remove-Item "$VmOut\$Name.txt" -ErrorAction SilentlyContinue
    Set-Content "$VmOut\elevated.cmd" "@echo off`r`n($Line) > C:\locktest\$Name.txt 2>&1`r`ncopy /y C:\locktest\$Name.txt `"\\vmware-host\Shared Folders\out\$Name.txt`" >nul" -Encoding ASCII
    Vm-CopyTo "$VmOut\elevated.cmd" 'C:\locktest\elevated.cmd'
    Vm-Run -Exe 'C:\Windows\System32\schtasks.exe' -Arguments '/run /tn LockTestElevated' -User Administrator
    for ($i = 0; $i -lt $WaitSeconds * 2 -and -not (Test-Path "$VmOut\$Name.txt"); $i++) { Start-Sleep -Milliseconds 500 }
    Start-Sleep 1; Get-Content "$VmOut\$Name.txt" -ErrorAction SilentlyContinue
}
function Vm-CopyTo($HostPath, $GuestPath, $User = 'tester') { $o = & "$VmWs\vmrun.exe" -T ws -gu $User -gp $VmPw copyFileFromHostToGuest $Vmx $HostPath $GuestPath 2>&1 | Out-String; if ($o.Trim()) { "copyTo: $($o.Trim())" } }
function Vm-CopyFrom($GuestPath, $HostPath, $User = 'tester') { $o = & "$VmWs\vmrun.exe" -T ws -gu $User -gp $VmPw copyFileFromGuestToHost $Vmx $GuestPath $HostPath 2>&1 | Out-String; if ($o.Trim()) { "copyFrom: $($o.Trim())" } }
function Vm-Shot($Name) { $f = "$VmOut\$Name.png"; & "$VmWs\vmcli.exe" $Vmx MKS captureScreenshot $f 2>&1 | Out-Null; $f }
# One real key press. $Usage = USB HID keyboard usage id (Enter 0x28, Esc 0x29, Backspace 0x2A, Tab 0x2B, Space 0x2C, L 0x0F, Y 0x1C).
# vmcli wants it as (usage << 16) | 7; found by experiment, its help does not say.
function Vm-Key([int]$Usage, [int]$Modifier = 0) { & "$VmWs\vmcli.exe" $Vmx MKS sendKeyEvent (($Usage -shl 16) -bor 7) $Modifier 2>&1 | Out-String }
function Vm-Line($Text) { Vm-Type $Text | Out-Null; Start-Sleep -Milliseconds 400; Vm-Key 0x28 | Out-Null }   # type a line and press Enter
function Vm-Type($Text) { & "$VmWs\vmcli.exe" $Vmx MKS sendKeySequence ($Text -replace '"', '\"') 2>&1 | Out-String }   # \" : PowerShell 5.1 does not escape quotes for native programs
# Real mouse movement and clicks, sent through VMware's built-in VNC server like a physical pointing device. Needs these
# lines in the vmx while the VM is off (and removed again afterwards): RemoteDisplay.vnc.enabled = "TRUE",
# RemoteDisplay.vnc.port = "5999", RemoteDisplay.vnc.ip = "127.0.0.1" (this PC only). Coordinates are guest screen pixels.
function Vm-Mouse {
    param([Parameter(Mandatory)][int[]]$X, [Parameter(Mandatory)][int[]]$Y, [switch]$Click, [int]$Port = 5999)
    $c = New-Object Net.Sockets.TcpClient('127.0.0.1', $Port); $s = $c.GetStream(); $s.ReadTimeout = 5000
    $rd = { param($n) $b = New-Object byte[] $n; $o = 0; while ($o -lt $n) { $r = $s.Read($b, $o, $n - $o); if ($r -le 0) { throw 'VNC closed the connection' }; $o += $r }; , $b }
    try {
        $ver = [Text.Encoding]::ASCII.GetString((& $rd 12)); $s.Write([Text.Encoding]::ASCII.GetBytes("RFB 003.008`n"), 0, 12)
        $n = (& $rd 1)[0]; if ($n -eq 0) { throw 'VNC refused the connection' }
        $types = & $rd $n; if ($types -notcontains 1) { throw "VNC wants authentication (security types $($types -join ','))" }
        $s.Write([byte[]]@(1), 0, 1); if (((& $rd 4) | Measure-Object -Sum).Sum -ne 0) { throw 'VNC security handshake failed' }
        $s.Write([byte[]]@(1), 0, 1)   # ClientInit: shared
        $init = & $rd 24; $w = $init[0] * 256 + $init[1]; $h = $init[2] * 256 + $init[3]; $null = & $rd ($init[20] * 16777216 + $init[21] * 65536 + $init[22] * 256 + $init[23])
        $ptr = { param($x, $y, $m) $s.Write([byte[]]@(5, $m, ($x -shr 8), ($x -band 255), ($y -shr 8), ($y -band 255)), 0, 6); $s.Flush(); Start-Sleep -Milliseconds 150 }
        for ($i = 0; $i -lt $X.Count; $i++) { & $ptr $X[$i] $Y[$i] 0 }
        if ($Click) { & $ptr $X[-1] $Y[-1] 1; & $ptr $X[-1] $Y[-1] 0 }
        "VNC $($ver.Trim()), guest picture ${w}x${h}: sent $($X.Count) pointer move(s)$(if ($Click) { ' and one click' })"
    } finally { $c.Close() }
}
function Vm-Tools { (& "$VmWs\vmrun.exe" -T ws checkToolsState $Vmx 2>&1 | Out-String).Trim() }
