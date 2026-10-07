# Pester 5 tests for the platform-independent parts of winctl.
#   Invoke-Pester -Path winctl/tests

BeforeAll {
    $lib = Join-Path (Join-Path $PSScriptRoot '..') 'lib'
    foreach ($name in 'Common', 'Services', 'Status', 'Power', 'Backup', 'Remote') { . (Join-Path $lib "$name.ps1") }

    $script:TempHome = Join-Path ([System.IO.Path]::GetTempPath()) ('winctl-test-' + [guid]::NewGuid())
    $script:TempConfig = Join-Path $script:TempHome 'config'
    New-Item -ItemType Directory -Path $script:TempConfig -Force | Out-Null
    $repoConfig = Join-Path (Join-Path (Join-Path $PSScriptRoot '..') '..') 'config'
    Copy-Item -Path (Join-Path $repoConfig '*.json') -Destination $script:TempConfig
    $env:WINCTL_HOME = Join-Path $script:TempHome 'data'
    $env:WINCTL_CONFIG_DIR = $script:TempConfig
}

AfterAll {
    Remove-Item -LiteralPath $script:TempHome -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\WINCTL_HOME, Env:\WINCTL_CONFIG_DIR -ErrorAction SilentlyContinue
}

Describe 'Configuration' {
    It 'merges nested objects and replaces arrays' {
        $base = '{"a":{"x":1,"y":2},"list":[1,2]}' | ConvertFrom-Json
        $over = '{"a":{"y":3},"list":[9]}' | ConvertFrom-Json
        $m = Merge-WinctlObject -Base $base -Override $over
        $m.a.x | Should -Be 1
        $m.a.y | Should -Be 3
        @($m.list) | Should -Be @(9)
    }

    It 'applies system.local.json over system.json' {
        Set-Content -LiteralPath (Join-Path $script:TempConfig 'system.local.json') -Value '{"machine":{"mac_address":"aa:bb:cc:dd:ee:ff"}}'
        try {
            $cfg = Get-WinctlConfig system
            $cfg.machine.mac_address | Should -Be 'aa:bb:cc:dd:ee:ff'
            $cfg.machine.name | Should -Be 'Alienware m17 R3'
        } finally {
            Remove-Item -LiteralPath (Join-Path $script:TempConfig 'system.local.json')
        }
    }

    It 'every mode references only defined services' {
        $services = Get-WinctlConfig services
        $defined = @($services.services.PSObject.Properties.Name)
        foreach ($mode in $services.modes.PSObject.Properties) {
            foreach ($key in @($mode.Value.start) + @($mode.Value.stop)) {
                if ($key) { $defined | Should -Contain $key }
            }
        }
        foreach ($key in $services.sleep_stop) { $defined | Should -Contain $key }
    }
}

Describe 'State' {
    It 'defaults to READY and round-trips' {
        (Get-WinctlState).mode | Should -Be 'READY'
        Set-WinctlMode 'game'
        (Get-WinctlState).mode | Should -Be 'GAME'
        Set-WinctlMode 'READY'
    }

    It 'rejects unknown modes' {
        { Set-WinctlMode 'TURBO' } | Should -Throw
    }
}

Describe 'Game detection' {
    It 'matches names with or without .exe, case-insensitively' {
        $found = Find-WinctlMatchingProcesses -Running @('explorer', 'Game', 'chrome') -Wanted @('game.exe', 'other.exe')
        @($found) | Should -Be @('game')
    }

    It 'never treats unknown processes as games' {
        @(Find-WinctlMatchingProcesses -Running @('steam', 'unknown') -Wanted @('game.exe')).Count | Should -Be 0
    }
}

Describe 'Resolve-WinctlState' {
    It 'returns the mode when everything is healthy' {
        Resolve-WinctlState -Mode 'WORK' -Checks @([pscustomobject]@{ ok = $true; severity = 'required' }) | Should -Be 'WORK'
    }
    It 'returns DEGRADED for a failed required check' {
        Resolve-WinctlState -Mode 'READY' -Checks @([pscustomobject]@{ ok = $false; severity = 'required' }) | Should -Be 'DEGRADED'
    }
    It 'returns ERROR for a failed critical check' {
        $checks = @([pscustomobject]@{ ok = $false; severity = 'required' }, [pscustomobject]@{ ok = $false; severity = 'critical' })
        Resolve-WinctlState -Mode 'READY' -Checks $checks | Should -Be 'ERROR'
    }
    It 'ignores failed info checks' {
        Resolve-WinctlState -Mode 'READY' -Checks @([pscustomobject]@{ ok = $false; severity = 'info' }) | Should -Be 'READY'
    }
    It 'does not keep a stale DEGRADED mode' {
        Resolve-WinctlState -Mode 'DEGRADED' -Checks @() | Should -Be 'READY'
    }
}

Describe 'Remote allowlist' {
    It 'accepts allowlisted commands' {
        Resolve-WinctlRemoteCommand 'status' | Should -Be 'status'
        Resolve-WinctlRemoteCommand '  SLEEP ' | Should -Be 'sleep'
    }
    It 'rejects everything else' -TestCases @(
        @{ c = '' }, @{ c = 'status --json; whoami' }, @{ c = 'powershell -c whoami' },
        @{ c = 'exec' }, @{ c = 'status&calc' }, @{ c = 'restore' }, @{ c = 'remote' }
    ) {
        Resolve-WinctlRemoteCommand $c | Should -BeNullOrEmpty
    }
    It 'maps task commands to scheduled task names' {
        Get-WinctlRemoteTaskName 'sleep' | Should -Be 'WinCtl-Sleep'
    }
}

Describe 'Robocopy arguments' {
    It 'never purges by default' {
        Get-WinctlRobocopyArgs -Source 'D:\W' -Destination 'E:\B' | Should -Not -Contain '/PURGE'
    }
    It 'purges only when mirror is enabled for backup' {
        Get-WinctlRobocopyArgs -Source 'D:\W' -Destination 'E:\B' -Mirror $true | Should -Contain '/PURGE'
    }
    It 'restore never purges and never overwrites newer files' {
        $a = Get-WinctlRobocopyArgs -Source 'E:\B' -Destination 'D:\W' -Mirror $true -Restore
        $a | Should -Not -Contain '/PURGE'
        $a | Should -Contain '/XO'
    }
    It 'passes excluded directories after /XD' {
        $a = Get-WinctlRobocopyArgs -Source 's' -Destination 'd' -ExcludeDirs @('node_modules', '.venv')
        $i = [array]::IndexOf($a, '/XD')
        $a[$i + 1] | Should -Be 'node_modules'
        $a[$i + 2] | Should -Be '.venv'
    }
}

Describe 'Sleep safety' {
    BeforeEach {
        Mock Get-WinctlRunningProcessNames { @('explorer') }
        Mock Get-WinctlActiveLocks { @() }
        Mock Get-WinctlInhibitingContainers { @() }
        Mock Stop-WinctlService { }
        Mock Stop-WinctlWslAll { }
        Mock Invoke-WinctlPowerAction { }
        Mock Send-WinctlNotification { }
        Set-WinctlMode 'READY'
        Set-WinctlStateField -Name inhibit_sleep -Value $false | Out-Null
    }

    It 'has no blockers on an idle PC' {
        @(Get-WinctlSleepBlockers -Night).Count | Should -Be 0
    }

    It 'blocks on a running game, a backup lock, an important process and a docker job' {
        Mock Get-WinctlRunningProcessNames { @('game', 'robocopy') }
        Mock Get-WinctlActiveLocks { @('backup') }
        Mock Get-WinctlInhibitingContainers { @('nightly-job') }
        $reasons = @(Get-WinctlSleepBlockers)
        $reasons | Should -Contain 'game running: game'
        $reasons | Should -Contain 'job in progress: backup'
        $reasons | Should -Contain 'important process running: robocopy'
        $reasons | Should -Contain 'docker job running: nightly-job'
    }

    It 'blocks night sleep in GAME mode and when inhibited' {
        Set-WinctlMode 'GAME'
        Set-WinctlStateField -Name inhibit_sleep -Value $true | Out-Null
        $reasons = @(Get-WinctlSleepBlockers -Night)
        $reasons | Should -Contain 'mode is GAME'
        ($reasons -join ';') | Should -Match 'inhibited'
    }

    It 'does not sleep while blocked' {
        Mock Get-WinctlRunningProcessNames { @('game') }
        Invoke-WinctlSleep -Night | Should -BeFalse
        Should -Invoke Invoke-WinctlPowerAction -Times 0
        (Get-WinctlState).mode | Should -Be 'READY'
    }

    It 'stops services and hibernates when safe' {
        Invoke-WinctlSleep -Night -NoPowerAction | Should -BeTrue
        Should -Invoke Stop-WinctlService -ParameterFilter { $Key -eq 'docker' }
        Should -Invoke Stop-WinctlWslAll -Times 1
        (Get-WinctlState).mode | Should -Be 'SLEEP'
        (Get-WinctlState).last_sleep | Should -Not -BeNullOrEmpty
    }

    It '--force overrides blockers' {
        Mock Get-WinctlRunningProcessNames { @('game') }
        Invoke-WinctlSleep -Force -NoPowerAction | Should -BeTrue
    }

    It 'night check stays on while a game runs' {
        Mock Get-WinctlRunningProcessNames { @('another-game') }
        Mock Invoke-WinctlSleep { $true }
        Invoke-WinctlNight
        Should -Invoke Invoke-WinctlSleep -Times 0
    }
}

Describe 'Format-WinctlStatus' {
    It 'renders the product.txt layout' {
        $status = [pscustomobject]@{
            name = 'Alienware m17 R3'; state = 'READY'; mode = 'READY'; uptime_seconds = 16320
            cpu = [pscustomobject]@{ percent = 4; temp_c = $null }
            memory = [pscustomobject]@{ used_gb = 12; total_gb = 64 }
            gpu = [pscustomobject]@{ percent = 3; vram_used_gb = 2; vram_total_gb = 8; temp_c = 40 }
            disks = @()
            services = [pscustomobject][ordered]@{ tailscale = 'OK'; ssh = 'OK' }
            checks = @([pscustomobject]@{ name = 'Workspace'; ok = $true })
            last_sleep = $null; last_wake = $null; last_error = $null; inhibit_sleep = $false
        }
        $text = Format-WinctlStatus $status
        $text | Should -Match 'State: READY'
        $text | Should -Match 'RAM: 12 / 64 GB'
        $text | Should -Match 'VRAM: 2 / 8 GB'
        $text | Should -Match 'Tailscale: OK'
        $text | Should -Match 'Workspace: OK'
        $text | Should -Match 'Uptime: 4h 32m'
    }
}

Describe 'winctl entry point' {
    BeforeAll { $script:Winctl = Join-Path (Join-Path $PSScriptRoot '..') 'winctl.ps1' }

    It 'passes dash options such as -n through to the command' {
        Add-WinctlHistory -Event 'test' -Detail 'one'
        Add-WinctlHistory -Event 'test' -Detail 'two'
        $out = @(& $script:Winctl history -n 1)
        $out.Count | Should -Be 1
        $out[0] | Should -Match '"two"'
    }

    It 'reports a missing backup drive clearly' {
        Set-Content -LiteralPath (Join-Path $script:TempConfig 'system.local.json') -Value '{"backup":{"target":"Q:\\Backups"}}'
        try {
            if ($env:OS -eq 'Windows_NT' -and (Test-Path 'Q:\')) { Set-ItResult -Skipped -Because 'Q: exists here' }
            { Assert-WinctlBackupTarget (Get-WinctlBackupPaths) } | Should -Throw '*not connected*'
        } finally {
            Remove-Item -LiteralPath (Join-Path $script:TempConfig 'system.local.json')
        }
    }
}
