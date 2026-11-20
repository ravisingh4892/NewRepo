Set-StrictMode -Version 2.0

# ---------- Stats, freeze detection, verdict (Task 1) ----------

function Get-WindowStats {
    param([AllowNull()][AllowEmptyCollection()][object[]]$Samples)
    $all = @($Samples)
    $got = @($all | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
    $count = $all.Count
    $loss = 0.0
    if ($count -gt 0) { $loss = ($count - $got.Count) / $count }
    $jitter = 0.0
    if ($got.Count -gt 1) {
        $sum = 0.0
        for ($i = 1; $i -lt $got.Count; $i++) { $sum += [math]::Abs($got[$i] - $got[$i - 1]) }
        $jitter = $sum / ($got.Count - 1)
    }
    $avg = 0.0
    if ($got.Count -gt 0) { $avg = ($got | Measure-Object -Average).Average }
    [pscustomobject]@{ Jitter = $jitter; Loss = $loss; Avg = $avg; Count = $count }
}

function Test-Freeze {
    param($Stats)
    if ($null -eq $Stats) { return $false }
    return ($Stats.Jitter -gt 30 -or $Stats.Loss -gt 0.02)
}

function Get-Cause {
    param([Nullable[int]]$Rssi, $Router, $Ps5, $Internet)
    if (($null -ne $Rssi -and $Rssi -lt -70) -or (Test-Freeze $Router)) { return 'PC-WIFI-WEAK' }
    if (Test-Freeze $Ps5) { return 'PS5-LINK' }
    if (Test-Freeze $Internet) { return 'ROUTER-OR-INTERNET' }
    return 'UNKNOWN'
}

function Get-Verdict {
    param([AllowNull()][AllowEmptyCollection()][object[]]$Events)
    $ev = @($Events | Where-Object { $null -ne $_ })
    if ($ev.Count -eq 0) { return 'No freezes recorded this session.' }
    $top = ($ev | Group-Object Cause | Sort-Object Count -Descending | Select-Object -First 1).Name
    $n = $ev.Count
    switch ($top) {
        'PS5-LINK' { return "$n freezes. PS5 link is the weak point; use a cable or move it closer to the router." }
        'PC-WIFI-WEAK' { return "$n freezes. Your PC's Wi-Fi link is weak. Software cannot fix a weak radio link: move closer to the router or use a cable." }
        'ROUTER-OR-INTERNET' { return "$n freezes. The router or your internet connection is the weak point; try restarting the router or changing its channel." }
        default { return "$n freezes, but the cause could not be pinned down." }
    }
}

# ---------- Reversible tuner (Task 2) ----------
# Every change records the previous value in a state file BEFORE it is made.
# Invoke-TunerRevert replays the state file, so it also cleans up after a crash.

$script:HogProcesses = @('OneDrive', 'steamwebhelper')
$script:AdminOnly = @('PowerSaving', 'PauseHogs', 'Qos')
$script:QosName = 'RemotePlayStabilizer'

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Wi-Fi power saving lives in the Windows power plan: Wireless Adapter Settings > Power Saving Mode
# (0 = maximum performance ... 3 = maximum power saving).
$script:WifiSubGroup = '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1'
$script:WifiPowerSetting = '12bbebe6-58d6-4636-95bb-3217ef867c1a'

function ConvertFrom-PowercfgQuery {
    param([string[]]$Text)
    $t = @($Text) -join "`n"
    $ac = [regex]::Match($t, 'Current AC Power Setting Index:\s+0x([0-9a-fA-F]+)')
    $dc = [regex]::Match($t, 'Current DC Power Setting Index:\s+0x([0-9a-fA-F]+)')
    if (-not $ac.Success -or -not $dc.Success) { return $null }
    @{ Ac = [Convert]::ToInt32($ac.Groups[1].Value, 16); Dc = [Convert]::ToInt32($dc.Groups[1].Value, 16) }
}

function Get-WifiPowerSaving {
    $m = [regex]::Match((@(powercfg /getactivescheme) -join "`n"), 'GUID:\s+([0-9a-fA-F-]{36})')
    if (-not $m.Success) { return $null }
    $scheme = $m.Groups[1].Value
    $v = ConvertFrom-PowercfgQuery -Text @(powercfg /query $scheme $script:WifiSubGroup $script:WifiPowerSetting)
    if ($null -eq $v) { return $null }
    @{ Scheme = $scheme; Ac = $v.Ac; Dc = $v.Dc }
}

function Set-WifiPowerSaving {
    param([string]$Scheme, [int]$Ac, [int]$Dc)
    powercfg /setacvalueindex $Scheme $script:WifiSubGroup $script:WifiPowerSetting $Ac
    if ($LASTEXITCODE -ne 0) { throw 'powercfg /setacvalueindex failed' }
    powercfg /setdcvalueindex $Scheme $script:WifiSubGroup $script:WifiPowerSetting $Dc
    if ($LASTEXITCODE -ne 0) { throw 'powercfg /setdcvalueindex failed' }
    powercfg /setactive SCHEME_CURRENT
}

function Get-StatePath {
    $dir = $env:RPS_STATE_DIR
    if (-not $dir) { $dir = Join-Path $env:LOCALAPPDATA 'RemotePlayStabilizer' }
    Join-Path $dir 'state.json'
}

function Read-State {
    $p = Get-StatePath
    if (-not (Test-Path $p)) { return $null }
    try { $o = Get-Content -Raw -Path $p | ConvertFrom-Json } catch { return $null }
    if ($null -eq $o) { return $null }
    $h = @{}
    foreach ($prop in $o.PSObject.Properties) { $h[$prop.Name] = $prop.Value }
    return $h
}

function Save-State {
    param($State)
    $p = Get-StatePath
    $d = Split-Path $p
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    $State | ConvertTo-Json -Depth 6 | Set-Content -Path $p -Encoding UTF8
}

function Get-ProcRecords {
    param([string[]]$Names)
    $seen = @{}
    foreach ($n in $Names) {
        foreach ($p in @(Get-Process -Name $n -ErrorAction SilentlyContinue)) {
            if ($null -eq $p -or $seen.ContainsKey($p.Id)) { continue }
            $seen[$p.Id] = $true
            $prev = $null
            try { $prev = [string]$p.PriorityClass } catch { }
            if ($prev) { @{ Id = $p.Id; Prev = $prev } }
        }
    }
}

function Set-ProcPriority {
    param([int]$Id, [string]$Priority)
    try {
        $p = Get-Process -Id $Id -ErrorAction SilentlyContinue
        if ($p) { $p.PriorityClass = $Priority }
    } catch { }
}

$script:Tunes = @{
    PowerSaving = @{
        Prev = {
            $ps = Get-WifiPowerSaving
            if ($null -eq $ps) { return $null }
            @{ Scheme = $ps.Scheme; Ac = $ps.Ac; Dc = $ps.Dc }
        }
        Do   = { param($r) Set-WifiPowerSaving -Scheme $r.Scheme -Ac 0 -Dc 0 }
        Undo = { param($r) Set-WifiPowerSaving -Scheme $r.Scheme -Ac $r.Ac -Dc $r.Dc }
    }
    ProcessPriority = @{
        Prev = {
            $recs = @(Get-ProcRecords @('RemotePlay'))
            if ($recs.Count -eq 0) { return $null }
            @{ Procs = $recs }
        }
        Do   = { param($r) foreach ($p in @($r.Procs)) { Set-ProcPriority $p.Id 'High' } }
        Undo = { param($r) foreach ($p in @($r.Procs)) { Set-ProcPriority $p.Id $p.Prev } }
    }
    PauseHogs = @{
        Prev = {
            $svc = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
            @{ WuauWasRunning = [bool]($svc -and $svc.Status -eq 'Running'); Procs = @(Get-ProcRecords $script:HogProcesses) }
        }
        Do   = {
            param($r)
            if ($r.WuauWasRunning) { Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue }
            foreach ($p in @($r.Procs)) { Set-ProcPriority $p.Id 'BelowNormal' }
        }
        Undo = {
            param($r)
            if ($r.WuauWasRunning) { Start-Service -Name wuauserv -ErrorAction SilentlyContinue }
            foreach ($p in @($r.Procs)) { Set-ProcPriority $p.Id $p.Prev }
        }
    }
    Qos = @{
        Prev = {
            if (Get-NetQosPolicy -Name $script:QosName -PolicyStore ActiveStore -ErrorAction SilentlyContinue) { return $null }
            @{ Name = $script:QosName }
        }
        Do   = { param($r) New-NetQosPolicy -Name $r.Name -AppPathNameMatchCondition 'RemotePlay.exe' -DSCPAction 46 -PolicyStore ActiveStore -ErrorAction Stop | Out-Null }
        Undo = { param($r) Remove-NetQosPolicy -Name $r.Name -PolicyStore ActiveStore -Confirm:$false -ErrorAction SilentlyContinue }
    }
}

function Invoke-TunerApply {
    param([string[]]$Actions)
    $admin = Test-IsAdmin
    $state = Read-State
    if ($null -eq $state) { $state = @{} }
    $applied = @(); $skipped = @()
    foreach ($a in $Actions) {
        if ($state.ContainsKey($a)) { $applied += $a; continue }
        if (($script:AdminOnly -contains $a) -and -not $admin) { $skipped += $a; continue }
        $t = $script:Tunes[$a]
        if ($null -eq $t) { $skipped += $a; continue }
        $rec = $null
        try { $rec = & $t.Prev } catch { }
        if ($null -eq $rec) { $skipped += $a; continue }
        $state[$a] = $rec
        Save-State $state
        try {
            & $t.Do $rec
            $applied += $a
        } catch {
            Write-Warning "Could not apply ${a}: $_"
            try { & $t.Undo $rec } catch { }
            $state.Remove($a)
            if ($state.Count -gt 0) { Save-State $state } else { Remove-Item (Get-StatePath) -Force -ErrorAction SilentlyContinue }
            $skipped += $a
        }
    }
    [pscustomobject]@{ Applied = $applied; Skipped = $skipped }
}

function Invoke-TunerRevert {
    $path = Get-StatePath
    $state = Read-State
    if ($null -ne $state) {
        foreach ($a in @($state.Keys)) {
            $t = $script:Tunes[$a]
            if ($null -eq $t) { continue }
            try { & $t.Undo $state[$a] } catch { Write-Warning "Could not revert ${a}: $_" }
        }
    }
    if (Test-Path $path) { Remove-Item $path -Force -ErrorAction SilentlyContinue }
}

function Test-TunerDirty { Test-Path (Get-StatePath) }

Export-ModuleMember -Function Get-WindowStats, Test-Freeze, Get-Cause, Get-Verdict,
    Get-StatePath, Test-IsAdmin, ConvertFrom-PowercfgQuery, Invoke-TunerApply, Invoke-TunerRevert, Test-TunerDirty
