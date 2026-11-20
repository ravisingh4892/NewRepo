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
