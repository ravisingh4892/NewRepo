$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here '..\src\Stabilizer.psm1') -Force

Describe 'ConvertFrom-NetshWlan' {
    It 'reads the RSSI from a connected interface' {
        $text = @(
            'There is 1 interface on the system:',
            '    State                  : connected',
            '    Signal                 : 76% ',
            '    Rssi                   : -74')
        ConvertFrom-NetshWlan -Text $text | Should Be -74
    }
    It 'returns null when there is no Wi-Fi interface' {
        ConvertFrom-NetshWlan -Text @('The Wireless AutoConfig Service (wlansvc) is not running.') | Should Be $null
    }
    It 'returns null for empty input' {
        ConvertFrom-NetshWlan -Text @() | Should Be $null
    }
}

Describe 'Write-SessionLog' {
    It 'appends one valid JSON line per entry, each with a Time' {
        $path = Join-Path $TestDrive 'logs\session.jsonl'
        Write-SessionLog -Path $path -Entry @{ Cause = 'PS5-LINK'; Jitter = 41 }
        Write-SessionLog -Path $path -Entry @{ Cause = 'UNKNOWN'; Jitter = 5 }
        $lines = @(Get-Content $path)
        $lines.Count | Should Be 2
        foreach ($l in $lines) {
            $o = $l | ConvertFrom-Json
            [bool]$o.Time | Should Be $true
        }
        ($lines[0] | ConvertFrom-Json).Cause | Should Be 'PS5-LINK'
    }
}

Describe 'Start-ProbeAsync / Get-ProbeResult' {
    It 'completes with a number for loopback' {
        $t = Start-ProbeAsync -Target '127.0.0.1' -TimeoutMs 500
        $t.Task.Wait(2000) | Out-Null
        $r = Get-ProbeResult -Probe $t
        $r.Done | Should Be $true
        ($r.Rtt -ge 0) | Should Be $true
    }
    It 'completes with a null RTT for an unresolvable host' {
        $t = Start-ProbeAsync -Target 'no-such-host.invalid' -TimeoutMs 100
        try { $t.Task.Wait(3000) | Out-Null } catch { }
        $r = Get-ProbeResult -Probe $t
        $r.Done | Should Be $true
        $r.Rtt | Should Be $null
    }
}

Describe 'Select-Ps5Candidate' {
    It 'picks the first private address that is not excluded' {
        Select-Ps5Candidate -Addresses @('8.8.8.8', '10.86.1.1', '10.86.1.57', '192.168.0.9') -Exclude @('10.86.1.1') | Should Be '10.86.1.57'
    }
    It 'ignores loopback, link-local, public and IPv6 addresses' {
        Select-Ps5Candidate -Addresses @('127.0.0.1', '169.254.3.4', '8.8.8.8', '::1', 'fe80::1') -Exclude @() | Should Be $null
    }
    It 'returns null for no addresses' {
        Select-Ps5Candidate -Addresses @() -Exclude @() | Should Be $null
    }
}

Describe 'Send-Probe' {
    It 'returns null instead of throwing for an unresolvable target' {
        { Send-Probe -Target 'no-such-host.invalid' -TimeoutMs 100 } | Should Not Throw
        Send-Probe -Target 'no-such-host.invalid' -TimeoutMs 100 | Should Be $null
    }
    It 'returns a number for loopback' {
        $rtt = Send-Probe -Target '127.0.0.1' -TimeoutMs 500
        ($rtt -ge 0) | Should Be $true
    }
}
