# Windows Personal Cloud - bootstrap (product.txt §33, §34)
#
# On a fresh Windows install, from Terminal (Admin):
#
#   winget install --id Git.Git -e --source winget
#   git clone https://github.com/takoyakidath/windows-personal-cloud.git C:\ProgramData\winctl\repo
#   Set-ExecutionPolicy -Scope Process Bypass
#   C:\ProgramData\winctl\repo\bootstrap.ps1
#
# Do not use the `irm <url> | iex` download cradle: Microsoft Defender rightly flags it as
# Trojan:Win32/Commando. This script updates the checkout and hands over to installer\install.ps1.
# Safe to run any number of times.

$ErrorActionPreference = 'Stop'
$RepoUrl = if ($env:WPC_REPO_URL) { $env:WPC_REPO_URL } else { 'https://github.com/takoyakidath/windows-personal-cloud.git' }
$Branch = if ($env:WPC_BRANCH) { $env:WPC_BRANCH } else { 'main' }
$HomeDir = Join-Path $env:ProgramData 'winctl'
$RepoDir = Join-Path $HomeDir 'repo'

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }

# --- Administrator check: re-launch this file elevated ---
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if (-not $PSCommandPath) {
        throw 'Run bootstrap.ps1 as a file from Terminal (Admin); see the comment at the top of this script.'
    }
    Write-Step 'Requesting Administrator rights'
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$PSCommandPath`"") -ErrorAction Stop
    } catch {
        Write-Host "Could not get Administrator rights: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'Right-click Start > Terminal (Admin), then run this script again.' -ForegroundColor Yellow
    }
    return
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
New-Item -ItemType Directory -Path $HomeDir -Force | Out-Null

# --- winget + Git ---
if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
    throw 'winget is not available. Update "App Installer" from the Microsoft Store, then run bootstrap again.'
}

function Find-Git {
    $cmd = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidate = Join-Path $env:ProgramFiles 'Git\cmd\git.exe'
    if (Test-Path $candidate) { return $candidate }
    return $null
}

$git = Find-Git
if (-not $git) {
    Write-Step 'Installing Git'
    & winget.exe install --id Git.Git --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
    $git = Find-Git
    if (-not $git) { throw 'Git installation failed.' }
}

# --- Repository ---
if (Test-Path (Join-Path $RepoDir '.git')) {
    Write-Step "Updating $RepoDir"
    & $git -C $RepoDir fetch origin $Branch
    & $git -C $RepoDir merge --ff-only "origin/$Branch"
    if ($LASTEXITCODE -ne 0) { Write-Warning 'Repository has local changes; continuing with the current checkout.' }
} elseif (Test-Path $RepoDir) {
    # Never delete an unknown directory (product.txt §35 Safe).
    throw "$RepoDir exists but is not a git checkout. Move it away and run bootstrap again."
} else {
    Write-Step "Cloning $RepoUrl"
    & $git clone --branch $Branch $RepoUrl $RepoDir
    if ($LASTEXITCODE -ne 0) { throw 'git clone failed.' }
}

# --- Hand over to the installer ---
Write-Step 'Running installer'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoDir 'installer\install.ps1')
exit $LASTEXITCODE
