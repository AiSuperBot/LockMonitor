<#
Test-VM helper: the running agent's memory and handles every -Every seconds for -Seconds, one line each in -Log:
private and working-set MB, handles, GDI and USER objects. Start it before a series of locks to see whether anything
grows from lock to lock (a leak), and what a lock costs in memory.
#>
param([int]$Seconds = 300, [int]$Every = 5, [string]$Log = 'C:\locktest\agent-watch.log')
Add-Type 'using System; using System.Runtime.InteropServices; public static class Gui { [DllImport("user32.dll")] public static extern int GetGuiResources(IntPtr h, int flags); }'
for ($end = (Get-Date).AddSeconds($Seconds); (Get-Date) -lt $end; Start-Sleep $Every) {
    $p = Get-Process LockMonitor-Agent -ErrorAction SilentlyContinue | Select-Object -First 1
    $row = if (-not $p) { 'no agent' } else {
        'private {0:N1} MB, working set {1:N1} MB, handles {2}, GDI {3}, USER {4}' -f ($p.PrivateMemorySize64 / 1MB), ($p.WorkingSet64 / 1MB), $p.HandleCount, [Gui]::GetGuiResources($p.Handle, 0), [Gui]::GetGuiResources($p.Handle, 1)
    }
    Add-Content $Log ('{0:HH:mm:ss} {1}' -f (Get-Date), $row)
}
