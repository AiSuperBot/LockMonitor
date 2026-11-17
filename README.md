# LockMonitor

Press **Win+L** and one monitor keeps showing its windows, live, while Windows is locked. The other monitors show the normal Windows lock screen.

The lock is the genuine Windows lock. No Windows file is patched, Win+L is not intercepted, there is no imitation lock screen, and signing in works exactly as before. The kept monitor shows pictures only: it has no cursor, no keyboard focus and takes no input.

**Status: pre-release.** The whole flow has been tested in a virtual machine with real Win+L presses and real password unlocks, on two and three screens. One step is not confirmed on real hardware yet: putting the picture onto a real monitor through a real graphics card. The VM's virtual graphics driver cannot do that step, so there the pictures were written to files. The first real attempts (a laptop with a TV on HDMI) ended before that step: the PC was unlocked again two seconds after Win+L. Details under [Tested and not tested](#tested-and-not-tested).

## Requirements

- Windows 10 version 2004 or later, or Windows 11, in the Enterprise, Pro for Workstations or IoT Enterprise edition. Only these have the "Remove display from desktop" switch this relies on.
- At least two monitors and a current display driver (WDDM 2.x).
- An administrator account for the one-time setup. The usual kind with UAC prompts is fine.
- Windows PowerShell 5.1, which is part of Windows. Nothing else is installed.

To check a PC without changing anything:

```powershell
powershell -ExecutionPolicy Bypass -File .\Show-Dashboard.ps1 -SelfTest
powershell -ExecutionPolicy Bypass -File .\Show-Dashboard.ps1 -Info
```

## Setup

From an elevated PowerShell, in the folder with these files:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-Auto.ps1
```

Then sign out and back in once, and restart Chrome and Edge once. After that, just press Win+L.

To update, download the newer release and run the same command again; no sign-out is needed for that.

To undo everything, including the two settings it changed:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-Auto.ps1 -Remove
```

## Which monitor

The highest-numbered screen (`\\.\DISPLAYn`) at the first Win+L after setup, and from then on only that very monitor. If it is switched off or unplugged when you lock, nothing stays on: the next screen in line never takes its place. After changing monitors, run the setup again.

After setup, this shows which screen it would be, without changing anything:

```powershell
& "$env:ProgramFiles\LockMonitor\Switch-LastScreen.exe" -list | more
```

## What happens at Win+L

1. Windows locks. Its own "workstation locked" event starts `Switch-LastScreen.exe -take` (elevated), which takes the monitor off the Windows desktop with the switch behind Settings > System > Display > Advanced display > "Remove display from desktop".
2. `Show-Dashboard.ps1 -Auto` (not elevated, waiting since sign-in) redraws on that monitor, live, the windows that were on it.
3. At unlock, Windows' "unlocked" event starts `Switch-LastScreen.exe -give`: the monitor is a desktop screen again and Windows moves the windows back.

## What the setup changes

- Two files in `%ProgramFiles%\LockMonitor`: `Show-Dashboard.ps1`, and `Switch-LastScreen.exe`, built on the spot from `Switch-LastScreen.cs` with the C# compiler that is part of Windows.
- Three scheduled tasks for your account: `LockMonitor-Agent`, `LockMonitor-Take`, `LockMonitor-Give`.
- The Windows setting "Minimize windows when a monitor is disconnected" is turned off for your account. With it on, Windows minimizes the windows of the monitor that leaves the desktop and there is nothing left to show.
- The Chrome and Edge policy `WindowOcclusionEnabled` is set to 0. These browsers stop drawing when the PC is locked, and this policy is their own switch for that. They will then say "managed by your organization". `-LeaveBrowsers` skips this.

`-Remove` puts both settings back to what they were.

## Good to know

- At Win+L the kept monitor goes blank first. In the test VM the picture came about 3 seconds after Win+L; a TV also has to find its signal again. Leave it locked for at least 15 seconds before judging.
- While locked, the PC is kept awake and the displays are kept on. Windows has one display-power switch for all monitors, so the other monitors stay lit, showing the lock screen.
- Apps must keep drawing while the PC is locked. Classic apps do. Chrome and Edge do with the policy above. Apps built on Electron may freeze; there is no switch for them from outside.
- The picture is refreshed up to four times a second while it changes, and once a second while it is still.
- If none of the screen's windows can be drawn, the screen says why instead of staying black.
- Logs: `%LOCALAPPDATA%\LockMonitor\log.txt` and `%ProgramFiles%\LockMonitor\switch.log`. For every lock they say what was noted, which screen was taken, how many pictures were shown, how the lock ended, and anything that went wrong.

## Tested and not tested

Tested in a VMware guest (Windows 11 Enterprise LTSC 2024), with real key presses and the real password:

- lock, live redraw at the screen's own resolution, unlock, windows back at their exact places
- two and three screens, and the kept screen being the primary display
- mouse and keyboard on the lock screen while the monitor is kept
- three lock and unlock cycles as fast as the keys can be typed
- the kept monitor unplugged during a lock, and a restart while locked: the monitor returns to the desktop by itself
- the kept monitor missing at Win+L: nothing stays on
- update and uninstall while it is running; uninstall restores every setting
- on a PC where Windows Terminal is the console host: nothing of it shows a window

Not tested:

- the picture on real hardware (see Status)
- a PC with two graphics adapters, monitors with different scaling, sleep and resume while locked, Electron apps
- whether the number Windows Settings shows for a monitor equals its `\\.\DISPLAYn` number on your PC (the `-list` command above shows the choice)

## Other files

- `Show-Dashboard.ps1` can also drive a monitor that is permanently off the desktop (`-Window`, `-Url`, `-Pattern`); see the top of the file.
- `Set-LockMonitor.ps1` and `Install-Tasks.ps1` are a fallback for other Windows editions: they switch a monitor's input over DDC/CI to a second video source.
- `Test-Locked.ps1` logs the lock state once a second.
- `vmtest\` is the harness used for the tests above. Its paths are those of the original test machine.
