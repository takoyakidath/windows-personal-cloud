# Allowlisted command dispatcher for the Raspberry Pi controller (product.txt §6.2, §32, §42).
# The controller's SSH key is installed with a forced command (`winctl remote`), so whatever the
# client sends arrives in SSH_ORIGINAL_COMMAND and is only ever matched against this table —
# it is never executed as a shell command.

Set-StrictMode -Version 2.0

# command -> how it runs. 'sync' returns output now; 'task' is handed to a scheduled task so it
# survives the SSH session ending (hibernate / reboot kill the connection).
$script:RemoteAllowlist = [ordered]@{
    ping     = 'sync'
    status   = 'sync'
    doctor   = 'sync'
    ready    = 'sync'
    game     = 'sync'
    work     = 'sync'
    server   = 'sync'
    sleep    = 'task'
    update   = 'task'
    reboot   = 'task'
    shutdown = 'task'
}

# Pure: returns the allowlisted command name, or $null for anything else (including any arguments).
function Resolve-WinctlRemoteCommand {
    param([string]$Original)
    if (-not $Original) { return $null }
    $trimmed = $Original.Trim().ToLowerInvariant()
    if ($trimmed -notmatch '^[a-z]+$') { return $null }
    if ($script:RemoteAllowlist.Contains($trimmed)) { return $trimmed }
    return $null
}

function Get-WinctlRemoteTaskName {
    param([Parameter(Mandatory)][string]$Command)
    return 'WinCtl-' + (Get-Culture).TextInfo.ToTitleCase($Command)
}

function Write-WinctlJson {
    param([Parameter(Mandatory)]$Object)
    [Console]::Out.WriteLine(($Object | ConvertTo-Json -Depth 6 -Compress))
}

function Invoke-WinctlRemote {
    $original = $env:SSH_ORIGINAL_COMMAND
    $command = Resolve-WinctlRemoteCommand $original
    if (-not $command) {
        Write-WinctlLog -Level WARN -Event 'remote' -Message "Rejected remote command: '$original'" -Quiet
        Write-WinctlJson @{ ok = $false; error = 'command not allowed'; allowed = @($script:RemoteAllowlist.Keys) }
        exit 64
    }
    Write-WinctlLog -Event 'remote' -Message "Remote command: $command" -Quiet
    Add-WinctlHistory -Event 'remote' -Detail $command

    try {
        if ($script:RemoteAllowlist[$command] -eq 'task') {
            $task = Get-WinctlRemoteTaskName $command
            Start-ScheduledTask -TaskName $task -TaskPath '\winctl\'
            Write-WinctlJson @{ ok = $true; accepted = $command }
            return
        }
        switch ($command) {
            'ping'   { Write-WinctlJson @{ ok = $true; time = (Get-WinctlTimestamp) } }
            'status' { Write-WinctlJson (Get-WinctlStatus) }
            'doctor' { Write-WinctlJson (Get-WinctlStatus) }
            default {
                Set-WinctlMode $command.ToUpperInvariant()
                $failed = @(Invoke-WinctlModeProfile $command.ToUpperInvariant())
                $status = Get-WinctlStatus
                $status | Add-Member -NotePropertyName 'failed' -NotePropertyValue $failed -Force
                Write-WinctlJson $status
            }
        }
    } catch {
        Set-WinctlLastError "Remote $command failed: $($_.Exception.Message)"
        Write-WinctlJson @{ ok = $false; error = $_.Exception.Message }
        exit 1
    }
}
