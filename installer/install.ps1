# Windows Personal Cloud - installer (product.txt §34, §35)
#
# Idempotent: every step checks current state before changing anything, so it can be run repeatedly.
# Resumable: when a step needs a reboot, a logon task re-runs this script with -Resume after restart.
# Safe:      never deletes Workspace / Projects / Documents / Media / Backups.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File installer\install.ps1 [-Only 60-openssh,90-firewall] [-NoReboot]

param(
    [switch]$Resume,
    [string[]]$Only = @(),
    [switch]$NoReboot
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $RepoRoot 'winctl\lib\Common.ps1')

if (-not (Test-WinctlAdmin)) { throw 'Run the installer from an elevated (Administrator) PowerShell.' }

Initialize-WinctlDirectories
$transcript = Join-Path (Get-WinctlPath Logs) ('install-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Start-Transcript -Path $transcript -Append | Out-Null

$ResumeTaskName = 'WinCtl-InstallResume'

# Shared context handed to every step.
$Ctx = [pscustomobject]@{
    RepoRoot = $RepoRoot
    HomeDir  = Get-WinctlHome
    System   = Get-WinctlConfig system
    Services = Get-WinctlConfig services
    UserId   = "$env:USERDOMAIN\$env:USERNAME"
    Warnings = New-Object System.Collections.Generic.List[string]
    Facts    = @{}
}

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Done { param([string]$Message) Write-Host "    $Message" -ForegroundColor DarkGray }
function Add-ManualAction { param([string]$Message) $Ctx.Warnings.Add($Message); Write-Host "    ! $Message" -ForegroundColor Yellow }

function Register-ResumeTask {
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -NoExit -File "{0}" -Resume' -f (Join-Path $RepoRoot 'installer\install.ps1'))
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $Ctx.UserId
    $principal = New-ScheduledTaskPrincipal -UserId $Ctx.UserId -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $ResumeTaskName -TaskPath '\winctl\' -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
}

function Unregister-ResumeTask {
    if (Get-ScheduledTask -TaskName $ResumeTaskName -TaskPath '\winctl\' -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $ResumeTaskName -TaskPath '\winctl\' -Confirm:$false
    }
}

function Save-InstallState {
    param([string]$Status, [string]$Step = '')
    [ordered]@{ status = $Status; step = $Step; time = (Get-WinctlTimestamp); commit = ((Invoke-WinctlNative git @('-C', $RepoRoot, 'rev-parse', '--short', 'HEAD')).Output -join '') } |
        ConvertTo-Json | Set-Content -LiteralPath (Get-WinctlPath InstallState) -Encoding UTF8
}

if ($Resume) { Write-Step 'Resuming installation after restart' }

$stepFiles = Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'steps') -Filter '*.ps1' | Sort-Object Name
if ($Only.Count -gt 0) { $stepFiles = $stepFiles | Where-Object { $Only -contains $_.BaseName } }

$exitCode = 0
$file = $null
try {
    foreach ($file in $stepFiles) {
        # Each step file returns @{ Name = '...'; Run = { param($Ctx) ...; return 'ok' | 'reboot' } }
        $step = & $file.FullName
        Write-Step "[$($file.BaseName)] $($step.Name)"
        Save-InstallState -Status 'running' -Step $file.BaseName
        $result = & $step.Run $Ctx
        if ($result -eq 'reboot') {
            Save-InstallState -Status 'reboot-pending' -Step $file.BaseName
            Register-ResumeTask
            Write-Host ''
            Write-Host 'A restart is required. Installation resumes automatically after you log in again.' -ForegroundColor Yellow
            if ($NoReboot) { Write-Host 'Restart manually when ready (-NoReboot was given).'; exit 3010 }
            Write-Host 'Restarting in 20 seconds (Ctrl+C to cancel)...'
            Start-Sleep -Seconds 20
            Restart-Computer -Force
            exit 3010
        }
    }
    Unregister-ResumeTask
    Save-InstallState -Status 'complete'
    Add-WinctlHistory -Event 'install' -Detail 'complete'
    Write-Host ''
    Write-Host 'Installation complete.' -ForegroundColor Green
} catch {
    $exitCode = 1
    Save-InstallState -Status 'failed' -Step $(if ($file) { $file.BaseName } else { '' })
    Write-Host "Installation failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    Write-Host 'Fix the problem and run the installer again; finished steps are skipped automatically.'
} finally {
    if ($Ctx.Warnings.Count -gt 0) {
        Write-Host ''
        Write-Host 'Manual actions:' -ForegroundColor Yellow
        foreach ($w in $Ctx.Warnings) { Write-Host "  - $w" -ForegroundColor Yellow }
    }
    Write-Host "Log: $transcript"
    Stop-Transcript | Out-Null
}
exit $exitCode
