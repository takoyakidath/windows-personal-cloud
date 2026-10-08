# Windows Personal Cloud - bootstrap (product.txt §33, §34)
#
# On a fresh Windows install (nothing else needed first):
#   1. Download the repository ZIP in a browser (GitHub > Code > Download ZIP) and extract it.
#   2. Terminal / PowerShell (Admin):
#        Set-ExecutionPolicy -Scope Process Bypass
#        & "$HOME\Downloads\windows-personal-cloud-main\bootstrap.ps1"
#
# It installs or repairs winget (official release, SHA-256 verified), installs Git (winget, or the signed Git for Windows installer as a fallback),
# clones the repo to C:\ProgramData\winctl\repo and runs installer\install.ps1 from there.
# Do not use the `irm <url> | iex` download cradle: Microsoft Defender rightly flags it as
# Trojan:Win32/Commando. Safe to run any number of times.

$ErrorActionPreference = 'Stop'
# Repository to clone: config/system.json next to this script (so a fork only edits config), else env.
$RepoUrl = $env:WPC_REPO_URL
$Branch = $env:WPC_BRANCH
$configPath = Join-Path (Join-Path $PSScriptRoot 'config') 'system.json'
if (Test-Path -LiteralPath $configPath) {
    $repoConfig = (Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json).repository
    if (-not $RepoUrl) { $RepoUrl = $repoConfig.url }
    if (-not $Branch) { $Branch = $repoConfig.branch }
}
if (-not $RepoUrl) { throw "Repository URL unknown: run bootstrap.ps1 from the extracted repository (needs config\system.json)." }
if (-not $Branch) { $Branch = 'main' }
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
# The PS 5.1 progress bar makes Invoke-WebRequest many times slower on large downloads.
$ProgressPreference = 'SilentlyContinue'
New-Item -ItemType Directory -Path $HomeDir -Force | Out-Null

# Native command without stderr turning into a terminating error (Windows PowerShell 5.1 + 'Stop').
function Invoke-Quiet {
    param([string]$FilePath, [string[]]$Arguments)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $FilePath @Arguments 2>&1 | Out-Null; return $LASTEXITCODE } finally { $ErrorActionPreference = $previous }
}

function Test-Winget {
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) { return $false }
    return ((Invoke-Quiet winget.exe @('search', '--id', 'Git.Git', '--exact', '--source', 'winget', '--accept-source-agreements', '--disable-interactivity')) -eq 0)
}

# Downloads a release asset and checks it against the SHA-256 the release publishes in <name>.txt.
function Get-VerifiedAsset {
    param($Release, [string]$Name, [string]$HashName, [string]$Dir)
    $asset = $Release.assets | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    $hashAsset = $Release.assets | Where-Object { $_.name -eq $HashName } | Select-Object -First 1
    if (-not $asset -or -not $hashAsset) { throw "Release asset $Name (or its hash) not found." }
    $file = Join-Path $Dir $Name
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $file -UseBasicParsing
    # Save the hash to a file: on PS 5.1 .Content of an octet-stream response is a byte array.
    $hashFile = Join-Path $Dir $HashName
    Invoke-WebRequest -Uri $hashAsset.browser_download_url -OutFile $hashFile -UseBasicParsing
    $expected = (Get-Content -LiteralPath $hashFile -Raw).Trim().Split()[0]
    $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
    if ($actual -ne $expected) { throw "SHA-256 mismatch for $Name (expected $expected, got $actual)." }
    return $file
}

# Installs winget (App Installer) from microsoft/winget-cli releases: the documented offline method.
# Appx packages are signature-checked by Windows on install.
function Install-WingetDirect {
    Write-Step 'Installing winget (App Installer) from the official release'
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
    $dir = Join-Path $env:TEMP 'wpc-winget'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/microsoft/winget-cli/releases/latest' -UseBasicParsing
    Write-Host "    winget $($release.tag_name)"
    $deps = Get-VerifiedAsset $release 'DesktopAppInstaller_Dependencies.zip' 'DesktopAppInstaller_Dependencies.txt' $dir
    $bundle = Get-VerifiedAsset $release 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle' 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.txt' $dir
    $depsDir = Join-Path $dir 'deps'
    Expand-Archive -LiteralPath $deps -DestinationPath $depsDir -Force
    foreach ($appx in Get-ChildItem -LiteralPath (Join-Path $depsDir $arch) -Filter '*.appx') {
        # Fails harmlessly when the same or a newer version is already installed.
        try { Add-AppxPackage -Path $appx.FullName -ErrorAction Stop; Write-Host "    + $($appx.Name)" }
        catch { Write-Host "    = $($appx.Name) (already present)" }
    }
    Add-AppxPackage -Path $bundle -ErrorAction Stop
    $env:Path = "$env:Path;$env:LOCALAPPDATA\Microsoft\WindowsApps"
}

# --- winget: register / reset sources (fresh Windows 10 often has a broken or missing source) ---
function Repair-Winget {
    if (Test-Winget) { return $true }
    Write-Step 'Repairing winget'
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        try { Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop } catch { }
        $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User') + ";$env:LOCALAPPDATA\Microsoft\WindowsApps"
    }
    if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
        Invoke-Quiet winget.exe @('source', 'reset', '--force') | Out-Null
        Invoke-Quiet winget.exe @('source', 'update') | Out-Null
        if (Test-Winget) { return $true }
    }
    # Missing or too old (fresh Windows 10): install the current release, then initialise its sources.
    try { Install-WingetDirect } catch { Write-Warning "winget install failed: $($_.Exception.Message)"; return $false }
    Invoke-Quiet winget.exe @('source', 'reset', '--force') | Out-Null
    Invoke-Quiet winget.exe @('source', 'update') | Out-Null
    return (Test-Winget)
}

# Fallback: the official, signed Git for Windows installer from its GitHub release.
function Install-GitDirect {
    Write-Step 'Installing Git from the Git for Windows release'
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { '64-bit' }
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/git-for-windows/git/releases/latest' -UseBasicParsing
    $asset = $release.assets | Where-Object { $_.name -match "^Git-[\d.]+-$arch\.exe$" } | Select-Object -First 1
    if (-not $asset) { throw "No Git for Windows installer found for $arch." }
    $file = Join-Path $env:TEMP $asset.name
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $file -UseBasicParsing
    $sig = Get-AuthenticodeSignature -FilePath $file
    if ($sig.Status -ne 'Valid') { throw "Git installer signature is $($sig.Status); not running it." }
    Write-Host "    signed by: $($sig.SignerCertificate.Subject)"
    $p = Start-Process -FilePath $file -ArgumentList '/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-', '/SUPPRESSMSGBOXES' -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "Git installer exited with $($p.ExitCode)." }
}

$wingetOk = Repair-Winget
if (-not $wingetOk) {
    Write-Warning 'winget is still not usable. Update "App Installer" from the Microsoft Store later; app installs will be listed as manual actions.'
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
    if ($wingetOk) {
        Write-Step 'Installing Git (winget)'
        Invoke-Quiet winget.exe @('install', '--id', 'Git.Git', '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity') | Out-Null
        $git = Find-Git
    }
    if (-not $git) { Install-GitDirect; $git = Find-Git }
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
# Always run the installer from the managed checkout (not from a downloaded ZIP).
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoDir 'installer\install.ps1')
exit $LASTEXITCODE
