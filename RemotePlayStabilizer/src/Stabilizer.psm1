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

Export-ModuleMember -Function Get-WindowStats, Test-Freeze, Get-Cause, Get-Verdict
