<#
Builds LockMonitor's two programs from the sources next to this script:
  Agent.cs + Common.cs              -> LockMonitor-Agent.exe   the agent, runs with normal rights
  Switch-LastScreen.cs + Common.cs  -> Switch-LastScreen.exe   the helper, started elevated at lock and unlock
It needs nothing but Windows: the C# compiler of .NET Framework 4.8, which is part of Windows 10 and 11, and Windows'
own description of its display interface (System32\WinMetadata). No Visual Studio, SDK or download.
Optimized release builds (/optimize+), for any CPU (64-bit on 64-bit Windows), without a console window, with
high-entropy ASLR (/highentropyva+: the compiler leaves it off by default, and the helper runs elevated).

  .\Build.ps1                  writes both to .\bin, and prints version, size and SHA256 of each
  .\Build.ps1 -Out <folder>
Install-Auto.ps1 runs this itself when it is started from the source code.
#>
param([string]$Out)
$ErrorActionPreference = 'Stop'
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { throw 'Run this from the normal PowerShell, not the "(x86)" one.' }
if (-not $Out) { $Out = "$PSScriptRoot\bin" }   # set here, not as the parameter's default: under -File that default cannot see the script's folder
# csc.exe and the facade assemblies of .NET Framework 4.8; named outright, so that this also works from PowerShell 7,
# which runs on another .NET
$fw = "$env:WINDIR\Microsoft.NET\Framework$(if ([Environment]::Is64BitOperatingSystem) { '64' })\v4.0.30319"
$md = [Environment]::GetFolderPath('System') + '\WinMetadata'
$null = New-Item -ItemType Directory -Force $Out
$winrt = @('Windows.Devices', 'Windows.Graphics', 'Windows.Foundation' | ForEach-Object { "/r:$md\$_.winmd" }) +
         @('System.Runtime', 'System.Runtime.WindowsRuntime', 'System.Runtime.InteropServices.WindowsRuntime' | ForEach-Object { "/r:$fw\$_.dll" })
# /unsafe for the agent only: it reads its picture's memory directly (Frame.Changed)
foreach ($b in @(@{ Src = 'Switch-LastScreen.cs'; Exe = 'Switch-LastScreen.exe'; More = @() }, @{ Src = 'Agent.cs'; Exe = 'LockMonitor-Agent.exe'; More = $winrt + '/unsafe' })) {
    $said = & "$fw\csc.exe" /nologo /target:winexe /optimize+ /highentropyva+ "/out:$Out\$($b.Exe)" $b.More "$PSScriptRoot\$($b.Src)" "$PSScriptRoot\Common.cs"
    if ($LASTEXITCODE) { throw "Could not build $($b.Src) with $fw\csc.exe:`n$($said | Out-String)" }
    $f = Get-Item "$Out\$($b.Exe)"
    '{0}  version {1}  {2:N0} bytes  SHA256 {3}' -f $f.FullName, $f.VersionInfo.FileVersion, $f.Length, (Get-FileHash $f.FullName -Algorithm SHA256).Hash
}
