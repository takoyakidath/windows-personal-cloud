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
# Pick up tools installed earlier in this session or by previous steps (Git, winget apps).
$env:Path = (@([Environment]::GetEnvironmentVariable('Path', 'Machine'), [Environment]::GetEnvironmentVariable('Path', 'User'), $env:Path) -join ';')
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
    Warnings = New-Object System.Collections.Generic.List[object]
    Facts    = @{}
}

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Done { param([string]$Message) Write-Host "    $Message" -ForegroundColor DarkGray }
# -Command is a one-line command to copy/paste; the final summary prints it on its own line.
function Add-ManualAction {
    param([string]$Message, [string]$Command)
    $Ctx.Warnings.Add([pscustomobject]@{ Message = $Message; Command = $Command })
    Write-Host "    ! $Message" -ForegroundColor Yellow
    if ($Command) { Write-Host "      > $Command" -ForegroundColor Cyan }
}

# Final summary: what is left to do, and the Raspberry Pi commands with this PC's real values filled in.
function Get-PiSetupScript {
    $m = $Ctx.System.machine
    $mac = if ($Ctx.Facts.ContainsKey('WolMac')) { $Ctx.Facts['WolMac'] } else { $m.mac_address }
    $ip = '<Windows Wi-Fi IP>'
    try {
        $route = Get-NetRoute -DestinationPrefix 0.0.0.0/0 -AddressFamily IPv4 -ErrorAction Stop |
            Sort-Object { $_.RouteMetric + (Get-NetIPInterface -InterfaceIndex $_.ifIndex -AddressFamily IPv4).InterfaceMetric } | Select-Object -First 1
        $ip = (Get-NetIPAddress -InterfaceIndex $route.ifIndex -AddressFamily IPv4 -ErrorAction Stop | Select-Object -First 1).IPAddress
    } catch { }
    $link = Get-WinctlProp $m 'wol_link_address' ''
    $broadcast = if ($link -match '^(\d+\.\d+\.\d+)\.\d+$') { "$($Matches[1]).255" } else { '255.255.255.255' }
    $user = $env:USERNAME.ToLowerInvariant()
    @"
sudo -u windows-controller ssh-keygen -R $ip -f /var/lib/windows-controller/known_hosts
sudo python3 - <<'PY'
import json
p = "/etc/windows-controller/controller.json"
c = json.load(open(p))
c["windows"].update(host="$ip", ssh_user="$user", mac_address="$mac", broadcast="$broadcast")
open(p, "w").write(json.dumps(c, indent=2) + "\n")
PY
sudo systemctl restart windows-controller
"@
}

function Write-InstallSummary {
    $pi = Get-PiSetupScript
    $piFile = Join-Path (Get-WinctlPath Logs) 'pi-setup.sh'
    Set-Content -LiteralPath $piFile -Value $pi -Encoding UTF8
    $copied = $false
    try { Set-Clipboard -Value $pi; $copied = $true } catch { }

    Write-Host ''
    Write-Host '==================== Summary / next steps ====================' -ForegroundColor Green
    Write-Host '1) Windows (this PC): do the Manual actions above (WSL password, Tailscale login, Parsec login).'
    Write-Host '2) Raspberry Pi: ssh takoyaki@wpc-controller.local , then paste this block'
    if ($copied) { Write-Host '   (already copied to the clipboard: just right-click to paste)' -ForegroundColor DarkGray }
    Write-Host ''
    Write-Host $pi -ForegroundColor Cyan
    Write-Host ''
    Write-Host "   Saved at: $piFile" -ForegroundColor DarkGray
    Write-Host '3) Check: winctl doctor  ->  Discord "/win status"  ->  Mac: Windows App to this PC.'
    Write-Host '==============================================================' -ForegroundColor Green

    Send-WinctlNotification ("Install finished on $env:COMPUTERNAME. On the Pi, paste:`n``````bash`n$pi`n``````")
}

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
    $commit = ''
    try { $commit = ((Invoke-WinctlNative git @('-C', $RepoRoot, 'rev-parse', '--short', 'HEAD')).Output -join '') } catch { }
    [ordered]@{ status = $Status; step = $Step; time = (Get-WinctlTimestamp); commit = $commit } |
        ConvertTo-Json | Set-Content -LiteralPath (Get-WinctlPath InstallState) -Encoding UTF8
}

if ($Resume) { Write-Step 'Resuming installation after restart' }

$stepFiles = Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'steps') -Filter '*.ps1' | Sort-Object Name
if ($Only.Count -gt 0) { $stepFiles = $stepFiles | Where-Object { $Only -contains $_.BaseName } }

$exitCode = 0
$completed = $false
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
            Write-Host 'Restarting in 20 seconds (press any key to restart now, Ctrl+C to cancel)...'
            $deadline = (Get-Date).AddSeconds(20)
            try {
                while ((Get-Date) -lt $deadline -and -not [Console]::KeyAvailable) { Start-Sleep -Milliseconds 200 }
            } catch {
                # No interactive console (redirected input, scheduled task): just wait out the countdown.
                $left = [int][math]::Ceiling(($deadline - (Get-Date)).TotalSeconds)
                if ($left -gt 0) { Start-Sleep -Seconds $left }
            }
            Restart-Computer -Force
            exit 3010
        }
    }
    Unregister-ResumeTask
    $completed = $true
    Save-InstallState -Status 'complete'
    Add-WinctlHistory -Event 'install' -Detail 'complete'
    Write-Host ''
    Write-Host 'Installation complete.' -ForegroundColor Green
} catch {
    $exitCode = 1
    Save-InstallState -Status 'failed' -Step $(if ($file) { $file.BaseName } else { '' })
    Write-Host "Installation failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
} finally {
    if ($Ctx.Warnings.Count -gt 0) {
        Write-Host ''
        Write-Host 'Manual actions:' -ForegroundColor Yellow
        foreach ($w in $Ctx.Warnings) {
            Write-Host "  - $($w.Message)" -ForegroundColor Yellow
            if ($w.Command) { Write-Host "      $($w.Command)" -ForegroundColor Cyan }
        }
    }
    if ($exitCode -ne 0) {
        Write-Host ''
        Write-Host 'The installer stopped before finishing.' -ForegroundColor Red
        if (@($Ctx.Warnings | Where-Object { $_.Command }).Count -gt 0) {
            Write-Host '  1) Run the manual commands listed above.' -ForegroundColor Yellow
            Write-Host '  2) Then run bootstrap again (double-click bootstrap.cmd). Finished steps are skipped and it continues from where it stopped.' -ForegroundColor Yellow
        } else {
            Write-Host 'Run bootstrap again (double-click bootstrap.cmd). Finished steps are skipped and it continues from where it stopped.' -ForegroundColor Yellow
        }
    }
    if ($completed) {
        try { Write-InstallSummary } catch { Write-Host "Summary failed: $($_.Exception.Message)" -ForegroundColor DarkGray }
    }
    Write-Host "Log: $transcript"
    Stop-Transcript | Out-Null
}
exit $exitCode
