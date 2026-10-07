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

        # Let the (non-elevated) user write state/logs; keep secrets.json readable only by user + admins.
        & icacls.exe $Ctx.HomeDir /grant "$($Ctx.UserId):(OI)(CI)M" | Out-Null
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
