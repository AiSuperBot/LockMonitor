<# Test-VM helper: keep a file open exclusively for a while, so that nobody else can write to it (e.g. the agent's log), to see that the agent survives that. #>
param([Parameter(Mandatory)][string]$Path, [int]$Seconds = 12)
$fs = [IO.File]::Open($Path, 'Open', 'ReadWrite', 'None')
try { Start-Sleep $Seconds } finally { $fs.Close() }
