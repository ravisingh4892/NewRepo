# Remote Play Stabilizer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Windows tool that tunes the PC while PS Remote Play runs, monitors the link, logs freezes with a likely cause, and reverts everything on exit.

**Architecture:** One PowerShell module (`Stabilizer.psm1`) holding pure logic (stats, freeze classification, verdict, tuner with persisted revert state, probes, logging) so it is unit-testable with Pester. A thin WinForms script (`Start-Stabilizer.ps1`) wires a timer loop, a RemotePlay.exe watcher, a live window and a tray icon.

**Tech Stack:** PowerShell 5.1, WinForms, Pester 3.4 (ships with Windows), System.Net.NetworkInformation.Ping, netsh, Set-NetAdapterPowerManagement, New-NetQosPolicy.

**Spec:** `docs/superpowers/specs/2026-11-20-remote-play-stabilizer-design.md`

## Global Constraints

- Windows 11, PowerShell 5.1, WinForms; no installs or dependencies beyond what ships with Windows.
- Ping router, PS5 and internet every 200 ms.
- Freeze event: jitter > 30 ms or loss > 2% over a 5 s window.
- Tuner changes are applied only while RemotePlay.exe runs and are reverted on exit or crash; a "Revert all" button exists; every change is logged and reversible.
- Admin is requested once, with a list of what will change.
- Logs live under `%LOCALAPPDATA%\RemotePlayStabilizer\`.
- Never claim to fix a weak signal; say so when the cause is the radio link.
- Does not touch the PS5 or router.

## Review Focus

- PS5 IP unknown or unreachable: monitor shows "PS5 not set/not found" and the verdict says the PS5 side is unmeasured, no crash.
- Wi-Fi disconnected mid-session (netsh returns no interface): RSSI shows n/a, session continues.
- Crash/kill while tuned: next launch finds the state file and reverts leftovers before doing anything.
- Remote Play launched twice or restarted: tuner applies once, reverts once.
- Not running as admin: tuner skips admin-only actions, reports which were skipped, monitor still works.

---

### Task 1: Stats, freeze detection, verdict

**Files:**
- Create: `src/Stabilizer.psm1`
- Test: `tests/Stats.Tests.ps1`

**Interfaces:**
- Produces: `Get-WindowStats -Samples <double[]>` (RTT ms, `$null` = lost) → `[pscustomobject]@{ Jitter; Loss; Avg; Count }` (jitter = mean absolute difference of consecutive received RTTs; loss = fraction 0–1).
- Produces: `Test-Freeze -Stats <obj>` → `[bool]` (Jitter > 30 or Loss > 0.02).
- Produces: `Get-Cause -Rssi <int|$null> -Router <stats> -Ps5 <stats|$null> -Internet <stats>` → `'PC-WIFI-WEAK'`, `'PS5-LINK'`, `'ROUTER-OR-INTERNET'` or `'UNKNOWN'`. Rules: Rssi < -70 or Router frozen → PC-WIFI-WEAK; else Ps5 frozen → PS5-LINK; else Internet frozen → ROUTER-OR-INTERNET; else UNKNOWN.
- Produces: `Get-Verdict -Events <obj[]>` (each has `.Cause`) → string; most frequent cause maps to plain advice (PS5-LINK → "PS5 link is the weak point; use a cable or move it closer to the router"; PC-WIFI-WEAK → states software cannot fix a weak radio link, move closer or use a cable).

- [ ] **Step 1: Write failing tests** in `tests/Stats.Tests.ps1`: `Get-WindowStats` on `@(10,10,10,10)` → Jitter 0, Loss 0; on `@(10,50,$null,10)` → Loss 0.25, Jitter 40; `Test-Freeze` true for Jitter 31, true for Loss 0.03, false for Jitter 30/Loss 0.02; `Get-Cause` returns each of the four values for crafted inputs, incl. Rssi -74 with healthy router → PC-WIFI-WEAK and `-Ps5 $null` never → PS5-LINK; `Get-Verdict` with three PS5-LINK and one PC-WIFI-WEAK contains "cable"; empty events → "No freezes recorded".
- [ ] **Step 2: Run** `powershell -Command "Invoke-Pester tests/Stats.Tests.ps1"` — Expected: FAIL (functions not defined).
- [ ] **Step 3: Implement** the four functions in `src/Stabilizer.psm1` and export them.
- [ ] **Step 4: Run Pester** — Expected: all pass.
- [ ] **Step 5: Commit** `feat: stats, freeze detection, verdict`

### Task 2: Tuner with persisted revert state

**Files:**
- Modify: `src/Stabilizer.psm1`
- Test: `tests/Tuner.Tests.ps1`

**Interfaces:**
- Produces: `Get-StatePath` → `%LOCALAPPDATA%\RemotePlayStabilizer\state.json` (overridable via `$script:StateDirOverride` for tests).
- Produces: `Test-IsAdmin` → `[bool]`.
- Produces: `Invoke-TunerApply -Actions <string[]>`, actions ⊆ `PowerSaving, ProcessPriority, PauseHogs, Qos` → `[pscustomobject]@{ Applied=string[]; Skipped=string[] }`. Previous value of each change is written to the state file *before* changing it, and never overwritten on a second apply. PowerSaving/PauseHogs/Qos are admin-only (Skipped when not elevated); ProcessPriority sets RemotePlay to High. PauseHogs stops `wuauserv` and suspends processes named in `$script:HogProcesses` (OneDrive, steamwebhelper). Qos creates NetQosPolicy "RemotePlayStabilizer" for RemotePlay.exe, DSCP 46.
- Produces: `Invoke-TunerRevert` → undoes every recorded change, deletes the state file; no-op if none; idempotent.
- Produces: `Test-TunerDirty` → `[bool]` (state file exists).

- [ ] **Step 1: Write failing tests** (Pester mocks for cmdlets, state dir under `$TestDrive`): apply then revert restores recorded previous values and removes the file; second revert is a no-op; with `Test-IsAdmin` mocked false, admin-only actions land in Skipped and ProcessPriority still applies; `Test-TunerDirty` true after apply, false after revert; applying twice keeps the original previous values.
- [ ] **Step 2: Run** `Invoke-Pester tests/Tuner.Tests.ps1` — Expected: FAIL.
- [ ] **Step 3: Implement** the functions.
- [ ] **Step 4: Run Pester** — Expected: pass.
- [ ] **Step 5: Commit** `feat: reversible tuner`

### Task 3: Probes and logging

**Files:**
- Modify: `src/Stabilizer.psm1`
- Test: `tests/Probes.Tests.ps1`

**Interfaces:**
- Produces: `ConvertFrom-NetshWlan -Text <string[]>` → `[int]` RSSI or `$null`.
- Produces: `Get-WifiRssi` → `[int]` or `$null` (runs netsh, calls the parser).
- Produces: `Get-GatewayIp` → default gateway IPv4 string or `$null`.
- Produces: `Send-Probe -Target <string> -TimeoutMs 150` → `[double]` RTT ms or `$null` on loss/timeout/exception.
- Produces: `Write-SessionLog -Path <string> -Entry <hashtable>` appends one JSON line with added `Time` (ISO-8601); creates the directory.

- [ ] **Step 1: Write failing tests**: parser on a sample containing "Rssi                   : -74" returns -74; on empty/no-interface text returns `$null`; `Write-SessionLog` into `$TestDrive` twice yields two lines, each valid JSON with `Time`.
- [ ] **Step 2: Run** `Invoke-Pester tests/Probes.Tests.ps1` — Expected: FAIL.
- [ ] **Step 3: Implement**; `Send-Probe` uses `System.Net.NetworkInformation.Ping`.
- [ ] **Step 4: Run Pester** — Expected: pass.
- [ ] **Step 5: Commit** `feat: probes and session log`

### Task 4: UI, watcher, session loop

**Files:**
- Create: `src/Start-Stabilizer.ps1`, `Run-Stabilizer.bat`

**Interfaces:**
- Consumes: all exported functions from Tasks 1–3.
- Produces: window "Remote Play Stabilizer" with live Router/PS5/Internet latency, jitter, loss, RSSI; status line (Waiting for Remote Play / Tuned / Freeze: cause); buttons "Revert all" and "Show verdict"; tray icon mirroring status. 200 ms timer sends probes into 25-sample sliding windows; 1 s timer checks for RemotePlay.exe. On start: if `Test-TunerDirty`, revert first. On Remote Play start: show admin-consent list, self-elevate once if accepted, `Invoke-TunerApply`. On Remote Play exit, window close or unhandled error: `Invoke-TunerRevert`, then show `Get-Verdict`. PS5 IP field persisted in `config.json` in the app data folder; blank → "PS5: not set". Freeze events logged with `Get-Cause`, at most one per 10 s.
- `Run-Stabilizer.bat` runs `powershell -STA -ExecutionPolicy Bypass -File src\Start-Stabilizer.ps1`.

- [ ] **Step 1: Implement** `Start-Stabilizer.ps1`.
- [ ] **Step 2: Parse check** — Expected: no parser errors.
- [ ] **Step 3: Manual verification** (user runs): .bat with Remote Play closed → "Waiting", live numbers. Open Remote Play → consent prompt, "Tuned", `Get-NetQosPolicy` shows the policy. Close it → policy gone, verdict shown. Kill the tool mid-session, relaunch → leftovers reverted.
- [ ] **Step 4: Commit** `feat: stabilizer UI and session loop`

### Task 5: README and full test run

**Files:**
- Create: `README.md`

- [ ] **Step 1: Run** `Invoke-Pester tests` — Expected: all pass.
- [ ] **Step 2: Write README**: what it does, how to run, exactly what it changes, how to revert, the honest limit on weak signal.
- [ ] **Step 3: Commit** `docs: readme`
