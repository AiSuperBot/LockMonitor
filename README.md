# LockMonitor

Press **Win+L** and one monitor keeps showing its windows, live, while Windows is locked. The other monitors show the normal Windows lock screen.

The lock is the genuine Windows lock. No Windows file is patched, Win+L is not intercepted, there is no imitation lock screen, and signing in works exactly as before. The kept monitor shows pictures only: it has no pointer, no keyboard focus and takes no input.

**Status: pre-release.** It works on real hardware: version 0.1.2 was run on a laptop with a TV on HDMI (Intel Iris Xe, Windows 11 Enterprise). Since version 0.2.0 the background program is a small compiled one that makes the same display calls; it has been through all the tests below in a virtual machine, and the setup tests it live on your PC.

## Requirements

- Windows 10 version 2004 or later, or Windows 11, in the **Enterprise, Pro for Workstations or IoT Enterprise** edition. Only these hand a screen to a program. Measured on one laptop: refused on Pro, fine after changing to Enterprise.
- At least two monitors on the PC's own graphics outputs (not a USB display adapter), and a current display driver.
- An administrator account for the one-time setup. The usual kind with UAC prompts is fine.

Nothing else is installed: the setup adds two small programs and three scheduled tasks.

## Setup

Download `LockMonitor-<version>-bin.zip` from the newest release (it has both programs ready-built) and extract it. From an elevated PowerShell, in the extracted folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-Auto.ps1
```

The same command in the source code (the repository, or a release's "Source code (zip)") first builds the two programs, as described under [Build](#build).

The setup ends with a live test: the screen that will be kept goes dark for a few seconds and shows a test picture. If the test fails, the setup says why and removes everything again.

Then sign out and back in once, and restart Chrome and Edge once. After that, just press Win+L.

To update, or after changing monitors, run the same command again. To undo everything, including the two settings it changed:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-Auto.ps1 -Remove
```

## Which monitor

The highest-numbered screen (`\\.\DISPLAYn`), and from then on only that very monitor: the one that showed the test picture. If it is switched off or unplugged when you lock, nothing stays on; the next screen in line never takes its place.

## What happens at Win+L

1. Windows locks. Its own "workstation locked" event starts `Switch-LastScreen.exe -take` (elevated), which takes the monitor off the Windows desktop with the switch behind Settings > System > Display > Advanced display > "Remove display from desktop".
2. `LockMonitor-Agent.exe` (not elevated, waiting since sign-in) redraws on that monitor, live, the windows that were on it.
3. At unlock, Windows' "unlocked" event starts `Switch-LastScreen.exe -give`: the monitor is a desktop screen again and Windows puts the windows back.

## What the setup changes

- Two programs in `%ProgramFiles%\LockMonitor`: `LockMonitor-Agent.exe` and `Switch-LastScreen.exe`.
- Three scheduled tasks for your account: `LockMonitor-Agent`, `LockMonitor-Take`, `LockMonitor-Give`.
- The Windows setting "Minimize windows when a monitor is disconnected" is turned off for your account. With it on, Windows minimizes the windows of the monitor that leaves the desktop and there is nothing left to show.
- The Chrome and Edge policy `WindowOcclusionEnabled` is set to 0. These browsers stop drawing when the PC is locked, and this policy is their own switch for that. They will then say "managed by your organization". `-LeaveBrowsers` skips this.

`-Remove` puts both settings back to what they were. It leaves the log in `%LOCALAPPDATA%\LockMonitor` for you to delete: the setup runs as administrator and does not delete in your own folders.

## Good to know

- **How faithful the picture is.** While the monitor is off the desktop, Windows keeps its windows on another screen, and that is where their picture comes from.
  - Windows shrinks or un-maximizes them there, so the agent gives each window back the size it had. A maximized window is shown full size. This is the only thing ever done to a window, and Windows puts every window back as it was at unlock.
  - If the other screens together are smaller than the kept one, a window cannot get its full size and its picture is enlarged to fit.
  - If the other screens use a different scaling (Settings > System > Display > Scale), apps draw their windows for that scaling and everything looks larger or smaller. The same scaling on all screens gives an identical picture. The log says so when this applies.
- The kept monitor goes blank for a moment at Win+L, and a TV has to find its signal again.
- While locked, the PC is kept awake and the displays are kept on. Windows has one display-power switch for all monitors, so the other monitors stay lit, showing the lock screen.
- Apps must keep drawing while the PC is locked. Classic apps do. Chrome and Edge do with the policy above. Apps built on Electron may freeze; there is no switch for them from outside.
- The picture is refreshed up to four times a second while it changes, and once a second while it is still. Only the rows that changed go to the graphics card, and windows completely hidden behind another one are not captured.
- If none of the monitor's windows can be drawn, the monitor says why instead of staying black.
- Logs: `%LOCALAPPDATA%\LockMonitor\log.txt` has two lines per lock (what is shown and from when, how long the lock lasted and how many pictures) plus anything that went wrong. `%ProgramFiles%\LockMonitor\switch.log` has only what was out of the ordinary. Nothing about how you signed in is recorded.
- `"%ProgramFiles%\LockMonitor\LockMonitor-Agent.exe" -selftest | more` checks the PC's graphics and window capture without changing anything.

## Tested and not tested

Tested in a VMware guest (Windows 11 Enterprise LTSC 2024), with real key presses and the real password:

- lock, live redraw at the screen's own resolution, unlock, windows back exactly as they were; maximized and normal windows
- two and three screens, and the kept screen being the primary display
- mouse and keyboard on the lock screen while the monitor is kept
- three lock and unlock cycles as fast as the keys can be typed
- the kept monitor unplugged during a lock, and a restart while locked: the monitor returns to the desktop by itself
- the kept monitor missing at Win+L: nothing stays on
- screens with different scaling
- update and uninstall while it is running; the agent killed and started again at the next unlock; uninstall restores every setting
- the setup's live test, passing and failing, from the ready-built zip marked as downloaded from the internet
- Windows refusing the request (made to happen with a deliberately wrong request): the setup shows Windows' own answer and explains it

Tested on real hardware (a laptop with a TV, by the first user): the edition requirement, and the picture with version 0.1.2.

Not tested:

- the compiled agent (version 0.2.0 and later) putting the picture on a real monitor (the setup's live test does exactly that on your PC)
- a PC with two graphics adapters, sleep and resume while locked, Electron apps
- whether the number Windows Settings shows for a monitor equals its `\\.\DISPLAYn` number on your PC (the test picture shows which monitor it is)

## Build

Building needs nothing but Windows 10 or 11 (64-bit): the C# compiler of .NET Framework 4.8, which is part of Windows, and Windows' own description of its display interface in `System32\WinMetadata`. No Visual Studio, SDK or download.

In the source code, from a normal (not elevated) PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\Build.ps1
```

This writes `bin\LockMonitor-Agent.exe` and `bin\Switch-LastScreen.exe` and prints the version, size and SHA256 of each; `-Out <folder>` writes them elsewhere. Both are optimized release builds (`/optimize+`) for any CPU, which run as 64-bit programs, without a console window and with high-entropy ASLR (`/highentropyva+`).

The same by hand, in a Command Prompt in the source folder:

```bat
set FW=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319
set MD=%WINDIR%\System32\WinMetadata
mkdir bin
%FW%\csc.exe /nologo /target:winexe /optimize+ /highentropyva+ /out:bin\Switch-LastScreen.exe Switch-LastScreen.cs Common.cs
%FW%\csc.exe /nologo /target:winexe /optimize+ /highentropyva+ /out:bin\LockMonitor-Agent.exe /r:%MD%\Windows.Devices.winmd /r:%MD%\Windows.Graphics.winmd /r:%MD%\Windows.Foundation.winmd /r:%FW%\System.Runtime.dll /r:%FW%\System.Runtime.WindowsRuntime.dll /r:%FW%\System.Runtime.InteropServices.WindowsRuntime.dll Agent.cs Common.cs
```

To check a build without changing anything: `bin\LockMonitor-Agent.exe -selftest | more`.

To install your own build, run `Install-Auto.ps1` in the source folder, which builds and installs in one go, or put the two programs next to `Install-Auto.ps1`, which then installs them as they are. That is how the release's `-bin.zip` is made: `Build.ps1`, then `Install-Auto.ps1`, `README.md` and the two programs in one zip.

## Files

- `Install-Auto.ps1`: setup, update, removal.
- `Build.ps1`: builds the two programs.
- `Agent.cs`: the agent, `LockMonitor-Agent.exe`.
- `Switch-LastScreen.cs`: the elevated helper, `Switch-LastScreen.exe`.
- `Common.cs`: what both programs share, compiled into each, the version number included.
- `vmtest\`: the harness used for the tests above. Its paths are those of the original test machine.

Earlier versions also had a mode for a permanently dedicated monitor and a fallback that switched a monitor's input; both were removed in 0.2.0 and remain in the repository history (tag `v0.1.2`).
