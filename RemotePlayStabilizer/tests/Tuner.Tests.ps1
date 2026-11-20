$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here '..\src\Stabilizer.psm1') -Force

# Every external side effect is mocked: these tests never touch the real system.
$global:AllActions = @('PowerSaving', 'ProcessPriority', 'PauseHogs', 'Qos')

function Reset-Fakes {
    $env:RPS_STATE_DIR = Join-Path $TestDrive ([guid]::NewGuid().ToString())
    $global:FakeRP = [pscustomobject]@{ Id = 111; Name = 'RemotePlay'; PriorityClass = 'Normal' }
    $global:FakeHog = [pscustomobject]@{ Id = 222; Name = 'OneDrive'; PriorityClass = 'Normal' }
    $global:RpRunning = $true
    $global:IsAdminFake = $true
    $global:PowerFail = $false
}

Describe 'Tuner apply and revert' {
Mock -ModuleName Stabilizer Test-IsAdmin { $global:IsAdminFake }
Mock -ModuleName Stabilizer Get-WifiPowerSaving { @{ Scheme = 'scheme-1'; Ac = 3; Dc = 2 } }
Mock -ModuleName Stabilizer Set-WifiPowerSaving { if ($global:PowerFail) { throw 'powercfg failed' } }
Mock -ModuleName Stabilizer Get-Service { [pscustomobject]@{ Status = 'Running' } }
Mock -ModuleName Stabilizer Stop-Service { }
Mock -ModuleName Stabilizer Start-Service { }
Mock -ModuleName Stabilizer Get-NetQosPolicy { $null }
Mock -ModuleName Stabilizer New-NetQosPolicy { }
Mock -ModuleName Stabilizer Remove-NetQosPolicy { }
Mock -ModuleName Stabilizer Get-Process { if ($global:RpRunning) { $global:FakeRP } } -ParameterFilter { $Name -eq 'RemotePlay' }
Mock -ModuleName Stabilizer Get-Process { $global:FakeHog } -ParameterFilter { $Name -eq 'OneDrive' }
Mock -ModuleName Stabilizer Get-Process { $null } -ParameterFilter { $Name -eq 'steamwebhelper' }
Mock -ModuleName Stabilizer Get-Process { if ($global:RpRunning) { $global:FakeRP } } -ParameterFilter { $Id -eq 111 }
Mock -ModuleName Stabilizer Get-Process { $global:FakeHog } -ParameterFilter { $Id -eq 222 }

    It 'applies all actions, records state, and reverts them' {
        Reset-Fakes
        $r = Invoke-TunerApply -Actions $global:AllActions
        ($r.Applied | Sort-Object) -join ',' | Should Be (($global:AllActions | Sort-Object) -join ',')
        @($r.Skipped).Count | Should Be 0
        Test-TunerDirty | Should Be $true
        $global:FakeRP.PriorityClass | Should Be 'High'
        Assert-MockCalled -ModuleName Stabilizer Set-WifiPowerSaving -Times 1 -ParameterFilter { $Ac -eq 0 -and $Dc -eq 0 }
        Assert-MockCalled -ModuleName Stabilizer New-NetQosPolicy -Times 1
        Assert-MockCalled -ModuleName Stabilizer Stop-Service -Times 1

        Invoke-TunerRevert
        $global:FakeRP.PriorityClass | Should Be 'Normal'
        $global:FakeHog.PriorityClass | Should Be 'Normal'
        Assert-MockCalled -ModuleName Stabilizer Set-WifiPowerSaving -Times 1 -ParameterFilter { $Ac -eq 3 -and $Dc -eq 2 }
        Assert-MockCalled -ModuleName Stabilizer Remove-NetQosPolicy -Times 1
        Assert-MockCalled -ModuleName Stabilizer Start-Service -Times 1
        Test-TunerDirty | Should Be $false
        Test-Path (Get-StatePath) | Should Be $false
    }

    It 'parses powercfg query output' {
        $text = @('  Current AC Power Setting Index: 0x00000003', '  Current DC Power Setting Index: 0x00000001')
        $v = ConvertFrom-PowercfgQuery -Text $text
        $v.Ac | Should Be 3
        $v.Dc | Should Be 1
        ConvertFrom-PowercfgQuery -Text @('nothing useful') | Should Be $null
    }

    It 'keeps admin-only records when reverting without admin, and clears them once admin' {
        Reset-Fakes
        Invoke-TunerApply -Actions $global:AllActions | Out-Null
        $global:IsAdminFake = $false
        Invoke-TunerRevert
        Test-TunerDirty | Should Be $true
        Assert-MockCalled -ModuleName Stabilizer Start-Service -Times 0 -Scope It
        Assert-MockCalled -ModuleName Stabilizer Remove-NetQosPolicy -Times 0 -Scope It
        $global:FakeRP.PriorityClass | Should Be 'Normal'
        $global:IsAdminFake = $true
        Invoke-TunerRevert
        Test-TunerDirty | Should Be $false
        Assert-MockCalled -ModuleName Stabilizer Remove-NetQosPolicy -Times 1 -Scope It
        Assert-MockCalled -ModuleName Stabilizer Start-Service -Times 1 -Scope It
        $global:FakeHog.PriorityClass | Should Be 'Normal'
    }

    It 'keeps a record whose undo failed, so a later revert can retry' {
        Reset-Fakes
        Invoke-TunerApply -Actions @('PowerSaving') | Out-Null
        $global:PowerFail = $true
        Invoke-TunerRevert 3>$null
        Test-TunerDirty | Should Be $true
        $global:PowerFail = $false
        Invoke-TunerRevert
        Test-TunerDirty | Should Be $false
        Assert-MockCalled -ModuleName Stabilizer Set-WifiPowerSaving -Times 1 -ParameterFilter { $Ac -eq 3 -and $Dc -eq 2 }
    }

    It 'revert is a no-op the second time' {
        Reset-Fakes
        Invoke-TunerApply -Actions $global:AllActions | Out-Null
        Invoke-TunerRevert
        { Invoke-TunerRevert } | Should Not Throw
        Assert-MockCalled -ModuleName Stabilizer Remove-NetQosPolicy -Times 1
    }

    It 'skips admin-only actions when not elevated but still raises priority' {
        Reset-Fakes
        $global:IsAdminFake = $false
        $r = Invoke-TunerApply -Actions $global:AllActions
        (@($r.Skipped) | Sort-Object) -join ',' | Should Be 'PauseHogs,PowerSaving,Qos'
        (@($r.Applied)) -join ',' | Should Be 'ProcessPriority'
        $global:FakeRP.PriorityClass | Should Be 'High'
        Invoke-TunerRevert
    }

    It 'keeps the original previous values when applied twice' {
        Reset-Fakes
        Invoke-TunerApply -Actions $global:AllActions | Out-Null
        Invoke-TunerApply -Actions $global:AllActions | Out-Null
        Invoke-TunerRevert
        $global:FakeRP.PriorityClass | Should Be 'Normal'
    }

    It 'skips ProcessPriority when Remote Play is not running' {
        Reset-Fakes
        $global:RpRunning = $false
        $r = Invoke-TunerApply -Actions @('ProcessPriority')
        (@($r.Skipped)) -join ',' | Should Be 'ProcessPriority'
        Test-TunerDirty | Should Be $false
    }

    It 'reverts cleanly when a process vanished meanwhile' {
        Reset-Fakes
        Invoke-TunerApply -Actions @('ProcessPriority') | Out-Null
        $global:RpRunning = $false
        { Invoke-TunerRevert } | Should Not Throw
        Test-TunerDirty | Should Be $false
    }
}
