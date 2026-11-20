# Remote Play Stabilizer

A small Windows tool you leave running while you play PS Remote Play. It tunes your PC for streaming, watches the connection, and tells you *why* it freezes.

## Run it

Double-click `Run-Stabilizer.bat`. A window appears and a tray icon.

- It asks once, listing what it will change. Choose **Yes** to restart as administrator (all four changes) or **No** to run without admin (monitoring plus the priority change only).
- Enter your PS5's IP (PS5: Settings > Network > View Connection Status). If you leave it blank, the tool tries to find it from Remote Play's connection.
- Start Remote Play as usual. The tool notices, tunes, and measures.

## What it changes (only while Remote Play runs)

| Change | Needs admin | Honest effect |
|---|---|---|
| Wi-Fi power saving -> maximum performance (power plan) | yes | Stops the adapter dozing between packets. Real, usually small. |
| Remote Play CPU priority -> High | no | Keeps decoding smooth under load. |
| Windows Update paused; OneDrive / Steam helper priority lowered | yes | Stops the biggest background downloads. It lowers CPU priority only; it does not cap their network use. |
| Remote Play traffic tagged DSCP 46 (QoS, active store) | yes | Only helps if your router honours it; many home routers ignore it. Clears on reboot. |

Everything is restored when Remote Play closes, when you press **Revert all**, or on the next launch if the tool was killed mid-session. The previous values are saved in `%LOCALAPPDATA%\RemotePlayStabilizer\state.json` before any change is made.

## What it measures

Every 200 ms it pings your router, your PS5 and the internet (1.1.1.1), and reads your Wi-Fi signal. A **freeze** is jitter over 30 ms, or loss over 2% with at least 2 lost pings, across 5 seconds, on the router or PS5 probe. (A PS5 that never replies is treated as unreachable, not as a freeze, and the tool re-detects its address. Internet blips are shown but never trigger a freeze, because Remote Play does not use the internet.) Each freeze is logged to `%LOCALAPPDATA%\RemotePlayStabilizer\sessions\` with a likely cause:

- `PC-WIFI-WEAK`: the router probe itself is bad (so your PC's link is the problem), or nothing is measurably bad but your signal is below -70 dBm.
- `PS5-LINK`: the router probe is clean but the PS5 probe is bad. The PS5 and internet probes cross your PC's Wi-Fi too, so a clean router probe clears the PC link.
- `ROUTER-OR-INTERNET`: only the internet probe is bad.

When Remote Play closes you get a plain-language verdict (also under **Show verdict**).

## The honest limit

Software cannot fix a weak radio link. With both the PS5 and the PC on Wi-Fi, every frame crosses the air twice, and Wi-Fi at about -74 dBm will drop packets under load no matter what runs on the PC. The tool removes the local causes and then shows you which link is the weak one. The fixes that work are physical:

1. Put a **cable on the PS5** (biggest win), or at least on the PC.
2. Move the PS5 or router closer, or use a router channel with less interference.
3. In Remote Play settings, lower the video quality (resolution and frame rate).

## Developing

Tests use the Pester 3.4 that ships with Windows: `Invoke-Pester tests`. Headless check of the window and loop: `powershell -STA -File src\Start-Stabilizer.ps1 -SmokeSeconds 6`.
