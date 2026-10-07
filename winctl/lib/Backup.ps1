# Workspace backup / restore / verify using robocopy (product.txt §30).
# GitHub is the environment definition, the Workspace is live data, the backup target (external SSD / NAS) is the backup.

Set-StrictMode -Version 2.0

# Backup can be switched off (e.g. no external SSD yet): backup.enabled in config, or `winctl backup on|off`.
function Test-WinctlBackupEnabled {
    param($SystemConfig = (Get-WinctlConfig system))
    return [bool](Get-WinctlProp $SystemConfig.backup 'enabled' $false)
}

function Assert-WinctlBackupEnabled {
    if (-not (Test-WinctlBackupEnabled)) {
        throw 'Backup is disabled. Enable it with "winctl backup on" (or backup.enabled in config/system.json).'
    }
}

# Writes backup.enabled to the git-ignored config/system.local.json (this machine only).
function Set-WinctlBackupEnabled {
    param([Parameter(Mandatory)][bool]$Enabled)
    $path = Join-Path (Get-WinctlConfigDir) 'system.local.json'
    $local = [pscustomobject]@{}
    if (Test-Path -LiteralPath $path) { $local = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json }
    $override = [pscustomobject]@{ backup = [pscustomobject]@{ enabled = $Enabled } }
    $merged = Merge-WinctlObject -Base $local -Override $override
    $merged | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding UTF8
    Add-WinctlHistory -Event 'backup' -Detail $(if ($Enabled) { 'enabled' } else { 'disabled' })
}

function Get-WinctlBackupPaths {
    $system = Get-WinctlConfig system
    $source = Get-WinctlWorkspacePath $system
    # Path.Combine, not Join-Path: Join-Path throws when the backup drive is not connected.
    $target = [System.IO.Path]::Combine($system.backup.target, 'Workspace')
    return [pscustomobject]@{ Source = $source; Target = $target; Root = $system.backup.target }
}

# Pure: robocopy arguments. Never purges unless mirror is explicitly enabled (and never on restore).
function Get-WinctlRobocopyArgs {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [string[]]$ExcludeDirs = @(),
        [bool]$Mirror = $false,
        [switch]$ListOnly,
        [switch]$Restore,
        [string]$LogFile
    )
    $rc = @($Source, $Destination, '/E', '/COPY:DAT', '/DCOPY:DAT', '/R:2', '/W:5', '/XJ', '/MT:8', '/NP')
    if ($Mirror -and -not $Restore) { $rc += '/PURGE' }
    if ($Restore) { $rc += '/XO' }   # never overwrite files that are newer in the workspace
    if ($ListOnly) { $rc += @('/L', '/NJH', '/NJS', '/NDL', '/FP') }
    if ($ExcludeDirs.Count -gt 0) { $rc += '/XD'; $rc += $ExcludeDirs }
    if ($LogFile) { $rc += "/LOG+:$LogFile" }
    return $rc
}

function Assert-WinctlBackupTarget {
    param([Parameter(Mandatory)]$Paths)
    $qualifier = Split-Path -Path $Paths.Root -Qualifier -ErrorAction SilentlyContinue
    if ($qualifier -and -not (Test-Path -LiteralPath "$qualifier\")) {
        throw "Backup drive $qualifier is not connected."
    }
    if ($Paths.Root.StartsWith('\\') -and -not (Test-Path -LiteralPath $Paths.Root)) {
        throw "Backup share $($Paths.Root) is not reachable."
    }
}

function Invoke-WinctlBackup {
    Assert-WinctlBackupEnabled
    $system = Get-WinctlConfig system
    $paths = Get-WinctlBackupPaths
    Assert-WinctlBackupTarget $paths
    if (-not (Test-Path -LiteralPath $paths.Source)) { throw "Workspace not found: $($paths.Source)" }
    if (-not (Test-Path -LiteralPath $paths.Target)) { New-Item -ItemType Directory -Path $paths.Target -Force | Out-Null }

    $log = Join-Path (Get-WinctlPath Logs) ('backup-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $mirror = [bool](Get-WinctlProp $system.backup 'mirror' $false)
    $rcArgs = Get-WinctlRobocopyArgs -Source $paths.Source -Destination $paths.Target -ExcludeDirs @(Get-WinctlProp $system.backup 'exclude_dirs' @()) -Mirror $mirror -LogFile $log

    Enter-WinctlLock 'backup'
    try {
        Write-WinctlLog -Event 'backup' -Message "Backup $($paths.Source) -> $($paths.Target)"
        & robocopy.exe @rcArgs | Out-Null
        $code = $LASTEXITCODE
    } finally {
        Exit-WinctlLock 'backup'
    }
    # robocopy: 0-7 success (bit flags), 8+ failure.
    if ($code -ge 8) {
        Set-WinctlLastError "Backup failed (robocopy exit $code). See $log"
        Send-WinctlNotification ([char]::ConvertFromUtf32(0x1F534) + " Backup failed (robocopy exit $code).")
        throw "Backup failed (robocopy exit $code). See $log"
    }
    $marker = [ordered]@{ time = (Get-WinctlTimestamp); host = $env:COMPUTERNAME; source = $paths.Source; robocopy_exit = $code }
    $marker | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $paths.Root 'last-backup.json') -Encoding UTF8
    Set-WinctlStateField -Name 'last_backup' -Value (Get-WinctlTimestamp) | Out-Null
    Add-WinctlHistory -Event 'backup' -Detail "ok (robocopy exit $code)"
    Write-WinctlLog -Event 'backup' -Message "Backup finished (robocopy exit $code). Log: $log"
}

# Pure: is the last successful backup recent enough? Returns @{ ok; detail }.
function Test-WinctlBackupFresh {
    param($LastBackup, [int]$MaxAgeDays = 7, [Parameter(Mandatory)][DateTimeOffset]$Now)
    if (-not $LastBackup) { return [pscustomobject]@{ ok = $false; detail = 'never backed up' } }
    try { $age = $Now - [DateTimeOffset]::Parse([string]$LastBackup) } catch { return [pscustomobject]@{ ok = $false; detail = 'unknown' } }
    $days = [math]::Floor($age.TotalDays)
    $detail = if ($days -lt 1) { 'today' } elseif ($days -eq 1) { '1 day ago' } else { "$days days ago" }
    return [pscustomobject]@{ ok = ($age.TotalDays -le $MaxAgeDays); detail = $detail }
}

# Lists files that differ between workspace and backup without copying anything.
function Test-WinctlBackup {
    Assert-WinctlBackupEnabled
    $system = Get-WinctlConfig system
    $paths = Get-WinctlBackupPaths
    Assert-WinctlBackupTarget $paths
    $rcArgs = Get-WinctlRobocopyArgs -Source $paths.Source -Destination $paths.Target -ExcludeDirs @(Get-WinctlProp $system.backup 'exclude_dirs' @()) -ListOnly
    $out = @(& robocopy.exe @rcArgs | Where-Object { $_ -match '\S' })
    if ($LASTEXITCODE -ge 8) { throw "Verification failed (robocopy exit $LASTEXITCODE)." }
    $markerPath = Join-Path $paths.Root 'last-backup.json'
    if (Test-Path -LiteralPath $markerPath) { Write-Host ('Last backup: ' + (Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json).time) }
    if ($out.Count -eq 0) {
        Write-Host 'Backup is up to date.'
    } else {
        Write-Host "$($out.Count) file(s) differ from backup:"
        $out | Select-Object -First 50 | ForEach-Object { Write-Host "  $($_.Trim())" }
    }
    return $out.Count
}

# Copies backup -> workspace. Never deletes and never overwrites files newer in the workspace.
function Invoke-WinctlRestore {
    param([switch]$Yes)
    $paths = Get-WinctlBackupPaths
    Assert-WinctlBackupTarget $paths
    if (-not (Test-Path -LiteralPath $paths.Target)) { throw "No backup found at $($paths.Target)" }
    if (-not $Yes) {
        Write-Host "This copies $($paths.Target) -> $($paths.Source)."
        Write-Host 'Existing files that are newer in the workspace are kept. Nothing is deleted.'
        Write-Host 'Re-run with --yes to proceed.'
        return
    }
    $log = Join-Path (Get-WinctlPath Logs) ('restore-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $rcArgs = Get-WinctlRobocopyArgs -Source $paths.Target -Destination $paths.Source -Restore -LogFile $log
    Enter-WinctlLock 'restore'
    try { & robocopy.exe @rcArgs | Out-Null; $code = $LASTEXITCODE } finally { Exit-WinctlLock 'restore' }
    if ($code -ge 8) { throw "Restore failed (robocopy exit $code). See $log" }
    Add-WinctlHistory -Event 'restore' -Detail "ok (robocopy exit $code)"
    Write-WinctlLog -Event 'backup' -Message "Restore finished (robocopy exit $code). Log: $log"
}
