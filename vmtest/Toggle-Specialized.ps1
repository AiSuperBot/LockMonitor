<#
Test-VM helper (logged-on session, unelevated): flip Windows' own Settings switch "Remove display from desktop" for
display -Display (its number in Settings), through UI Automation, the way a person clicks through Settings: Display page,
pick the display, "Advanced display" (Windows 11) / "Advanced display settings" (Windows 10), the switch.
-List stops on the advanced page and lists what it shows. Settings asks for elevation: in the test VM, UAC is set to
elevate without asking while this is used. Log: -Out
#>
param([int]$Display = 2, [switch]$List, [string]$Out = 'C:\locktest\toggle.txt')
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms
$AE = [Windows.Automation.AutomationElement]; $Scope = [Windows.Automation.TreeScope]; $CT = [Windows.Automation.ControlType]
function Say($m) { Add-Content $Out ('{0:HH:mm:ss} {1}' -f (Get-Date), $m) }
function All { $win.FindAll($Scope::Descendants, [Windows.Automation.Condition]::TrueCondition) }
function Find($test) { for ($i = 0; $i -lt 20; $i++) { $e = All | Where-Object $test | Select-Object -First 1; if ($e) { return $e }; Start-Sleep -Milliseconds 500 } }
Remove-Item $Out -ErrorAction SilentlyContinue
Start-Process 'ms-settings:display'
$win = $null
for ($i = 0; $i -lt 30 -and -not $win; $i++) { Start-Sleep -Milliseconds 500; $win = $AE::RootElement.FindFirst($Scope::Children, (New-Object Windows.Automation.PropertyCondition($AE::NameProperty, 'Settings'))) }
if (-not $win) { Say 'no Settings window'; return }
$tile = Find { $_.Current.AutomationId -eq "Display$Display" -or ($_.Current.ControlType -eq $CT::ListItem -and $_.Current.Name -match "^Display $Display\b") }
if ($tile) { try { $tile.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select() } catch { $tile.SetFocus() }; Start-Sleep 2; Say "picked $($tile.Current.Name)" } else { Say "no tile for display $Display" }
$adv = Find { $_.Current.Name -match '^Advanced display( settings)?$' -and ($_.Current.ControlType -eq $CT::Button -or $_.Current.ControlType -eq $CT::Hyperlink) }
if (-not $adv) { Say 'no link to the advanced display page'; return }
$adv.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke(); Start-Sleep 3
Say "opened $($adv.Current.Name)"
# the advanced page has its own list of displays
$combo = Find { $_.Current.ControlType -eq $CT::ComboBox }
if ($combo) {
    $combo.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand(); Start-Sleep 1
    $item = $combo.FindAll($Scope::Descendants, [Windows.Automation.Condition]::TrueCondition) | Where-Object { $_.Current.ControlType -eq $CT::ListItem -and $_.Current.Name -match "Display $Display\b" } | Select-Object -First 1
    if ($item) { $item.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select(); Start-Sleep 2; Say "chose $($item.Current.Name)" }
    else { try { $combo.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Collapse() } catch { } }
}
if ($List) {
    foreach ($e in All) { $c = $e.Current; if ($c.Name -or $c.AutomationId) { Say ('{0} | {1} | id {2} | enabled {3}' -f $c.ControlType.ProgrammaticName, $c.Name, $c.AutomationId, $c.IsEnabled) } }
    return
}
$toggle = Find { $_.Current.AutomationId -match 'MonitorSpecialization_ToggleSwitch' -or ($_.Current.Name -match 'Remove display from desktop' -and $_.GetSupportedPatterns() -contains [Windows.Automation.TogglePattern]::Pattern) }
if (-not $toggle) { Say 'no "Remove display from desktop" switch on the page'; return }
$t = $toggle.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
Say "switch before: $($t.Current.ToggleState), enabled $($toggle.Current.IsEnabled); screens: $([Windows.Forms.Screen]::AllScreens.Count)"
$t.Toggle(); Start-Sleep 6
$state = try { $t.Current.ToggleState } catch { 'gone (the page was rebuilt)' }
Say "switch after: $state; screens: $([Windows.Forms.Screen]::AllScreens.Count)"
