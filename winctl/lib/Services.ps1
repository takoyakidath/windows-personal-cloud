# Service control driven by config/services.json.
# Service types:
#   windows_service  - a Windows service (Get-Service name)
#   wsl              - the configured WSL2 distro itself
#   wsl_systemd      - a systemd unit inside the WSL2 distro (e.g. docker)

Set-StrictMode -Version 2.0

# Runs wsl.exe and returns its stdout as clean text (wsl.exe writes UTF-16 unless WSL_UTF8 is set).
function Invoke-WinctlWsl {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $env:WSL_UTF8 = '1'
    $output = & wsl.exe @Arguments 2>&1 | Out-String
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = ($output -replace "`0", '').Trim()
    }
}

function Get-WinctlDistro {
    return (Get-WinctlConfig system).wsl.distro
}

function Test-WinctlWslRunning {
    $distro = Get-WinctlDistro
    $result = Invoke-WinctlWsl -Arguments @('--list', '--running', '--quiet')
    if ($result.ExitCode -ne 0) { return $false }
    $names = $result.Output -split "`r?`n" | ForEach-Object { $_.Trim() }
    return ($names -contains $distro)
}

function Get-WinctlServiceDefinition {
    param([Parameter(Mandatory)][string]$Key)
    $services = (Get-WinctlConfig services).services
    $def = $services.PSObject.Properties[$Key]
    if (-not $def) { throw "Unknown service in services.json: $Key" }
    return $def.Value
}

# Returns OK | STOPPED | MISSING | UNKNOWN. Never starts anything (checking WSL must not wake it).
function Get-WinctlServiceStatus {
    param([Parameter(Mandatory)][string]$Key)
    $def = Get-WinctlServiceDefinition $Key
    try {
        switch ($def.type) {
            'windows_service' {
                $svc = Get-Service -Name $def.name -ErrorAction SilentlyContinue
                if (-not $svc) { return 'MISSING' }
                if ($svc.Status -eq 'Running') { return 'OK' }
                return 'STOPPED'
            }
            'wsl' {
                if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return 'MISSING' }
                if (Test-WinctlWslRunning) { return 'OK' }
                return 'STOPPED'
            }
            'wsl_systemd' {
                if (-not (Test-WinctlWslRunning)) { return 'STOPPED' }
                $r = Invoke-WinctlWsl -Arguments @('-d', (Get-WinctlDistro), '-u', 'root', '--', 'systemctl', 'is-active', $def.unit)
                if ($r.Output -eq 'active') { return 'OK' }
                if ($r.Output -match 'inactive|failed|activating') { return 'STOPPED' }
                return 'MISSING'
            }
            default { return 'UNKNOWN' }
        }
    } catch {
        return 'UNKNOWN'
    }
}

function Start-WinctlService {
    param([Parameter(Mandatory)][string]$Key)
    $def = Get-WinctlServiceDefinition $Key
    if ((Get-WinctlServiceStatus $Key) -eq 'OK') { return }
    switch ($def.type) {
        'windows_service' {
            $svc = Get-Service -Name $def.name -ErrorAction SilentlyContinue
            if (-not $svc) { Write-WinctlLog -Level WARN -Event 'service' -Message "$Key ($($def.name)) is not installed."; return }
            Start-Service -Name $def.name
        }
        'wsl' {
            # WSL stops an idle distro, so a long-lived `sleep infinity` keeps it (and Docker) up.
            # It runs as a scheduled task so it is not killed when an SSH session that started it ends.
            $task = Get-ScheduledTask -TaskName 'WinCtl-WslKeepAlive' -TaskPath '\winctl\' -ErrorAction SilentlyContinue
            if ($task) {
                Start-ScheduledTask -TaskName 'WinCtl-WslKeepAlive' -TaskPath '\winctl\'
            } else {
                Start-Process -FilePath 'wsl.exe' -ArgumentList @('-d', (Get-WinctlDistro), '-u', 'root', '--', 'sleep', 'infinity') -WindowStyle Hidden
            }
            $deadline = (Get-Date).AddSeconds(60)
            while (-not (Test-WinctlWslRunning)) {
                if ((Get-Date) -gt $deadline) { throw 'WSL distro did not start within 60s.' }
                Start-Sleep -Seconds 2
            }
        }
        'wsl_systemd' {
            Start-WinctlService 'wsl'
            $r = Invoke-WinctlWsl -Arguments @('-d', (Get-WinctlDistro), '-u', 'root', '--', 'systemctl', 'start', $def.unit)
            if ($r.ExitCode -ne 0) { throw "Failed to start $($def.unit): $($r.Output)" }
        }
    }
    Write-WinctlLog -Event 'service' -Message "Started $Key"
}

function Stop-WinctlService {
    param([Parameter(Mandatory)][string]$Key)
    $def = Get-WinctlServiceDefinition $Key
    if ((Get-WinctlServiceStatus $Key) -ne 'OK') { return }
    switch ($def.type) {
        'windows_service' { Stop-Service -Name $def.name -Force }
        'wsl'             { Invoke-WinctlWsl -Arguments @('--terminate', (Get-WinctlDistro)) | Out-Null }
        'wsl_systemd'     { Invoke-WinctlWsl -Arguments @('-d', (Get-WinctlDistro), '-u', 'root', '--', 'systemctl', 'stop', $def.unit) | Out-Null }
    }
    Write-WinctlLog -Event 'service' -Message "Stopped $Key"
}

function Get-WinctlModeProfile {
    param([Parameter(Mandatory)][string]$Mode)
    $modes = (Get-WinctlConfig services).modes
    $prop = $modes.PSObject.Properties[$Mode.ToUpperInvariant()]
    if (-not $prop) { $prop = $modes.PSObject.Properties['READY'] }
    return $prop.Value
}

# Services that must be running for a mode to count as healthy.
function Get-WinctlRequiredServices {
    param([Parameter(Mandatory)][string]$Mode)
    if (@('SLEEP') -contains $Mode) { return @() }
    $winctlProfile = Get-WinctlModeProfile $Mode
    return @(Get-WinctlProp $winctlProfile 'start' @())
}

# Applies a mode profile: stop first (frees resources), then start. Returns names that failed.
function Invoke-WinctlModeProfile {
    param([Parameter(Mandatory)][string]$Mode)
    $winctlProfile = Get-WinctlModeProfile $Mode
    $failed = @()
    foreach ($key in @(Get-WinctlProp $winctlProfile 'stop' @())) {
        try { Stop-WinctlService $key } catch { $failed += $key; Write-WinctlLog -Level WARN -Event 'service' -Message "Failed to stop ${key}: $($_.Exception.Message)" }
    }
    foreach ($key in @(Get-WinctlProp $winctlProfile 'start' @())) {
        try { Start-WinctlService $key } catch { $failed += $key; Write-WinctlLog -Level WARN -Event 'service' -Message "Failed to start ${key}: $($_.Exception.Message)" }
    }
    foreach ($project in @(Get-WinctlProp $winctlProfile 'compose' @())) {
        try { Start-WinctlComposeProject $project } catch { $failed += "compose:$project"; Write-WinctlLog -Level WARN -Event 'service' -Message "Failed to start compose project ${project}: $($_.Exception.Message)" }
    }
    return $failed
}

# Starts a Docker Compose project located inside the WSL filesystem (e.g. ~/services/app).
function Start-WinctlComposeProject {
    param([Parameter(Mandatory)][string]$Path)
    $system = Get-WinctlConfig system
    $quoted = "'" + ($Path -replace "'", "'\''") + "'"
    $quoted = $quoted -replace "^'~/", "~/'"
    $r = Invoke-WinctlWsl -Arguments @('-d', $system.wsl.distro, '-u', $system.wsl.default_user, '--', 'bash', '-lc', "cd $quoted && docker compose up -d")
    if ($r.ExitCode -ne 0) { throw $r.Output }
    Write-WinctlLog -Event 'service' -Message "Compose project up: $Path"
}

function Stop-WinctlWslAll {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return }
    Invoke-WinctlWsl -Arguments @('--shutdown') | Out-Null
    Write-WinctlLog -Event 'service' -Message 'WSL shut down'
}
