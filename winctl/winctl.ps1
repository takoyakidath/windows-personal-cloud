# winctl - manage the Windows Personal Cloud PC (product.txt §17).
# Usage: winctl <command> [options]. Run `winctl help` for the list.

param(
    [Parameter(Position = 0)][string]$Command = 'help',
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Rest = @()
)

$ErrorActionPreference = 'Stop'
foreach ($lib in 'Common', 'Services', 'Status', 'Power', 'Backup', 'Remote') {
    . (Join-Path (Join-Path $PSScriptRoot 'lib') "$lib.ps1")
}

function Test-Flag { param([string]$Name) return ($Rest -contains $Name) }

function Get-Option {
    param([string]$Name, $Default)
    $i = [array]::IndexOf($Rest, $Name)
    if ($i -ge 0 -and $i + 1 -lt $Rest.Count) { return $Rest[$i + 1] }
    return $Default
}

function Show-Help {
    @'
winctl - Windows Personal Cloud controller

  status [--json]           Hardware, services and health summary
  doctor [--json]           Detailed health checks (exit 1 = DEGRADED, 2 = ERROR)
  mode [MODE]               Show or set mode (READY, GAME, WORK, SERVER)
  ready | game | work | server
                            Switch mode and start/stop services for it
  sleep [--force]           Stop services and enter the configured power state
  wake                      Recover services after boot/resume and return to READY
  inhibit on|tonight|off    Block automatic night sleep (tonight = until 06:00) / allow it
  services [start|stop NAME]
                            List services or control one
  disk                      Disk usage
  backup [verify]           Back up the workspace (or check it is up to date)
  restore [--yes]           Copy the backup back into the workspace (never deletes)
  sync                      git pull the configuration repository
  update [--packages]       sync + re-run the idempotent installer (+ winget upgrades)
  reboot | shutdown         Stop WSL cleanly, then reboot / shut down
  logs [-n N]               Show today's log
  history [-n N]            Show recent events
'@ | Write-Host
}

function Invoke-ModeCommand {
    param([string]$Mode)
    $Mode = $Mode.ToUpperInvariant()
    if (@('READY', 'GAME', 'WORK', 'SERVER') -notcontains $Mode) { throw "Mode must be READY, GAME, WORK or SERVER (got $Mode)." }
    Set-WinctlMode $Mode
    $failed = @(Invoke-WinctlModeProfile $Mode)
    if ($failed.Count -gt 0) { Write-WinctlLog -Level WARN -Event 'mode' -Message ('Mode set, but these failed: ' + ($failed -join ', ')) }
    else { Write-WinctlLog -Event 'mode' -Message "Mode: $Mode" }
}

function Invoke-Doctor {
    $status = Get-WinctlStatus
    if (Test-Flag '--json') { Write-WinctlJson $status }
    else {
        foreach ($c in $status.checks) {
            $mark = if ($c.ok) { ' OK ' } elseif ($c.severity -eq 'info') { ' -- ' } else { 'FAIL' }
            Write-Host ('[{0}] {1,-12} {2}' -f $mark, $c.name, $c.detail)
        }
        Write-Host ''
        Write-Host "State: $($status.state)"
        if (-not (Test-WinctlTailscale)) { Write-Host 'Hint: run "tailscale up" to log in to Tailscale.' -ForegroundColor Yellow }
    }
    switch ($status.state) { 'ERROR' { exit 2 } 'DEGRADED' { exit 1 } default { exit 0 } }
}

function Invoke-Sync {
    $repo = $script:RepoRoot
    if (-not (Test-Path -LiteralPath (Join-Path $repo '.git'))) { throw "$repo is not a git checkout." }
    & git -C $repo pull --ff-only
    if ($LASTEXITCODE -ne 0) { throw 'git pull failed (local changes?).' }
    Add-WinctlHistory -Event 'sync' -Detail (& git -C $repo rev-parse --short HEAD)
}

function Invoke-Update {
    Assert-WinctlAdmin
    Invoke-Sync
    if (Test-Flag '--packages') {
        foreach ($id in @((Get-WinctlConfig system).packages)) {
            & winget upgrade --id $id --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Null
        }
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:RepoRoot 'installer\install.ps1')
    if ($LASTEXITCODE -ne 0) { throw "Installer exited with $LASTEXITCODE" }
    Add-WinctlHistory -Event 'update' -Detail 'ok'
}

function Invoke-Restart {
    param([ValidateSet('reboot', 'shutdown')][string]$Kind)
    Write-WinctlLog -Event 'power' -Message "Preparing to $Kind"
    Add-WinctlHistory -Event $Kind
    Stop-WinctlWslAll
    if ($Kind -eq 'reboot') { & shutdown.exe /r /t 5 } else { & shutdown.exe /s /t 5 }
}

function Show-Services {
    $services = (Get-WinctlConfig services).services
    foreach ($p in $services.PSObject.Properties) {
        Write-Host ('{0,-10} {1,-16} {2}' -f $p.Name, $p.Value.type, (Get-WinctlServiceStatus $p.Name))
    }
}

function Show-Tail {
    param([string]$Path, [int]$Count)
    if (-not (Test-Path -LiteralPath $Path)) { Write-Host "No log at $Path"; return }
    Get-Content -LiteralPath $Path -Tail $Count -Encoding UTF8
}

try {
    switch ($Command.ToLowerInvariant()) {
        'help'     { Show-Help }
        'status' {
            $status = Get-WinctlStatus
            if (Test-Flag '--json') { Write-WinctlJson $status } else { Write-Host (Format-WinctlStatus $status) }
        }
        'doctor'   { Invoke-Doctor }
        'mode' {
            if ($Rest.Count -eq 0) { Write-Host (Get-WinctlState).mode } else { Invoke-ModeCommand $Rest[0] }
        }
        'ready'    { Invoke-ModeCommand 'READY' }
        'game'     { Invoke-ModeCommand 'GAME' }
        'work'     { Invoke-ModeCommand 'WORK' }
        'server'   { Invoke-ModeCommand 'SERVER' }
        'sleep' {
            if (-not (Invoke-WinctlSleep -Force:(Test-Flag '--force'))) { exit 3 }
        }
        'night'    { Invoke-WinctlNight }
        'wake'     { Invoke-WinctlRecover -Reason (Get-Option '--reason' 'manual') | Out-Null }
        'recover'  { Invoke-WinctlRecover -Reason (Get-Option '--reason' 'boot') | Out-Null }
        'inhibit' {
            $value = 'on'
            if ($Rest.Count -gt 0) { $value = $Rest[0].ToLowerInvariant() }
            Set-WinctlInhibit -Value $value
            $state = Get-WinctlState
            if ($value -eq 'off') { Write-Host 'Automatic sleep is now ALLOWED' }
            elseif ($state.inhibit_until) { Write-Host "Automatic sleep is BLOCKED until $($state.inhibit_until)" }
            else { Write-Host 'Automatic sleep is now BLOCKED' }
        }
        'services' {
            if ($Rest.Count -ge 2 -and $Rest[0] -eq 'start') { Start-WinctlService $Rest[1] }
            elseif ($Rest.Count -ge 2 -and $Rest[0] -eq 'stop') { Stop-WinctlService $Rest[1] }
            else { Show-Services }
        }
        'disk' {
            foreach ($d in Get-WinctlDisks) { Write-Host ('{0}  {1,6} GB free of {2,6} GB ({3}%)' -f $d.drive, $d.free_gb, $d.total_gb, $d.free_percent) }
        }
        'backup' {
            if ($Rest.Count -gt 0 -and $Rest[0] -eq 'verify') { if ((Test-WinctlBackup) -gt 0) { exit 1 } }
            else { Invoke-WinctlBackup }
        }
        'restore'  { Invoke-WinctlRestore -Yes:(Test-Flag '--yes') }
        'sync'     { Invoke-Sync }
        'update'   { Invoke-Update }
        'reboot'   { Invoke-Restart 'reboot' }
        'shutdown' { Invoke-Restart 'shutdown' }
        'logs' {
            Show-Tail -Path (Join-Path (Get-WinctlPath Logs) ('winctl-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))) -Count ([int](Get-Option '-n' 50))
        }
        'history'  { Show-Tail -Path (Get-WinctlPath History) -Count ([int](Get-Option '-n' 30)) }
        'remote'   { Invoke-WinctlRemote }
        default    { Write-Host "Unknown command: $Command"; Show-Help; exit 64 }
    }
} catch {
    Set-WinctlLastError "$Command failed: $($_.Exception.Message)"
    Write-Host "winctl $Command failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
