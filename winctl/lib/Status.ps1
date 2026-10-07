# Hardware metrics, health checks and the combined status document (`winctl status [--json]`).

Set-StrictMode -Version 2.0

function Get-WinctlCpu {
    $load = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
    $temp = $null
    try {
        # Requires admin and is not exposed by every firmware; null when unavailable.
        $zone = Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop | Select-Object -First 1
        if ($zone) { $temp = [math]::Round(($zone.CurrentTemperature / 10) - 273.15, 0) }
    } catch { }
    return [pscustomobject]@{ percent = [int]$load; temp_c = $temp }
}

function Get-WinctlMemory {
    $os = Get-CimInstance Win32_OperatingSystem
    $totalGb = [math]::Round($os.TotalVisibleMemorySize / 1MB, 0)
    $usedGb = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB, 0)
    return [pscustomobject]@{ used_gb = $usedGb; total_gb = $totalGb }
}

function Get-WinctlGpu {
    $smi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if (-not $smi) { return $null }
    try {
        $line = & $smi.Source '--query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu' '--format=csv,noheader,nounits' | Select-Object -First 1
        $parts = $line -split ',\s*'
        return [pscustomobject]@{
            name          = $parts[0]
            percent       = [int]$parts[1]
            vram_used_gb  = [math]::Round([double]$parts[2] / 1024, 0)
            vram_total_gb = [math]::Round([double]$parts[3] / 1024, 0)
            temp_c        = [int]$parts[4]
        }
    } catch {
        return $null
    }
}

function Get-WinctlDisks {
    $disks = @()
    foreach ($d in Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3') {
        if (-not $d.Size) { continue }
        $disks += [pscustomobject]@{
            drive        = $d.DeviceID
            free_gb      = [math]::Round($d.FreeSpace / 1GB, 0)
            total_gb     = [math]::Round($d.Size / 1GB, 0)
            free_percent = [math]::Round(100 * $d.FreeSpace / $d.Size, 0)
        }
    }
    return $disks
}

function Get-WinctlUptimeSeconds {
    $os = Get-CimInstance Win32_OperatingSystem
    return [int]((Get-Date) - $os.LastBootUpTime).TotalSeconds
}

function Test-WinctlNetwork {
    $configs = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' })
    return ($configs.Count -gt 0)
}

function Test-WinctlTailscale {
    if ((Get-WinctlServiceStatus 'tailscale') -ne 'OK') { return $false }
    $exe = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
    if (-not (Test-Path -LiteralPath $exe)) { return $false }
    try {
        $json = & $exe status --json 2>$null | Out-String | ConvertFrom-Json
        return ($json.BackendState -eq 'Running')
    } catch {
        return $false
    }
}

function New-WinctlCheck {
    param([string]$Name, [bool]$Ok, [string]$Detail = '', [ValidateSet('required', 'critical', 'info')][string]$Severity = 'info')
    return [pscustomobject]@{ name = $Name; ok = $Ok; detail = $Detail; severity = $Severity }
}

# Pure: derives the reported state from the stored mode and the health checks.
#   any failed critical check -> ERROR
#   any failed required check -> DEGRADED
#   otherwise the stored mode (DEGRADED/ERROR are not sticky; they recover to READY)
function Resolve-WinctlState {
    param([Parameter(Mandatory)][string]$Mode, [object[]]$Checks = @())
    $failed = @($Checks | Where-Object { -not $_.ok })
    if (@($failed | Where-Object { $_.severity -eq 'critical' }).Count -gt 0) { return 'ERROR' }
    if (@($failed | Where-Object { $_.severity -eq 'required' }).Count -gt 0) { return 'DEGRADED' }
    if (@('DEGRADED', 'ERROR') -contains $Mode) { return 'READY' }
    return $Mode
}

$script:ServiceLabels = [ordered]@{
    tailscale = 'Tailscale'
    ssh       = 'SSH'
    wsl       = 'WSL2'
    docker    = 'Docker'
    smb       = 'SMB'
    parsec    = 'Parsec'
}

function Get-WinctlHealthChecks {
    param([Parameter(Mandatory)][string]$Mode)
    $system = Get-WinctlConfig system
    $required = Get-WinctlRequiredServices $Mode
    $checks = @()

    $checks += New-WinctlCheck -Name 'Windows' -Ok $true -Severity 'critical'
    $checks += New-WinctlCheck -Name 'Network' -Ok (Test-WinctlNetwork) -Severity 'critical' -Detail 'default gateway reachable'

    $serviceStatus = [ordered]@{}
    foreach ($key in $script:ServiceLabels.Keys) {
        $status = Get-WinctlServiceStatus $key
        if ($key -eq 'tailscale' -and $status -eq 'OK' -and -not (Test-WinctlTailscale)) { $status = 'LOGGED_OUT' }
        $serviceStatus[$key] = $status
        $severity = 'info'
        if ($required -contains $key) { $severity = 'required' }
        $checks += New-WinctlCheck -Name $script:ServiceLabels[$key] -Ok ($status -eq 'OK') -Detail $status -Severity $severity
    }

    $workspace = Get-WinctlWorkspacePath $system
    $checks += New-WinctlCheck -Name 'Workspace' -Ok (Test-Path -LiteralPath $workspace) -Detail $workspace -Severity 'required'

    foreach ($disk in Get-WinctlDisks) {
        $severity = 'required'
        if ($disk.drive -eq $env:SystemDrive) { $severity = 'critical' }
        $checks += New-WinctlCheck -Name "Disk $($disk.drive)" -Ok ($disk.free_percent -ge 5) -Detail "$($disk.free_gb) GB free ($($disk.free_percent)%)" -Severity $severity
    }

    return [pscustomobject]@{ checks = $checks; services = [pscustomobject]$serviceStatus }
}

function Get-WinctlStatus {
    $system = Get-WinctlConfig system
    $state = Get-WinctlState
    $health = Get-WinctlHealthChecks -Mode $state.mode
    return [pscustomobject][ordered]@{
        name           = $system.machine.name
        hostname       = $env:COMPUTERNAME
        mode           = $state.mode
        state          = Resolve-WinctlState -Mode $state.mode -Checks $health.checks
        power_state    = 'ON'
        uptime_seconds = Get-WinctlUptimeSeconds
        cpu            = Get-WinctlCpu
        memory         = Get-WinctlMemory
        gpu            = Get-WinctlGpu
        disks          = @(Get-WinctlDisks)
        services       = $health.services
        checks         = $health.checks
        last_sleep     = $state.last_sleep
        last_wake      = $state.last_wake
        last_error     = $state.last_error
        inhibit_sleep  = $state.inhibit_sleep
        time           = Get-WinctlTimestamp
    }
}

function Format-WinctlDuration {
    param([int]$Seconds)
    $ts = [TimeSpan]::FromSeconds($Seconds)
    if ($ts.Days -gt 0) { return '{0}d {1}h {2}m' -f $ts.Days, $ts.Hours, $ts.Minutes }
    return '{0}h {1}m' -f $ts.Hours, $ts.Minutes
}

function Format-WinctlStatus {
    param([Parameter(Mandatory)]$Status)
    $icon = switch ($Status.state) { 'ERROR' { '[ERROR]' } 'DEGRADED' { '[DEGRADED]' } default { '[OK]' } }
    $lines = @()
    $lines += "$icon $($Status.name)"
    $lines += ''
    $lines += "State: $($Status.state)   (mode: $($Status.mode))"
    $lines += ''
    $lines += "CPU: $($Status.cpu.percent)%" + $(if ($null -ne $Status.cpu.temp_c) { "  $($Status.cpu.temp_c)C" } else { '' })
    $lines += "RAM: $($Status.memory.used_gb) / $($Status.memory.total_gb) GB"
    if ($Status.gpu) {
        $lines += "GPU: $($Status.gpu.percent)%  $($Status.gpu.temp_c)C"
        $lines += "VRAM: $($Status.gpu.vram_used_gb) / $($Status.gpu.vram_total_gb) GB"
    }
    foreach ($d in $Status.disks) { $lines += "Disk $($d.drive): $($d.free_gb) / $($d.total_gb) GB free" }
    $lines += ''
    foreach ($p in $Status.services.PSObject.Properties) {
        $label = $script:ServiceLabels[$p.Name]
        $lines += ('{0}: {1}' -f $label, $p.Value)
    }
    $workspace = $Status.checks | Where-Object { $_.name -eq 'Workspace' } | Select-Object -First 1
    if ($workspace) { $lines += 'Workspace: ' + $(if ($workspace.ok) { 'OK' } else { 'MISSING' }) }
    $lines += ''
    $lines += "Uptime: $(Format-WinctlDuration $Status.uptime_seconds)"
    if ($Status.last_sleep) { $lines += "Last Sleep: $($Status.last_sleep)" }
    if ($Status.last_wake) { $lines += "Last Wake: $($Status.last_wake)" }
    if ($Status.last_error) { $lines += "Last Error: $($Status.last_error)" }
    if ($Status.inhibit_sleep) { $lines += 'Auto-sleep: INHIBITED' }
    return ($lines -join [Environment]::NewLine)
}
