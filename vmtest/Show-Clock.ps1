<#
Test-VM helper: a classic (GDI) window with a running clock, placed where asked, as something to keep showing.
-ClickThrough makes it a click-through overlay (WS_EX_TRANSPARENT), the kind -Auto must leave out of its note.
#>
param([int]$Left = 1400, [int]$Top = 120, [int]$Width = 420, [int]$Height = 260, [string]$Title = 'classic-clock', [string]$Color = 'DarkGreen', [switch]$ClickThrough, [int]$Seconds = 900)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
public class ClockForm : System.Windows.Forms.Form {
    public bool ClickThrough;
    protected override System.Windows.Forms.CreateParams CreateParams { get { System.Windows.Forms.CreateParams p = base.CreateParams; if (ClickThrough) p.ExStyle |= 0x20; return p; } }
}
'@
$f = New-Object ClockForm -Property @{ ClickThrough = [bool]$ClickThrough; Text = $Title; StartPosition = 'Manual'; Left = $Left; Top = $Top; Width = $Width; Height = $Height; BackColor = [Drawing.Color]::FromName($Color) }
$l = New-Object Windows.Forms.Label -Property @{ Dock = 'Fill'; ForeColor = 'White'; Font = (New-Object Drawing.Font('Segoe UI', 36)); TextAlign = 'MiddleCenter' }
$f.Controls.Add($l)
$end = (Get-Date).AddSeconds($Seconds)
$t = New-Object Windows.Forms.Timer -Property @{ Interval = 200 }
$t.add_Tick({ $l.Text = (Get-Date).ToString('HH:mm:ss'); if ((Get-Date) -gt $end) { $f.Close() } })
$t.Start(); [Windows.Forms.Application]::Run($f)
