<#
Test-VM helper: walk the Windows.Devices.Display.Core steps one at a time on the specialized display and print what
each returns, so a failure can be pinned to one call (Show-Dashboard.ps1 does the same calls in one go).
#>
$ErrorActionPreference = 'Continue'
$null = [Windows.Devices.Display.Core.DisplayManager, Windows.Devices.Display.Core, ContentType=WindowsRuntime]
$null = [Windows.Graphics.DirectX.DirectXColorSpace, Windows.Graphics.DirectX, ContentType=WindowsRuntime]
$null = [Windows.Graphics.DirectX.Direct3D11.Direct3DMultisampleDescription, Windows.Graphics.DirectX.Direct3D11, ContentType=WindowsRuntime]
function Step($name, [scriptblock]$b) { try { $r = & $b; "OK    $name" + $(if ($null -ne $r -and $r -isnot [array] -and "$r" -notmatch '^(Windows|System)\.') { " -> $r" }); , $r } catch { "FAIL  $name -> " + $_.Exception.Message.Trim() + $(if ($_.Exception.InnerException) { ' / 0x{0:X8}' -f $_.Exception.InnerException.HResult }); , $null } }

foreach ($opt in 'None', 'EnforceSourceOwnership') {
    "=== DisplayManagerOptions.$opt ==="
    $dm = [Windows.Devices.Display.Core.DisplayManager]::Create($opt)
    $t = $dm.GetCurrentTargets() | Where-Object { $_.IsConnected -and $_.UsageKind -ne 'Standard' } | Select-Object -First 1
    if (-not $t) { 'no specialized display'; $dm.Dispose(); continue }
    "target $($t.StableMonitorId) usage=$($t.UsageKind) adapter source count=$($t.Adapter.SourceCount) properties=$($t.Adapter.Properties.Count)"
    $list = New-Object 'System.Collections.Generic.List[Windows.Devices.Display.Core.DisplayTarget]'; $list.Add($t)
    $r = $dm.TryAcquireTargetsAndCreateEmptyState($list); "acquire: $($r.ErrorCode)"
    $state = $r.State
    $path = $state.ConnectTarget($t)
    $path.IsInterlaced = $false; $path.Scaling = 'Identity'; $path.SourcePixelFormat = 'B8G8R8A8UIntNormalized'
    $modes = @($path.FindModes('OnlyPreferredResolution')); "modes at preferred resolution: $($modes.Count); all: $(@($path.FindModes('None')).Count)"
    $m = $modes | Select-Object -First 1
    if (-not $m) { $m = @($path.FindModes('None')) | Select-Object -First 1 }
    $v = $m.PresentationRate.VerticalSyncRate
    "mode: source $($m.SourceResolution.Width)x$($m.SourceResolution.Height) target $($m.TargetResolution.Width)x$($m.TargetResolution.Height) vsync $($v.Numerator)/$($v.Denominator) fmt=$($m.SourcePixelFormat) stereo=$($m.IsStereo) wire=$($m.GetWireFormatSupportedBitsPerChannel('Rgb444'))"
    $path.ApplyPropertiesFromMode($m)
    $a = $state.TryApply('None'); "apply: $($a.Status) $($a.ExtendedErrorCode.Message)"
    $r2 = $dm.TryAcquireTargetsAndReadCurrentState($list); "re-read: $($r2.ErrorCode)"
    $p2 = $r2.State.GetPathForTarget($t)
    "applied path: status=$($p2.Status) source=$($p2.SourceResolution.Width)x$($p2.SourceResolution.Height) fmt=$($p2.SourcePixelFormat) scaling=$($p2.Scaling) view paths=$($p2.View.Paths.Count)"
    $dev = $null
    $x = Step 'CreateDisplayDevice' { $script:dev = $dm.CreateDisplayDevice($t.Adapter); 'device' }; $x[0]
    if ($dev) {
        $x = Step 'IsCapabilitySupported(FlipOverride)' { $dev.IsCapabilitySupported('FlipOverride') }; $x[0]
        $src = $null
        $x = Step 'CreateScanoutSource' { $script:src = $dev.CreateScanoutSource($t); "source id $($script:src.SourceId) status $($script:src.Status)" }; $x[0]
        $ms = New-Object Windows.Graphics.DirectX.Direct3D11.Direct3DMultisampleDescription; $ms.Count = 1
        $desc = [Windows.Devices.Display.Core.DisplayPrimaryDescription]::new([uint32]$p2.SourceResolution.Width, [uint32]$p2.SourceResolution.Height, $p2.SourcePixelFormat, [Windows.Graphics.DirectX.DirectXColorSpace]::RgbFullG22NoneP709, $false, $ms)
        $surf = $null
        $x = Step 'CreatePrimary' { $script:surf = $dev.CreatePrimary($t, $desc); 'surface' }; $x[0]
        if ($src -and $surf) {
            $x = Step 'CreateSimpleScanout' { $script:scan = $dev.CreateSimpleScanout($src, $surf, 0, 1); 'scanout' }; $x[0]
            $x = Step 'ExecuteTask' { $pool = $dev.CreateTaskPool(); $task = $pool.CreateTask(); $task.SetScanout($script:scan); $pool.ExecuteTask($task); 'presented' }; $x[0]
            $x = Step 'WaitForVBlank' { $dev.WaitForVBlank($src); 'vblank' }; $x[0]
        }
    }
    $dm.Dispose()
    Start-Sleep 1
}
