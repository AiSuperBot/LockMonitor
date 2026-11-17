<#
Lock probe for the test VM (run in the logged-on user's session, unelevated).
Question: does Chrome keep handing over fresh pictures of a page (DevTools screencast, the path Show-Dashboard.ps1 uses)
while the workstation is locked? Tested for headless Chrome and for a normal visible Chrome window.
It compiles the C# straight out of Show-Dashboard.ps1, so the probe exercises the product's real code.
Once per second it logs how many frames each browser delivered. The page changes every 100 ms.
  .\Probe-Screencast.ps1 -Seconds 120 -Chrome C:\Chrome\chrome.exe      log: C:\locktest\screencast.log
#>
param([int]$Seconds = 120, [Parameter(Mandatory)][string]$Chrome, [string]$Dir = 'C:\locktest', [string]$Dashboard)
$ErrorActionPreference = 'Stop'
if (-not $Dashboard) {   # next to this probe (as copied into the VM), else one folder up (as in the repo)
    $here = Split-Path $PSCommandPath
    $Dashboard = "$here\Show-Dashboard.ps1", "$here\..\Show-Dashboard.ps1" | Where-Object { Test-Path $_ } | Select-Object -First 1
}
$null = New-Item -ItemType Directory -Force $Dir
$Log = "$Dir\screencast.log"
Invoke-Expression ([regex]::Match((Get-Content $Dashboard -Raw), "(?s)Add-Type -ReferencedAssemblies.*?\n'@").Value)

$html = "$Dir\probe-screencast.html"
Set-Content $html '<title>probe-screencast</title><body style="font:60px sans-serif;background:navy;color:white"><div id=t></div><script>setInterval(()=>t.textContent=Date.now(),100)</script>'
$url = 'file:///' + ($html -replace '\\', '/')
$browsers = @()
try {
    foreach ($b in @(@{ n = 'headless'; show = $false }, @{ n = 'visible'; show = $true })) {
        $prof = "$Dir\prof-cast-$($b.n)"
        Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -like "*$prof*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        try { $browsers += [pscustomobject]@{ Name = $b.n; Cdp = (New-Object Cdp($Chrome, $prof, $url, 800, 480, $b.show)); Last = [long]0 } }
        catch { Add-Content $Log "$($b.n): could not start: $($_.Exception.Message)" }
    }
    Add-Content $Log ('{0:HH:mm:ss} start: {1}' -f (Get-Date), (($browsers | ForEach-Object Name) -join ','))
    $next = (Get-Date).AddSeconds(1)
    for ($end = (Get-Date).AddSeconds($Seconds); (Get-Date) -lt $end; Start-Sleep -Milliseconds 100) {
        foreach ($b in $browsers) { $null = $b.Cdp.NextJpeg(0) }   # take the frames at the monitor loop's pace: Chrome sends the next ones only then
        if ((Get-Date) -lt $next) { continue }
        $next = $next.AddSeconds(1)
        $row = '{0:HH:mm:ss} locked={1,-5}' -f (Get-Date), ([Pix]::SessionState() -eq 'LOCKED')
        foreach ($b in $browsers) { $f = $b.Cdp.Frames; $row += ' | {0}: frames={1,-3}' -f $b.Name, ($f - $b.Last); $b.Last = $f }
        Add-Content $Log $row
    }
} finally {
    foreach ($b in $browsers) { $b.Cdp.Dispose() }
    Add-Content $Log ('{0:HH:mm:ss} end' -f (Get-Date))
}
