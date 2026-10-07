# Common helpers for winctl: paths, configuration, logging, state, notifications.
# Must stay compatible with Windows PowerShell 5.1 (no ternary, no ??, no -AsHashtable).

Set-StrictMode -Version 2.0

$script:RepoRoot = (Resolve-Path (Join-Path (Join-Path $PSScriptRoot '..') '..')).Path

function Get-WinctlHome {
    if ($env:WINCTL_HOME) { return $env:WINCTL_HOME }
    if ($env:ProgramData) { return (Join-Path $env:ProgramData 'winctl') }
    return (Join-Path ([System.IO.Path]::GetTempPath()) 'winctl')
}

function Get-WinctlPath {
    param([Parameter(Mandatory)][ValidateSet('Logs', 'State', 'History', 'Secrets', 'Locks', 'Bin', 'InstallState')][string]$Name)
    $homeDir = Get-WinctlHome
    switch ($Name) {
        'Logs'         { return (Join-Path $homeDir 'logs') }
        'State'        { return (Join-Path $homeDir 'state.json') }
        'History'      { return (Join-Path (Join-Path $homeDir 'logs') 'history.jsonl') }
        'Secrets'      { return (Join-Path $homeDir 'secrets.json') }
        'Locks'        { return (Join-Path $homeDir 'locks') }
        'Bin'          { return (Join-Path $homeDir 'bin') }
        'InstallState' { return (Join-Path $homeDir 'install-state.json') }
    }
}

function Get-WinctlConfigDir {
    if ($env:WINCTL_CONFIG_DIR) { return $env:WINCTL_CONFIG_DIR }
    return (Join-Path $script:RepoRoot 'config')
}

# Recursively merges $Override into $Base. Objects merge; everything else (arrays, scalars) is replaced.
function Merge-WinctlObject {
    param($Base, $Override)
    if ($null -eq $Override) { return $Base }
    if ($null -eq $Base) { return $Override }
    if (-not ($Base -is [System.Management.Automation.PSCustomObject]) -or
        -not ($Override -is [System.Management.Automation.PSCustomObject])) {
        return $Override
    }
    $result = [ordered]@{}
    foreach ($p in $Base.PSObject.Properties) { $result[$p.Name] = $p.Value }
    foreach ($p in $Override.PSObject.Properties) {
        if ($result.Contains($p.Name)) {
            $result[$p.Name] = Merge-WinctlObject -Base $result[$p.Name] -Override $p.Value
        } else {
            $result[$p.Name] = $p.Value
        }
    }
    return [pscustomobject]$result
}

# Loads config/<Name>.json, merged with an optional git-ignored config/<Name>.local.json.
function Get-WinctlConfig {
    param([Parameter(Mandatory)][ValidateSet('system', 'games', 'services')][string]$Name)
    $dir = Get-WinctlConfigDir
    $path = Join-Path $dir "$Name.json"
    if (-not (Test-Path -LiteralPath $path)) { throw "Config not found: $path" }
    $config = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $localPath = Join-Path $dir "$Name.local.json"
    if (Test-Path -LiteralPath $localPath) {
        $local = Get-Content -LiteralPath $localPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $config = Merge-WinctlObject -Base $config -Override $local
    }
    return $config
}

function Get-WinctlSecret {
    param([Parameter(Mandatory)][string]$Name)
    $path = Get-WinctlPath Secrets
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $secrets = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $prop = $secrets.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

# Strict-mode-safe property read with a default.
function Get-WinctlProp {
    param($Object, [Parameter(Mandatory)][string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop -and $null -ne $prop.Value) { return $prop.Value }
    return $Default
}

function Get-WinctlTimestamp { return (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz') }

function Initialize-WinctlDirectories {
    foreach ($dir in @((Get-WinctlHome), (Get-WinctlPath Logs), (Get-WinctlPath Locks))) {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }
}

function Write-WinctlLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO',
        [Alias('Event')][string]$EventName = 'command',
        [switch]$Quiet
    )
    try {
        Initialize-WinctlDirectories
        $line = '{0} [{1}] [{2}] {3}' -f (Get-WinctlTimestamp), $Level, $EventName, $Message
        $file = Join-Path (Get-WinctlPath Logs) ('winctl-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
        Add-Content -LiteralPath $file -Value $line -Encoding UTF8
    } catch {
        # Logging must never break a command.
    }
    if (-not $Quiet) {
        if ($Level -eq 'ERROR') { Write-Host $Message -ForegroundColor Red }
        elseif ($Level -eq 'WARN') { Write-Host $Message -ForegroundColor Yellow }
        else { Write-Host $Message }
    }
}

# Appends a structured event to history.jsonl (wake, sleep, boot, mode, health, error, command).
function Add-WinctlHistory {
    param([Parameter(Mandatory)][Alias('Event')][string]$EventName, [string]$Detail = '')
    try {
        Initialize-WinctlDirectories
        $entry = [ordered]@{ time = (Get-WinctlTimestamp); event = $EventName; detail = $Detail }
        Add-Content -LiteralPath (Get-WinctlPath History) -Value ($entry | ConvertTo-Json -Compress) -Encoding UTF8
    } catch { }
}

$script:ValidModes = @('READY', 'GAME', 'WORK', 'SERVER', 'SLEEP', 'DEGRADED', 'ERROR')

function Get-WinctlState {
    $default = [pscustomobject]@{
        mode          = 'READY'
        mode_since    = $null
        last_sleep    = $null
        last_wake     = $null
        last_error    = $null
        inhibit_sleep = $false
    }
    $path = Get-WinctlPath State
    if (-not (Test-Path -LiteralPath $path)) { return $default }
    try {
        $saved = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        return (Merge-WinctlObject -Base $default -Override $saved)
    } catch {
        return $default
    }
}

function Save-WinctlState {
    param([Parameter(Mandatory)]$State)
    Initialize-WinctlDirectories
    $path = Get-WinctlPath State
    $tmp = "$path.tmp"
    $State | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Set-WinctlStateField {
    param([Parameter(Mandatory)][string]$Name, $Value)
    $state = Get-WinctlState
    $state | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    Save-WinctlState $state
    return $state
}

function Set-WinctlMode {
    param([Parameter(Mandatory)][string]$Mode)
    $Mode = $Mode.ToUpperInvariant()
    if ($script:ValidModes -notcontains $Mode) { throw "Unknown mode: $Mode" }
    $state = Get-WinctlState
    $previous = $state.mode
    $state.mode = $Mode
    $state.mode_since = Get-WinctlTimestamp
    Save-WinctlState $state
    if ($previous -ne $Mode) { Add-WinctlHistory -Event 'mode' -Detail "$previous -> $Mode" }
}

function Set-WinctlLastError {
    param([Parameter(Mandatory)][string]$Message)
    Set-WinctlStateField -Name 'last_error' -Value ('{0} {1}' -f (Get-WinctlTimestamp), $Message) | Out-Null
    Add-WinctlHistory -Event 'error' -Detail $Message
    Write-WinctlLog -Level ERROR -Event 'error' -Message $Message -Quiet
}

# Sends a message to a Discord webhook if `discord_webhook_url` exists in secrets.json. Never throws.
function Send-WinctlNotification {
    param([Parameter(Mandatory)][string]$Message)
    $url = Get-WinctlSecret 'discord_webhook_url'
    if (-not $url) { return }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $body = @{ content = $Message } | ConvertTo-Json -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        Invoke-RestMethod -Uri $url -Method Post -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec 10 | Out-Null
    } catch {
        Write-WinctlLog -Level WARN -Event 'notify' -Message "Discord notification failed: $($_.Exception.Message)" -Quiet
    }
}

# Lock files mark long-running work (e.g. backup) so the night check will not hibernate under it.
function Enter-WinctlLock {
    param([Parameter(Mandatory)][string]$Name)
    Initialize-WinctlDirectories
    $path = Join-Path (Get-WinctlPath Locks) "$Name.lock"
    Set-Content -LiteralPath $path -Value ('{0} pid={1}' -f (Get-WinctlTimestamp), $PID) -Encoding UTF8
}

function Exit-WinctlLock {
    param([Parameter(Mandatory)][string]$Name)
    $path = Join-Path (Get-WinctlPath Locks) "$Name.lock"
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
}

function Get-WinctlActiveLocks {
    $dir = Get-WinctlPath Locks
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    $locks = @()
    foreach ($file in Get-ChildItem -LiteralPath $dir -Filter '*.lock') {
        $content = Get-Content -LiteralPath $file.FullName -Raw
        $lockPid = $null
        if ($content -match 'pid=(\d+)') { $lockPid = [int]$Matches[1] }
        # A lock whose owning process is gone is stale; ignore it.
        if ($lockPid -and -not (Get-Process -Id $lockPid -ErrorAction SilentlyContinue)) { continue }
        $locks += $file.BaseName
    }
    return $locks
}

function Test-WinctlAdmin {
    if ($env:OS -ne 'Windows_NT') { return $false }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-WinctlAdmin {
    if (-not (Test-WinctlAdmin)) { throw 'This command requires an elevated (Administrator) shell.' }
}

function Get-WinctlWorkspacePath {
    param($SystemConfig = (Get-WinctlConfig system))
    $preferred = $SystemConfig.workspace.path
    $qualifier = Split-Path -Path $preferred -Qualifier -ErrorAction SilentlyContinue
    if (-not $qualifier -or (Test-Path -LiteralPath "$qualifier\")) { return $preferred }
    return $SystemConfig.workspace.fallback_path
}
