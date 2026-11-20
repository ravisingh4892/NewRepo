$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here '..\src\Stabilizer.psm1') -Force

function New-Stats($j, $l) { [pscustomobject]@{ Jitter = $j; Loss = $l; Avg = 10; Count = 25 } }

Describe 'Get-WindowStats' {
    It 'is zero for a steady link' {
        $s = Get-WindowStats -Samples @(10, 10, 10, 10)
        $s.Jitter | Should Be 0
        $s.Loss | Should Be 0
    }
    It 'counts loss and jitter' {
        $s = Get-WindowStats -Samples @(10, 50, $null, 10)
        $s.Loss | Should Be 0.25
        $s.Jitter | Should Be 40
    }
    It 'treats an all-lost window as total loss' {
        $s = Get-WindowStats -Samples @($null, $null)
        $s.Loss | Should Be 1
    }
    It 'handles an empty window' {
        $s = Get-WindowStats -Samples @()
        $s.Count | Should Be 0
        $s.Loss | Should Be 0
    }
}

Describe 'Test-Freeze' {
    It 'fires above the jitter threshold' { Test-Freeze -Stats (New-Stats 31 0) | Should Be $true }
    It 'fires above the loss threshold' { Test-Freeze -Stats (New-Stats 0 0.08) | Should Be $true }
    It 'ignores a single lost sample' { Test-Freeze -Stats (New-Stats 0 0.04) | Should Be $false }
    It 'does not fire at the thresholds' { Test-Freeze -Stats (New-Stats 30 0.02) | Should Be $false }
}

Describe 'Get-Cause' {
    $ok = New-Stats 1 0
    $bad = New-Stats 50 0
    It 'blames a weak PC radio link' {
        Get-Cause -Rssi -74 -Router $ok -Ps5 $ok -Internet $ok | Should Be 'PC-WIFI-WEAK'
    }
    It 'blames the PC link when the router probe is bad' {
        Get-Cause -Rssi -50 -Router $bad -Ps5 $ok -Internet $ok | Should Be 'PC-WIFI-WEAK'
    }
    It 'blames the PS5 even when the PC signal is weak but the router is clean' {
        Get-Cause -Rssi -74 -Router $ok -Ps5 $bad -Internet $ok | Should Be 'PS5-LINK'
    }
    It 'blames router or internet even when the PC signal is weak' {
        Get-Cause -Rssi -74 -Router $ok -Ps5 $ok -Internet $bad | Should Be 'ROUTER-OR-INTERNET'
    }
    It 'blames the PS5 link' {
        Get-Cause -Rssi -50 -Router $ok -Ps5 $bad -Internet $ok | Should Be 'PS5-LINK'
    }
    It 'blames router or internet' {
        Get-Cause -Rssi -50 -Router $ok -Ps5 $ok -Internet $bad | Should Be 'ROUTER-OR-INTERNET'
    }
    It 'is unknown when nothing is bad' {
        Get-Cause -Rssi -50 -Router $ok -Ps5 $ok -Internet $ok | Should Be 'UNKNOWN'
    }
    It 'never blames the PS5 when it is unmeasured' {
        Get-Cause -Rssi -50 -Router $ok -Ps5 $null -Internet $ok | Should Be 'UNKNOWN'
    }
    It 'tolerates an unknown RSSI' {
        Get-Cause -Rssi $null -Router $ok -Ps5 $bad -Internet $ok | Should Be 'PS5-LINK'
    }
}

Describe 'Get-Severity' {
    It 'is null when nothing is wrong' { Get-Severity -Stats (New-Stats 5 0) | Should Be $null }
    It 'is BLIP for a couple of lost pings' { Get-Severity -Stats (New-Stats 8 0.08) | Should Be 'BLIP' }
    It 'is BLIP for moderate jitter' { Get-Severity -Stats (New-Stats 31 0) | Should Be 'BLIP' }
    It 'is STALL for heavy loss' { Get-Severity -Stats (New-Stats 0 0.24) | Should Be 'STALL' }
    It 'is STALL for very high jitter' { Get-Severity -Stats (New-Stats 75 0) | Should Be 'STALL' }
    It 'is null for unmeasured' { Get-Severity -Stats $null | Should Be $null }
}

Describe 'Get-LinkGrade' {
    It 'needs enough samples before grading' { Get-LinkGrade -Sent 50 -Lost 0 | Should Be $null }
    It 'is GOOD under 0.5% loss' { Get-LinkGrade -Sent 1000 -Lost 2 | Should Be 'GOOD' }
    It 'is MARGINAL from 0.5% to under 2%' { Get-LinkGrade -Sent 1000 -Lost 8 | Should Be 'MARGINAL' }
    It 'is POOR at 2% or more' { Get-LinkGrade -Sent 1000 -Lost 30 | Should Be 'POOR' }
}

Describe 'Get-Verdict stalls and blips' {
    It 'separates stalls from blips and gives PS5-specific fixes' {
        $ev = @([pscustomobject]@{ Cause = 'PS5-LINK'; Severity = 'STALL' },
            [pscustomobject]@{ Cause = 'PS5-LINK'; Severity = 'BLIP' }, [pscustomobject]@{ Cause = 'PS5-LINK'; Severity = 'BLIP' })
        $v = Get-Verdict -Events $ev
        $v | Should Match '1 stall'
        $v | Should Match '2 minor'
        $v | Should Match '5 GHz'
        $v | Should Match '720p'
    }
    It 'does not let many blips outvote the cause of a real stall' {
        $ev = @(1..5 | ForEach-Object { [pscustomobject]@{ Cause = 'PC-WIFI-WEAK'; Severity = 'BLIP' } }) +
            @([pscustomobject]@{ Cause = 'PS5-LINK'; Severity = 'STALL' })
        Get-Verdict -Events $ev | Should Match 'PS5'
    }
    It 'says there were no real stalls when only blips happened' {
        $ev = @([pscustomobject]@{ Cause = 'PS5-LINK'; Severity = 'BLIP' })
        Get-Verdict -Events $ev | Should Match 'no real stalls'
    }
}

Describe 'Get-Verdict' {
    It 'says so when there were no freezes' {
        Get-Verdict -Events @() | Should Match 'No freezes recorded'
    }
    It 'advises a cable when the PS5 link dominates' {
        $ev = @(
            [pscustomobject]@{ Cause = 'PS5-LINK' }, [pscustomobject]@{ Cause = 'PS5-LINK' },
            [pscustomobject]@{ Cause = 'PS5-LINK' }, [pscustomobject]@{ Cause = 'PC-WIFI-WEAK' })
        Get-Verdict -Events $ev | Should Match 'cable'
    }
    It 'admits software cannot fix a weak PC radio link' {
        $ev = @([pscustomobject]@{ Cause = 'PC-WIFI-WEAK' })
        Get-Verdict -Events $ev | Should Match 'cannot fix'
    }
}
