<#
Lock probe for the test VM (run in the logged-on user's session, unelevated).
Uses Show-Dashboard.ps1's own window-mirror call (Pix.CaptureWindow) on an ordinary Chrome window that shows a running
clock, every 3 s, and saves each picture as a PNG named with the lock state. Looking at the PNGs taken while locked
shows what the dedicated monitor would be given. Also logs whether a held specialized display stays owned.
  .\Probe-Frames.ps1 -Seconds 90 -Chrome C:\Chrome\chrome.exe -Out "\\vmware-host\Shared Folders\out\frames"
#>
param([int]$Seconds = 90, [Parameter(Mandatory)][string]$Chrome, [string]$Out = 'C:\locktest\frames', [string]$Dir = 'C:\locktest', [string]$Dashboard)
$ErrorActionPreference = 'Stop'
if (-not $Dashboard) { $here = Split-Path $PSCommandPath; $Dashboard = "$here\Show-Dashboard.ps1", "$here\..\Show-Dashboard.ps1" | Where-Object { Test-Path $_ } | Select-Object -First 1 }
Invoke-Expression ([regex]::Match((Get-Content $Dashboard -Raw), "(?s)Add-Type -ReferencedAssemblies.*?\n'@").Value)
$null = New-Item -ItemType Directory -Force $Out
$Log = "$Dir\frames.log"

# an ordinary Chrome window with default settings, like a user's own
$html = "$Dir\probe-frames.html"
Set-Content $html '<title>probe-frames</title><body style="font:48px sans-serif;background:#102040;color:white;margin:30px"><div>live window</div><div id=t></div><div id=n></div><script>let n=0;setInterval(()=>{t.textContent=new Date().toLocaleTimeString();n.textContent="tick "+(++n)},200)</script>'
$prof = "$Dir\prof-frames"
Start-Process $Chrome -ArgumentList "--user-data-dir=`"$prof`" --no-first-run --no-default-browser-check --disable-sync --disable-background-networking --new-window --window-size=700,420 --window-position=60,120 `"file:///$($html -replace '\\','/')`""

# hold the specialized display the way Show-Dashboard does (up to the mode set), to see if the lock takes it away
$null = [Windows.Devices.Display.Core.DisplayManager, Windows.Devices.Display.Core, ContentType=WindowsRuntime]
$dm = [Windows.Devices.Display.Core.DisplayManager]::Create('None')
$t = $dm.GetCurrentTargets() | Where-Object { $_.IsConnected -and $_.UsageKind -ne 'Standard' } | Select-Object -First 1
$own = 'no specialized display'
if ($t) {
    $list = New-Object 'System.Collections.Generic.List[Windows.Devices.Display.Core.DisplayTarget]'; $list.Add($t)
    $r = $dm.TryAcquireTargetsAndCreateEmptyState($list); $path = $r.State.ConnectTarget($t)
    $path.IsInterlaced = $false; $path.Scaling = 'Identity'; $path.SourcePixelFormat = 'B8G8R8A8UIntNormalized'
    $path.ApplyPropertiesFromMode((@($path.FindModes('OnlyPreferredResolution')) | Select-Object -First 1))
    $own = "acquire=$($r.ErrorCode) apply=$($r.State.TryApply('None').Status)"
}
Add-Content $Log ('{0:HH:mm:ss} start: display {1}' -f (Get-Date), $own)

try {
    $bmp = New-Object Frame(960, 540)
    $hwnd = [IntPtr]::Zero; $i = 0
    for ($end = (Get-Date).AddSeconds($Seconds); (Get-Date) -lt $end; Start-Sleep 3) {
        if ($hwnd -eq [IntPtr]::Zero) { $hwnd = [Pix]::FindWindow('probe-frames') }
        $st = if ($hwnd -eq [IntPtr]::Zero) { 'gone' } else { [Pix]::CaptureWindow($hwnd, $bmp) }
        $state = [Pix]::SessionState(); $i++
        if ($st -eq 'ok') { $bmp.Gdi.Save(('{0}\frame-{1:00}-{2}.png' -f $Out, $i, $state), [System.Drawing.Imaging.ImageFormat]::Png) }
        $held = if ($t) { $rr = $dm.TryAcquireTargetsAndReadCurrentState($list); "owned=$($rr.ErrorCode) path=$([bool]$rr.State.GetPathForTarget($t)) stale=$($t.IsStale)" } else { '' }
        Add-Content $Log ('{0:HH:mm:ss} frame {1:00} session={2,-8} capture={3,-9} display: {4}' -f (Get-Date), $i, $state, $st, $held)
    }
} finally {
    $dm.Dispose()
    Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -like "*$prof*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Add-Content $Log ('{0:HH:mm:ss} end' -f (Get-Date))
}
