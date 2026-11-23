# LockMonitor

Press **Win+L** and one monitor keeps showing its windows, live, while Windows is locked. The other monitors show the normal Windows lock screen.

The lock is the genuine Windows lock. No Windows file is patched, Win+L is not intercepted, there is no imitation lock screen, and signing in works exactly as before. The kept monitor shows pictures only: it has no pointer, no keyboard focus and takes no input.

**Status: pre-release.** It works on real hardware: version 0.2.6 on a desktop PC with Windows 10 Enterprise and a TV on a VGA-to-HDMI converter (Intel UHD 770), and version 0.1.2 on a laptop with a TV on HDMI (Intel Iris Xe, Windows 11 Enterprise). It has been through all the tests below in virtual machines, and the setup tests it live on your PC.

## Requirements

- Windows 10 version 2004 or later, or Windows 11, in the **Enterprise, Pro for Workstations or IoT Enterprise** edition. Only these hand a screen to a program. Measured on one laptop: refused on Pro, fine after changing to Enterprise. Windows 10 needs version 0.2.6 or later.
- At least two monitors on the PC's own graphics outputs (not a USB display adapter), and a current display driver.
- An administrator account for the one-time setup. The usual kind with UAC prompts is fine.

Nothing else is installed: the setup adds two small programs and three scheduled tasks.

## Setup

Download `LockMonitor-<version>-bin.zip` from the newest release (it has both programs ready-built) and extract it. From an elevated PowerShell, in the extracted folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-Auto.ps1
```

The same command in the source code (the repository, or a release's "Source code (zip)") first builds the two programs, as described under [Build](#build).

The setup checks that the scheduled tasks get administrator rights for your account, and ends with a live test: the screen that will be kept goes dark for a few seconds and shows a test picture. If either fails, the setup says why and removes everything again.

Then do what the setup lists at its end, once: on Windows 11 sign out and back in, and restart Chrome and Edge if they are running (`chrome://restart` or `edge://restart` in the address bar brings the tabs back). After that, just press Win+L.

To update, or after changing monitors, run the same command again. To undo everything, including the two settings it changed:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-Auto.ps1 -Remove
```

## Which monitor

The highest-numbered screen (`\\.\DISPLAYn`), and from then on only that very monitor: the one that showed the test picture. If it is switched off or unplugged when you lock, nothing stays on; the next screen in line never takes its place.

## What happens at Win+L

1. Windows locks. Its own "workstation locked" event starts `Switch-LastScreen.exe -take` (elevated), which takes the monitor off the Windows desktop with the switch behind Settings > System > Display > Advanced display > "Remove display from desktop". Windows 10 does not know the documented form of that request, so there it sends the one Windows' own Settings sends.
2. `LockMonitor-Agent.exe` (not elevated, waiting since sign-in) redraws on that monitor, live, the windows that were on it.
3. When the password box appears, the agent stops and has `Switch-LastScreen.exe -give` put the monitor back on the desktop, behind the sign-in screen: it is black there until you are signed in, and its windows are back in their places before your desktop appears. If the sign-in screen goes without a sign-in, the monitor is taken again and shows its windows. At unlock, Windows' "unlocked" event starts `-give` as well (for a sign-in too quick for the step before), and the windows are maximized again if they were and stacked as before, without taking the focus.

## What the setup changes

- Two programs in `%ProgramFiles%\LockMonitor`: `LockMonitor-Agent.exe` and `Switch-LastScreen.exe`.
- Three scheduled tasks for your account: `LockMonitor-Agent`, `LockMonitor-Take`, `LockMonitor-Give`.
- Windows 11 only: the setting "Minimize windows when a monitor is disconnected" is turned off for your account. With it on, Windows minimizes the windows of the monitor that leaves the desktop and there is nothing left to show.
- The Chrome and Edge policy `WindowOcclusionEnabled` is set to 0. These browsers stop drawing when the PC is locked, and this policy is their own switch for that. They will then say "managed by your organization". `-LeaveBrowsers` skips this.

`-Remove` puts both settings back to what they were. It leaves the log in `%LOCALAPPDATA%\LockMonitor` for you to delete: the setup runs as administrator and does not delete in your own folders.

## Good to know

- **How faithful the picture is.** While the monitor is off the desktop, Windows keeps its windows on another screen, and that is where their picture comes from.
  - Windows shrinks or un-maximizes them there, so the agent gives each window back the size it had. A maximized window is shown full size. When the password box appears they go back to their places on the monitor, out of sight of the other screens on the way (classic apps stop drawing out there, so not for the whole lock), and after the unlock they are maximized again if they were, without taking the focus. One exception: when the app it belongs to is in front on another screen (two Chrome windows, say), Windows would hand that window the keyboard focus on maximizing it, so it stays in its place and size, not maximized. Nothing else is ever done to a window.
  - If the other screens together are smaller than the kept one, a window cannot get its full size and its picture is enlarged to fit.
  - If the other screens use a different scaling (Settings > System > Display > Scale), apps draw their windows for that scaling and everything looks larger or smaller. The same scaling on all screens gives an identical picture. The log says so when this applies.
- The kept monitor goes blank for a moment at Win+L and when the password box appears, and a TV has to find its signal again.
- The other monitors: whenever the kept monitor leaves or rejoins the desktop, Windows takes the taskbar's room away from them for a moment, so their maximized windows change size. That happens behind the lock screen and the sign-in screen; one change is left at the unlock, when Windows gives the taskbar its room back.
- While locked, the PC is kept awake and the displays are kept on. Windows has one display-power switch for all monitors, so the other monitors stay lit, showing the lock screen. If the PC locks by itself after the displays went dark, they are switched on again; not when the PC woke up by itself (for updates at night, say).
- A screen saver that asks for the password when it ends ("On resume, display logon screen", also when set by your organization) does not lock the PC until then, and it covers the kept monitor too. Once it has run past its grace period (5 s unless set otherwise), when only the password leads back to the desktop, the agent locks the PC with Windows' own lock, as the screen saver would at its end: the other monitors show the lock screen instead of the screen saver, and the kept monitor shows its windows.
- Windows hands the monitor to the agent only while the lock screen's picture is up, not while a screen saver or the password box has the screen (measured). So with the policy "Do not display the lock screen", where Win+L goes straight to the password box, nothing stays on.
- If the PC sleeps anyway (put to sleep while locked, or gone to sleep while unlocked and locked on waking), the monitor shows its windows again about a second after the PC wakes up. Should the screen not have been freed after a lock or a wake-up although the monitor is there, the agent has the helper run again.
- Apps must keep drawing while the PC is locked. Classic apps do. Chrome and Edge do with the policy above, from their next start: one that has run since before the setup freezes at a lock, its page dark (the log then says so). Apps built on Electron may freeze; there is no switch for them from outside.
- The picture is refreshed up to four times a second while it changes, and once a second while it is still. Only the rows that changed go to the graphics card, and windows completely hidden behind another one are not captured.
- If none of the monitor's windows can be drawn, the monitor says why instead of staying black.
- Logs: `%LOCALAPPDATA%\LockMonitor\log.txt` has two lines per lock (what is shown, how long after the lock and after the screen was freed; how long the lock lasted and how many pictures), often a third (how many windows were put back), a line when a screen saver was turned into a lock or a sign-in screen went without a sign-in, a hint when Chrome or Edge may need its one restart, plus anything that went wrong. `%ProgramFiles%\LockMonitor\switch.log` has only what was out of the ordinary. Nothing about how you signed in is recorded.
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

Tested in a VMware guest with Windows 10 Enterprise 22H2 (build 19045), from version 0.2.6: the setup and its live test, lock and unlock with a normal and a maximized window on the kept screen (both back in place afterwards, the focus left where it was), the kept monitor unplugged during a lock, a restart while locked, also with the kept monitor unplugged until after the restart, a window hidden by its app during a lock, Chrome started before the setup, and the setup for an account the tasks cannot get administrator rights for.
From version 0.2.9, on Windows 10 and 11: no window of the kept monitor shows on another screen at unlock (screenshots of the "Welcome" and right after it), the focus stays with the window that had it, windows stacked as before; a sign-in screen left to time out (the windows come back and keep drawing); sleep (standby) while locked and while unlocked with sign-in on waking; a lock at which the helper did not run; the kept monitor unplugged during a lock and still unplugged at unlock (its windows stay visible on the other screen).
From version 0.2.11, on Windows 10 and 11: the monitor back on the desktop behind the sign-in screen (black there; its windows in place before the unlock; a maximized window on the other screen changes size once at the unlock, where it changed three times before), signing in fast while the monitor comes back, a sign-in screen left to time out (the monitor is taken again); on Windows 10 also a lock while the displays were dark (they came on again) and sleep while locked; a screen saver with "On resume, display logon screen" (locked after its grace period, the monitor showing its windows).
From version 0.2.12, on Windows 10 and 11: the bottom-most window drawn straight into the picture (a maximized browser, also at 125% scaling, with other windows above it), a sign-in screen left to time out in a lock (the windows get their size back), five locks in a row without growing memory, handles or GDI objects.

Tested on real hardware, by the first user: the edition requirement and the picture with version 0.1.2 (laptop with a TV, Windows 11); the picture with version 0.2.6 (desktop PC with Windows 10, Grafana in Chrome on a TV).

Not tested:

- a PC with two graphics adapters, Electron apps
- sleep on real hardware: the virtual machines offer standby S1 only, not S3 or Modern Standby, and their display adapter cannot show the picture itself
- a kept monitor that is turned to portrait: the picture is not turned with it
- whether the number Windows Settings shows for a monitor equals its `\\.\DISPLAYn` number on your PC (the test picture shows which monitor it is)

## Build

Building needs nothing but Windows 10 or 11 (64-bit): the C# compiler of .NET Framework 4.8, which is part of Windows, and Windows' own description of its display interface in `System32\WinMetadata`. No Visual Studio, SDK or download.

In the source code, from a normal (not elevated) PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\Build.ps1
```

This writes `bin\LockMonitor-Agent.exe` and `bin\Switch-LastScreen.exe` and prints the version, size and SHA256 of each; `-Out <folder>` writes them elsewhere. Both are optimized release builds (`/optimize+`) for any CPU, which run as 64-bit programs, without a console window and with high-entropy ASLR (`/highentropyva+`). The agent is built with `/unsafe`: it reads its own picture's memory directly to find the rows that changed.

The same by hand, in a Command Prompt in the source folder:

```bat
set FW=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319
set MD=%WINDIR%\System32\WinMetadata
mkdir bin
%FW%\csc.exe /nologo /target:winexe /optimize+ /highentropyva+ /out:bin\Switch-LastScreen.exe Switch-LastScreen.cs Common.cs
%FW%\csc.exe /nologo /target:winexe /optimize+ /highentropyva+ /unsafe /out:bin\LockMonitor-Agent.exe /r:%MD%\Windows.Devices.winmd /r:%MD%\Windows.Graphics.winmd /r:%MD%\Windows.Foundation.winmd /r:%FW%\System.Runtime.dll /r:%FW%\System.Runtime.WindowsRuntime.dll /r:%FW%\System.Runtime.InteropServices.WindowsRuntime.dll Agent.cs Common.cs
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
