# PS Remote Play Stabilizer — Design (short)

## Intent and why
PS Remote Play freezes and disconnects during intense gameplay. The PS5 and the Windows PC are both on Wi-Fi, so video crosses the radio twice and the two devices compete for airtime. Measured on the PC: 5 GHz ch157, RSSI -74 dBm (weak), link speed swinging 866 → 175 Mbps. Internet speed is not the issue; jitter and packet loss are.

Build a Windows tool that runs alongside Remote Play, removes local causes of instability, and records evidence of what is still wrong.

## Goals
- Auto-start tuning when RemotePlay.exe launches; auto-revert when it exits.
- Tuner: Wi-Fi power saving off, no roaming to weaker APs, Remote Play process priority up, background bandwidth hogs paused (Windows Update, OneDrive, Steam downloads), traffic marked high priority where Windows allows.
- Monitor: ping router, PS5 and internet every 200 ms; show latency, jitter, loss and signal (RSSI) live.
- Freeze log: when jitter or loss crosses a threshold, log a timestamped entry naming the likely cause (PC link weak, PS5 side lossy, router/internet).
- Plain-language verdict at the end of a session (e.g. "PS5 link is the weak point; use a cable or move it").

## Non-goals
- Not a network driver, VPN or packet shaper. No kernel code.
- Does not modify the PS5 or the router.
- No installs or dependencies beyond what ships with Windows.

## Anti-goals (failure even if it "works")
- Leaving system settings changed after Remote Play closes.
- Claiming it fixes a weak signal. The tool must say so when the cause is the radio link.

## Constraints
- Windows 11, PowerShell 5.1, WinForms for the window.
- Some changes need admin; the tool asks once and says what it will change.
- Every change is logged and reversible; a "Revert all" button exists.
- Needs the PS5's IP (auto-detect via Remote Play connection, else user enters it once).

## Approaches considered
1. Tuner only: quick, but small effect and no proof of cause.
2. Monitor only: shows the cause, fixes nothing.
3. Tuner + monitor + freeze log (chosen by user): fixes what software can, and gives evidence for the physical fix (cable / closer / router channel).

## Decided by user
- Option 3.

## My calls (not yet confirmed)
- PowerShell + WinForms, single script, window with tray icon.
- Logs under `%LOCALAPPDATA%\RemotePlayStabilizer\`.
- Thresholds: jitter > 30 ms or loss > 2% over a 5 s window counts as a freeze event.
- Tuner changes are applied only when Remote Play is running and reverted on exit or crash.

## Left to the builder
- Exact UI layout, how to detect the PS5 IP, QoS policy mechanics, and the list of background processes to pause.
