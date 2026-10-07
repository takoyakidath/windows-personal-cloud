# Game detection, sleep safety checks, sleep/hibernate, night mode and boot/resume recovery.

Set-StrictMode -Version 2.0

function ConvertTo-WinctlProcessName {
    param([string]$Name)
    return ($Name.Trim() -replace '\.exe$', '').ToLowerInvariant()
}

# Pure: which configured names appear in the running process list. Unknown processes are never games.
function Find-WinctlMatchingProcesses {
    param([string[]]$Running = @(), [string[]]$Wanted = @())
    $runningSet = @{}
    foreach ($r in $Running) { if ($r) { $runningSet[(ConvertTo-WinctlProcessName $r)] = $true } }
    $found = @()
    foreach ($w in $Wanted) {
        if (-not $w) { continue }
        $n = ConvertTo-WinctlProcessName $w
        if ($runningSet.ContainsKey($n) -and $found -notcontains $n) { $found += $n }
    }
    return $found
}

function Get-WinctlRunningProcessNames {
    return @(Get-Process | ForEach-Object { $_.ProcessName })
}

function Get-WinctlRunningGames {
    $games = @(Get-WinctlProp (Get-WinctlConfig games) 'games' @())
    return @(Find-WinctlMatchingProcesses -Running (Get-WinctlRunningProcessNames) -Wanted $games)
}

function Get-WinctlInhibitingContainers {
    $system = Get-WinctlConfig system
    $label = Get-WinctlProp $system.power 'inhibit_docker_label' ''
    if (-not $label) { return @() }
    if ((Get-WinctlServiceStatus 'docker') -ne 'OK') { return @() }
    $r = Invoke-WinctlWsl -Arguments @('-d', $system.wsl.distro, '-u', 'root', '--', 'docker', 'ps', '--filter', "label=$label", '--format', '{{.Names}}')
    if ($r.ExitCode -ne 0 -or -not $r.Output) { return @() }
    return @($r.Output -split "`r?`n" | Where-Object { $_ })
}

# --- Wake sources: only the built-in Ethernet (magic packet) may wake the PC. ---

# Devices currently allowed to wake the PC (`powercfg /devicequery wake_armed`).
function Get-WinctlWakeArmedDevices {
    $out = @(& powercfg.exe /devicequery wake_armed 2>$null)
    return @($out | ForEach-Object { "$_".Trim() } | Where-Object { $_ -and $_ -ne 'NONE' })
}

# Pure: armed devices that are not the wake NIC and must be disarmed.
function Select-WinctlWakeDevicesToDisarm {
    param([string[]]$Armed = @(), [string]$Keep = '')
    return @($Armed | Where-Object { $_ -and $_.Trim() -and $_.Trim() -ne 'NONE' -and $_.Trim() -ne $Keep })
}

# The adapter used for Wake-on-LAN: machine.ethernet_adapter, else the first built-in wired NIC.
function Get-WinctlWakeAdapter {
    param($SystemConfig = (Get-WinctlConfig system))
    $adapter = Get-NetAdapter -Name $SystemConfig.machine.ethernet_adapter -Physical -ErrorAction SilentlyContinue
    if (-not $adapter) {
        $adapter = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
            Where-Object { $_.PhysicalMediaType -eq '802.3' -and $_.InterfaceDescription -notmatch 'USB' } |
            Select-Object -First 1
    }
    return $adapter
}

# Pure: when a "tonight only" inhibit ends - the next 06:00.
function Get-WinctlTonightUntil {
    param([Parameter(Mandatory)][DateTimeOffset]$Now)
    $six = New-Object DateTimeOffset ($Now.Year, $Now.Month, $Now.Day, 6, 0, 0, $Now.Offset)
    if ($Now -lt $six) { return $six }
    return $six.AddDays(1)
}

# Pure: is automatic sleep blocked by the user (permanently or until a time)?
function Test-WinctlInhibited {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][DateTimeOffset]$Now)
    if (Get-WinctlProp $State 'inhibit_sleep' $false) { return $true }
    $until = Get-WinctlProp $State 'inhibit_until' $null
    if (-not $until) { return $false }
    try { return ([DateTimeOffset]::Parse([string]$until) -gt $Now) } catch { return $false }
}

# Returns a list of human-readable reasons why the PC must not sleep now (empty = safe).
function Get-WinctlSleepBlockers {
    param([switch]$Night)
    $system = Get-WinctlConfig system
    $state = Get-WinctlState
    $reasons = @()

    if ($Night -and $state.mode -eq 'GAME') { $reasons += 'mode is GAME' }
    if (Test-WinctlInhibited -State $state -Now ([DateTimeOffset]::Now)) { $reasons += 'auto-sleep inhibited by user (winctl inhibit off to clear)' }

    foreach ($g in Get-WinctlRunningGames) { $reasons += "game running: $g" }
    foreach ($l in Get-WinctlActiveLocks) { $reasons += "job in progress: $l" }

    $inhibitProcs = @(Get-WinctlProp $system.power 'inhibit_processes' @())
    foreach ($p in Find-WinctlMatchingProcesses -Running (Get-WinctlRunningProcessNames) -Wanted $inhibitProcs) {
        $reasons += "important process running: $p"
    }
    foreach ($c in Get-WinctlInhibitingContainers) { $reasons += "docker job running: $c" }
    return $reasons
}

function Invoke-WinctlPowerAction {
    param([Parameter(Mandatory)][ValidateSet('hibernate', 'sleep', 'shutdown', 'none')][string]$Action)
    switch ($Action) {
        'hibernate' { & shutdown.exe /h }
        'sleep' {
            Add-Type -AssemblyName System.Windows.Forms
            [System.Windows.Forms.Application]::SetSuspendState([System.Windows.Forms.PowerState]::Suspend, $false, $false) | Out-Null
        }
        'shutdown'  { & shutdown.exe /s /t 0 }
        'none'      { Write-WinctlLog -Event 'sleep' -Message 'night_mode is none; staying on.' }
    }
}

# Stops services and enters the configured power state. Returns $true if it went to sleep.
function Invoke-WinctlSleep {
    param([switch]$Force, [switch]$Night, [switch]$NoPowerAction)
    $system = Get-WinctlConfig system
    $services = Get-WinctlConfig services

    $blockers = @(Get-WinctlSleepBlockers -Night:$Night)
    if ($blockers.Count -gt 0) {
        if (-not $Force) {
            $msg = 'Sleep skipped: ' + ($blockers -join '; ')
            Write-WinctlLog -Level WARN -Event 'sleep' -Message $msg
            Add-WinctlHistory -Event 'sleep-skipped' -Detail ($blockers -join '; ')
            return $false
        }
        Write-WinctlLog -Level WARN -Event 'sleep' -Message ('Forcing sleep despite: ' + ($blockers -join '; '))
    }

    $action = Get-WinctlProp $system.power 'night_mode' 'hibernate'
    Write-WinctlLog -Event 'sleep' -Message "Preparing to $action"
    Set-WinctlMode 'SLEEP'

    foreach ($key in @(Get-WinctlProp $services 'sleep_stop' @())) {
        try { Stop-WinctlService $key } catch { Write-WinctlLog -Level WARN -Event 'sleep' -Message "Failed to stop ${key}: $($_.Exception.Message)" }
    }
    Stop-WinctlWslAll

    # Keep SSH up briefly so the Raspberry Pi can observe mode=SLEEP and report HIBERNATED, not OFFLINE.
    $grace = [int](Get-WinctlProp $system.power 'sleep_grace_seconds' 0)
    if ($grace -gt 0 -and -not $NoPowerAction) { Start-Sleep -Seconds $grace }

    Set-WinctlStateField -Name 'last_sleep' -Value (Get-WinctlTimestamp) | Out-Null
    Add-WinctlHistory -Event 'sleep' -Detail $action
    if ($action -eq 'hibernate') { Send-WinctlNotification ([char]::ConvertFromUtf32(0x1F4A4) + ' Windows PC entered Hibernate.') }
    else { Send-WinctlNotification ([char]::ConvertFromUtf32(0x1F4A4) + " Windows PC entering $action.") }

    if (-not $NoPowerAction) { Invoke-WinctlPowerAction $action }
    return $true
}

# 21:00 scheduled task entry point.
function Invoke-WinctlNight {
    $games = @(Get-WinctlRunningGames)
    if ($games.Count -gt 0) {
        Write-WinctlLog -Event 'night' -Message ('Game running, staying on: ' + ($games -join ', '))
        Add-WinctlHistory -Event 'night' -Detail ('skip: game ' + ($games -join ', '))
        return
    }
    # product.txt §22 "Check backup": optionally back up first (skipped when the drive is not connected).
    $backup = (Get-WinctlConfig system).backup
    if ((Get-WinctlProp $backup 'before_night_sleep' $false) -and -not (Test-WinctlInhibited -State (Get-WinctlState) -Now ([DateTimeOffset]::Now))) {
        try { Invoke-WinctlBackup }
        catch { Write-WinctlLog -Level WARN -Event 'night' -Message "Backup before sleep failed: $($_.Exception.Message)" }
    }
    Add-WinctlHistory -Event 'night' -Detail 'no game; sleeping'
    Invoke-WinctlSleep -Night | Out-Null
}

function Wait-WinctlNetwork {
    param([int]$TimeoutSeconds = 90)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-WinctlNetwork) { return $true }
        Start-Sleep -Seconds 3
    }
    return $false
}

# Runs after boot, logon and resume from hibernate: bring services back and report health.
function Invoke-WinctlRecover {
    param([string]$Reason = 'boot')
    Write-WinctlLog -Event 'boot' -Message "Recovery started ($Reason)"
    Add-WinctlHistory -Event 'wake' -Detail $Reason
    Set-WinctlStateField -Name 'last_wake' -Value (Get-WinctlTimestamp) | Out-Null

    if (-not (Wait-WinctlNetwork)) { Write-WinctlLog -Level WARN -Event 'boot' -Message 'Network did not come up within timeout.' }

    $state = Get-WinctlState
    $mode = $state.mode
    if (@('SLEEP', 'DEGRADED', 'ERROR') -contains $mode) { $mode = 'READY' }
    Set-WinctlMode $mode

    $failed = @(Invoke-WinctlModeProfile $mode)
    $status = Get-WinctlStatus
    Add-WinctlHistory -Event 'health' -Detail $status.state

    if ($status.state -eq 'ERROR' -or $failed.Count -gt 0) {
        $bad = @($status.checks | Where-Object { -not $_.ok } | ForEach-Object { $_.name }) + $failed
        $detail = ($bad | Select-Object -Unique) -join ', '
        Set-WinctlLastError "Recovery problems: $detail"
        Send-WinctlNotification ([char]::ConvertFromUtf32(0x1F534) + " Windows PC failed health check: $detail")
    } elseif ($status.state -eq 'DEGRADED') {
        $bad = @($status.checks | Where-Object { -not $_.ok } | ForEach-Object { $_.name }) -join ', '
        Send-WinctlNotification ([char]::ConvertFromUtf32(0x1F7E1) + " Windows PC is up but DEGRADED: $bad")
    } else {
        Send-WinctlNotification ([char]::ConvertFromUtf32(0x1F7E2) + ' Windows PC is ready.')
    }
    Write-WinctlLog -Event 'boot' -Message "Recovery finished: $($status.state)"
    return $status
}
