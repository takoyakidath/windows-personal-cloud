# Docker Engine + Compose inside WSL2 (not Docker Desktop: `wsl --shutdown` stops it completely).
@{
    Name = 'Docker (inside WSL2)'
    Run  = {
        param($Ctx)
        . (Join-Path $Ctx.RepoRoot 'winctl\lib\Services.ps1')
        $distro = $Ctx.System.wsl.distro
        $list = Invoke-WinctlWsl -Arguments @('--list', '--quiet')
        if (($list.Output -split "`r?`n" | ForEach-Object { $_.Trim() }) -notcontains $distro) {
            Add-ManualAction "Docker skipped: $distro is not installed yet."
            return 'ok'
        }
        # A Windows checkout may have converted the script to CRLF, which bash rejects (`set -o pipefail`).
        # Run an LF-only copy; passing it through wsl.exe quoting tricks is fragile (wsl -- uses the login shell).
        $src = Join-Path $Ctx.RepoRoot 'installer\wsl\install-docker.sh'
        $winPath = Join-Path (Get-WinctlPath Data) 'install-docker.sh'
        [IO.File]::WriteAllText($winPath, ((Get-Content -LiteralPath $src -Raw) -replace "`r", ''), (New-Object Text.UTF8Encoding($false)))
        $wslPath = (Invoke-WinctlWsl -Arguments @('-d', $distro, '-u', 'root', '--', 'wslpath', '-a', ($winPath -replace '\\', '/'))).Output
        $r = Invoke-WinctlWsl -Arguments @('-d', $distro, '-u', 'root', '--', 'bash', $wslPath, $Ctx.System.wsl.default_user)
        if ($r.ExitCode -ne 0) { throw "Docker install failed: $($r.Output)" }
        Write-Done (($r.Output -split "`r?`n") -join '; ')
        return 'ok'
    }
}
