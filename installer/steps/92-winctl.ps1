# winctl CLI: shim on PATH, data directory permissions, git safe.directory.
@{
    Name = 'winctl'
    Run  = {
        param($Ctx)
        $bin = Get-WinctlPath Bin
        New-Item -ItemType Directory -Path $bin -Force | Out-Null
        $entry = Join-Path $Ctx.RepoRoot 'winctl\winctl.ps1'
        $shim = @(
            '@echo off',
            "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$entry`" %*",
            'exit /b %ERRORLEVEL%'
        )
        Set-Content -LiteralPath (Join-Path $bin 'winctl.cmd') -Value $shim -Encoding ASCII

        $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        if (($machinePath -split ';') -notcontains $bin) {
            [Environment]::SetEnvironmentVariable('Path', "$machinePath;$bin", 'Machine')
            Write-Done "Added $bin to PATH (new shells)"
        }
        $env:Path = "$env:Path;$bin"

        # Everything here (repo, bin, installer) runs elevated, so only SYSTEM and Administrators may
        # write it; the inherited ProgramData ACL would let any user create files (e.g. a new installer
        # step). The non-elevated user may only write logs, locks and data (state.json).
        & icacls.exe $Ctx.HomeDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
        & icacls.exe (Join-Path $Ctx.HomeDir '*') /reset /T /C /Q | Out-Null
        foreach ($dir in @((Get-WinctlPath Logs), (Get-WinctlPath Locks), (Get-WinctlPath Data))) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            & icacls.exe $dir /grant "$($Ctx.UserId):(OI)(CI)M" | Out-Null
        }
        $oldState = Join-Path $Ctx.HomeDir 'state.json'
        if ((Test-Path -LiteralPath $oldState) -and -not (Test-Path -LiteralPath (Get-WinctlPath State))) {
            Move-Item -LiteralPath $oldState -Destination (Get-WinctlPath State)
        }
        $secrets = Get-WinctlPath Secrets
        if (Test-Path -LiteralPath $secrets) {
            & icacls.exe $secrets /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' /grant "$($Ctx.UserId):F" | Out-Null
        } else {
            Add-ManualAction "Optional: create $secrets with {""discord_webhook_url"": ""...""} for Discord notifications."
        }

        $repo = $Ctx.RepoRoot -replace '\\', '/'
        $safe = @((Invoke-WinctlNative git @('config', '--system', '--get-all', 'safe.directory')).Output)
        if ($safe -notcontains $repo) { & git config --system --add safe.directory $repo }
        Write-Done "winctl -> $entry"
        return 'ok'
    }
}
