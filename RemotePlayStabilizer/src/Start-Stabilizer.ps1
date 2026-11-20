param(
    [switch]$Consented,      # set when relaunched as admin: the consent dialog was already answered
    [int]$SmokeSeconds = 0   # >0: run headless-ish for N seconds, print a summary, exit (used for verification)
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Import-Module (Join-Path $PSScriptRoot 'Stabilizer.psm1') -Force
[System.Windows.Forms.Application]::EnableVisualStyles()

$AppDir = Split-Path (Get-StatePath)
$ConfigPath = Join-Path $AppDir 'config.json'
$LogPath = Join-Path $AppDir ("sessions\{0}.jsonl" -f (Get-Date -Format 'yyyyMMdd'))
$Names = @('Router', 'Ps5', 'Internet')
$WindowSize = 25      # 5 s of samples at 200 ms
$MinSamples = 15
$AllActions = @('PowerSaving', 'ProcessPriority', 'PauseHogs', 'Qos')

# ---------- single instance: a second copy would revert the first one's live tuning ----------
$script:mutex = New-Object System.Threading.Mutex($false, 'Local\RemotePlayStabilizerSingleton')
$owned = $false
try { $owned = $script:mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) {
    if ($SmokeSeconds -gt 0) { 'ALREADY RUNNING'; exit 1 }
    [void][System.Windows.Forms.MessageBox]::Show('Remote Play Stabilizer is already running (check the tray icon).', 'Remote Play Stabilizer')
    exit 0
}

# ---------- startup: clean up after a crash, then ask for consent once ----------
if (Test-TunerDirty) { Invoke-TunerRevert }

$changes = "While Remote Play is running, this tool will:`n" +
    "  - set Wi-Fi power saving to maximum performance`n" +
    "  - raise Remote Play's CPU priority`n" +
    "  - lower OneDrive/Steam helper priority and pause Windows Update`n" +
    "  - mark Remote Play traffic as high priority (QoS)`n`n" +
    "Everything is restored when Remote Play closes (or press 'Revert all')."

if (-not $Consented -and $SmokeSeconds -eq 0) {
    if (Test-IsAdmin) {
        $a = [System.Windows.Forms.MessageBox]::Show($changes, 'Remote Play Stabilizer', 'OKCancel', 'Information')
        if ($a -ne 'OK') { exit 0 }
    } else {
        $msg = $changes + "`n`nYes = restart as administrator (all four changes)`nNo = continue without admin (only the priority change; monitoring still works)`nCancel = quit"
        $a = [System.Windows.Forms.MessageBox]::Show($msg, 'Remote Play Stabilizer', 'YesNoCancel', 'Information')
        if ($a -eq 'Cancel') { exit 0 }
        if ($a -eq 'Yes') {
            $script:mutex.ReleaseMutex(); $script:mutex.Dispose()   # let the elevated copy take the lock
            Start-Process -FilePath powershell.exe -Verb RunAs -ArgumentList '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"", '-Consented'
            exit 0
        }
    }
}

# ---------- state ----------
$script:win = @{}; $script:probe = @{}; $script:addr = @{}
foreach ($n in $Names) { $script:win[$n] = New-Object System.Collections.Generic.List[object]; $script:probe[$n] = $null }
$script:addr['Internet'] = '1.1.1.1'
$script:addr['Router'] = Get-GatewayIp
$cfg = $null
if (Test-Path $ConfigPath) { try { $cfg = Get-Content -Raw $ConfigPath | ConvertFrom-Json } catch { } }
if ($cfg -and $cfg.PSObject.Properties['Ps5Ip'] -and $cfg.Ps5Ip) { $script:addr['Ps5'] = [string]$cfg.Ps5Ip } else { $script:addr['Ps5'] = $null }
$script:rssi = $null
$script:netshProc = $null; $script:netshTask = $null
$script:session = $false; $script:events = @(); $script:lastEvent = [datetime]::MinValue
$script:tuneText = ''; $script:freezeText = ''; $script:freezeUntil = [datetime]::MinValue
$script:ticks = 0; $script:samples = @{ Router = 0; Ps5 = 0; Internet = 0 }

function Add-Sample($name, $rtt) {
    $l = $script:win[$name]
    $l.Add($rtt)
    if ($l.Count -gt $WindowSize) { $l.RemoveAt(0) }
    $script:samples[$name]++
}

function Get-Stats($name) {
    if (-not $script:addr[$name]) { return $null }
    $l = $script:win[$name]
    if ($l.Count -lt $MinSamples) { return $null }
    Get-WindowStats -Samples $l.ToArray()
}

function Save-Config { New-Item -ItemType Directory -Path $AppDir -Force | Out-Null; @{ Ps5Ip = [string]$script:addr['Ps5'] } | ConvertTo-Json | Set-Content -Path $ConfigPath -Encoding UTF8 }

function Set-Ps5Address($ip) {
    $script:addr['Ps5'] = $ip
    $script:win['Ps5'].Clear(); $script:probe['Ps5'] = $null
    Save-Config
}

# ---------- UI ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Remote Play Stabilizer'
$form.Size = New-Object System.Drawing.Size(500, 470)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$form.FormBorderStyle = 'FixedSingle'; $form.MaximizeBox = $false

function New-Lbl($text, $x, $y, $w = 120, $bold = $false) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y); $l.Size = New-Object System.Drawing.Size($w, 24)
    if ($bold) { $l.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold) }
    $form.Controls.Add($l); $l
}

$cols = @(150, 270, 360)
[void](New-Lbl 'Link' 16 14 120 $true)
[void](New-Lbl 'Latency' $cols[0] 14 100 $true); [void](New-Lbl 'Jitter' $cols[1] 14 80 $true); [void](New-Lbl 'Loss' $cols[2] 14 80 $true)
$ui = @{}
$rowY = 44
foreach ($n in $Names) {
    $label = @{ Router = 'Router'; Ps5 = 'PS5'; Internet = 'Internet' }[$n]
    [void](New-Lbl $label 16 $rowY 120)
    $ui[$n] = @{ Lat = (New-Lbl '-' $cols[0] $rowY 110); Jit = (New-Lbl '-' $cols[1] $rowY 90); Loss = (New-Lbl '-' $cols[2] $rowY 90) }
    $rowY += 30
}
[void](New-Lbl 'Wi-Fi signal' 16 $rowY 120)
$ui['Rssi'] = New-Lbl 'n/a' $cols[0] $rowY 300
$rowY += 40

[void](New-Lbl 'PS5 IP address' 16 $rowY 120)
$txtIp = New-Object System.Windows.Forms.TextBox
$txtIp.Location = New-Object System.Drawing.Point($cols[0], ($rowY - 2)); $txtIp.Size = New-Object System.Drawing.Size(150, 26)
if ($script:addr['Ps5']) { $txtIp.Text = $script:addr['Ps5'] }
$form.Controls.Add($txtIp)
$btnIp = New-Object System.Windows.Forms.Button
$btnIp.Text = 'Save'; $btnIp.Location = New-Object System.Drawing.Point(316, ($rowY - 3)); $btnIp.Size = New-Object System.Drawing.Size(70, 28)
$form.Controls.Add($btnIp)
$rowY += 40

$lblStatus = New-Lbl 'Waiting for Remote Play...' 16 $rowY 450 $true
$lblStatus.Size = New-Object System.Drawing.Size(450, 24)
$rowY += 30
$lblDetail = New-Lbl '' 16 $rowY 450
$lblDetail.Size = New-Object System.Drawing.Size(450, 64)
$rowY += 70

$btnRevert = New-Object System.Windows.Forms.Button
$btnRevert.Text = 'Revert all'; $btnRevert.Location = New-Object System.Drawing.Point(16, $rowY); $btnRevert.Size = New-Object System.Drawing.Size(120, 32)
$btnVerdict = New-Object System.Windows.Forms.Button
$btnVerdict.Text = 'Show verdict'; $btnVerdict.Location = New-Object System.Drawing.Point(146, $rowY); $btnVerdict.Size = New-Object System.Drawing.Size(130, 32)
$form.Controls.Add($btnRevert); $form.Controls.Add($btnVerdict)

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = [System.Drawing.SystemIcons]::Information
$notify.Text = 'Remote Play Stabilizer'
$notify.Visible = $true

function Format-Stat($name) {
    $s = Get-Stats $name
    $u = $ui[$name]
    if (-not $script:addr[$name]) {
        $u.Lat.Text = 'not set'; $u.Jit.Text = '-'; $u.Loss.Text = '-'
        return
    }
    if ($null -eq $s) { $u.Lat.Text = 'measuring...'; $u.Jit.Text = '-'; $u.Loss.Text = '-'; return }
    $u.Lat.Text = if ($s.Loss -ge 1) { 'no reply' } else { '{0:N0} ms' -f $s.Avg }
    $u.Jit.Text = '{0:N1} ms' -f $s.Jitter
    $u.Loss.Text = '{0:P0}' -f $s.Loss
    $bad = [System.Drawing.Color]::Firebrick; $ok = [System.Drawing.SystemColors]::ControlText
    $u.Jit.ForeColor = if ($s.Jitter -gt 30) { $bad } else { $ok }
    $u.Loss.ForeColor = if ($s.Loss -gt 0.02) { $bad } else { $ok }
}

function Update-Status {
    if (-not $script:session) {
        $lblStatus.Text = 'Waiting for Remote Play...'
        $lblDetail.Text = $script:tuneText
    } elseif ((Get-Date) -lt $script:freezeUntil) {
        $lblStatus.Text = $script:freezeText
        $lblStatus.ForeColor = [System.Drawing.Color]::Firebrick
        $lblDetail.Text = $script:tuneText
    } else {
        $lblStatus.Text = 'Remote Play running - monitoring'
        $lblStatus.ForeColor = [System.Drawing.SystemColors]::ControlText
        $lblDetail.Text = $script:tuneText
    }
    $t = $lblStatus.Text; if ($t.Length -gt 60) { $t = $t.Substring(0, 60) }
    $notify.Text = $t
}

function Start-Session {
    $script:session = $true; $script:events = @(); $script:lastEvent = [datetime]::MinValue
    $r = Invoke-TunerApply -Actions $AllActions
    $text = 'Applied: ' + $(if (@($r.Applied).Count) { @($r.Applied) -join ', ' } else { 'nothing' })
    if (@($r.Skipped).Count) { $text += "`nSkipped (need admin or not available): " + (@($r.Skipped) -join ', ') }
    $script:tuneText = $text
    Write-SessionLog -Path $LogPath -Entry @{ Event = 'session-start'; Applied = @($r.Applied); Skipped = @($r.Skipped); Rssi = $script:rssi }
}

function Stop-Session {
    Invoke-TunerRevert
    $script:session = $false
    $verdict = Get-Verdict -Events $script:events
    $script:tuneText = "Settings restored. Last session: $verdict"
    Write-SessionLog -Path $LogPath -Entry @{ Event = 'session-end'; Freezes = @($script:events).Count; Verdict = $verdict }
    $notify.ShowBalloonTip(6000, 'Remote Play closed', $verdict, 'Info')
}

function Read-Netsh {
    if ($script:netshTask -and $script:netshTask.IsCompleted) {
        $script:rssi = ConvertFrom-NetshWlan -Text ($script:netshTask.Result -split "`r?`n")
        try { $script:netshProc.Dispose() } catch { }
        $script:netshProc = $null; $script:netshTask = $null
    }
    if (-not $script:netshProc) {
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo 'netsh', 'wlan show interfaces'
            $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.CreateNoWindow = $true
            $script:netshProc = [System.Diagnostics.Process]::Start($psi)
            $script:netshTask = $script:netshProc.StandardOutput.ReadToEndAsync()
        } catch { $script:netshProc = $null; $script:netshTask = $null }
    }
}

function Test-FreezeNow {
    if (-not $script:session) { return }
    $st = @{}
    foreach ($n in $Names) { $st[$n] = Get-Stats $n }
    # A PS5 that never replies is unreachable or mistyped, not a freeze. Remote Play does not use the internet, so an
    # internet-only blip is shown but does not trigger a freeze either.
    if ($st['Ps5'] -and $st['Ps5'].Loss -ge 1) { $st['Ps5'] = $null }
    $frozen = (Test-Freeze $st['Router']) -or (Test-Freeze $st['Ps5'])
    if (-not $frozen -or ((Get-Date) - $script:lastEvent).TotalSeconds -lt 10) { return }
    $script:lastEvent = Get-Date
    $cause = Get-Cause -Rssi $script:rssi -Router $st['Router'] -Ps5 $st['Ps5'] -Internet $st['Internet']
    $script:events += [pscustomobject]@{ Cause = $cause; Time = Get-Date }
    $entry = @{ Event = 'freeze'; Cause = $cause; Rssi = $script:rssi }
    foreach ($n in $Names) { if ($st[$n]) { $entry["${n}Jitter"] = [math]::Round($st[$n].Jitter, 1); $entry["${n}Loss"] = [math]::Round($st[$n].Loss, 3) } }
    Write-SessionLog -Path $LogPath -Entry $entry
    $script:freezeText = "Freeze at $((Get-Date).ToString('HH:mm:ss')): $cause"
    $script:freezeUntil = (Get-Date).AddSeconds(10)
    $notify.ShowBalloonTip(4000, 'Connection freeze', $script:freezeText, 'Warning')
}

# fast loop: probes + display (200 ms)
$probeTimer = New-Object System.Windows.Forms.Timer
$probeTimer.Interval = 200
$probeTimer.Add_Tick({
    $script:ticks++
    foreach ($n in $Names) {
        $a = $script:addr[$n]
        if (-not $a) { continue }
        $p = $script:probe[$n]
        if ($p) {
            $r = Get-ProbeResult -Probe $p
            if (-not $r.Done) { continue }
            Add-Sample $n $r.Rtt
            $script:probe[$n] = $null
        }
        $script:probe[$n] = Start-ProbeAsync -Target $a -TimeoutMs 150
    }
    if ($script:ticks % 10 -eq 0) { Read-Netsh }
    if ($script:ticks % 50 -eq 0) { $g = Get-GatewayIp; if ($g) { $script:addr['Router'] = $g } }
    foreach ($n in $Names) { Format-Stat $n }
    $ui['Rssi'].Text = if ($null -ne $script:rssi) { "$($script:rssi) dBm" + $(if ($script:rssi -lt -70) { '  (weak)' } else { '' }) } else { 'n/a' }
    Test-FreezeNow
    Update-Status
})

# slow loop: watch for Remote Play (1 s)
$watchTimer = New-Object System.Windows.Forms.Timer
$watchTimer.Interval = 1000
$script:watchTicks = 0
$watchTimer.Add_Tick({
    $script:watchTicks++
    $running = @(Get-Process -Name RemotePlay -ErrorAction SilentlyContinue).Count -gt 0
    if ($running -and -not $script:session) { Start-Session }
    elseif (-not $running -and $script:session) { Stop-Session }
    # Detect the PS5 when unset, and re-detect when the saved address never answers (DHCP change, typo).
    $ps5 = Get-Stats 'Ps5'
    $ps5Dead = $ps5 -and $ps5.Loss -ge 1
    if ($running -and (-not $script:addr['Ps5'] -or $ps5Dead) -and $script:watchTicks % 5 -eq 0) {
        $ip = Find-Ps5Ip
        if ($ip -and $ip -ne $script:addr['Ps5']) { $txtIp.Text = $ip; Set-Ps5Address $ip }
    }
})

$btnIp.Add_Click({
    $ip = $txtIp.Text.Trim()
    if ($ip -match '^\d{1,3}(\.\d{1,3}){3}$') { Set-Ps5Address $ip }
    elseif ($ip -eq '') { Set-Ps5Address $null }
    else { [void][System.Windows.Forms.MessageBox]::Show('Enter an IPv4 address like 192.168.1.50 (PS5: Settings > Network > View Connection Status).', 'PS5 IP') }
})
$btnRevert.Add_Click({
    Invoke-TunerRevert
    $script:tuneText = 'Reverted by you. Tuning resumes next time Remote Play starts.'
})
$btnVerdict.Add_Click({ [void][System.Windows.Forms.MessageBox]::Show((Get-Verdict -Events $script:events), 'Verdict') })
$notify.Add_Click({ $form.Show(); $form.WindowState = 'Normal'; $form.Activate() })
$form.Add_FormClosing({ $probeTimer.Stop(); $watchTimer.Stop(); Invoke-TunerRevert })

if ($SmokeSeconds -gt 0) {
    $smoke = New-Object System.Windows.Forms.Timer
    $smoke.Interval = $SmokeSeconds * 1000
    $smoke.Add_Tick({ $smoke.Stop(); $form.Close() })
    $smoke.Start()
}

$probeTimer.Start(); $watchTimer.Start()
try {
    [System.Windows.Forms.Application]::Run($form)
} finally {
    Invoke-TunerRevert
    $notify.Visible = $false; $notify.Dispose()
    try { $script:mutex.ReleaseMutex(); $script:mutex.Dispose() } catch { }
}

if ($SmokeSeconds -gt 0) {
    "SMOKE ticks=$($script:ticks) router=$($script:samples['Router']) internet=$($script:samples['Internet']) rssi=$($script:rssi) dirty=$(Test-TunerDirty)"
}
