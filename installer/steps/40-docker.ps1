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
        # Run the script from the repo checkout through its /mnt/c/... path.
        $winPath = Join-Path $Ctx.RepoRoot 'installer\wsl\install-docker.sh'
        $wslPath = (Invoke-WinctlWsl -Arguments @('-d', $distro, '-u', 'root', '--', 'wslpath', '-a', ($winPath -replace '\\', '/'))).Output
        # Strip CR first: a Windows checkout may have converted the script to CRLF, which bash rejects.
        $r = Invoke-WinctlWsl -Arguments @('-d', $distro, '-u', 'root', '--', 'bash', '-c', 'bash <(tr -d "\r" < "$0") "$1"', $wslPath, $Ctx.System.wsl.default_user)
        if ($r.ExitCode -ne 0) { throw "Docker install failed: $($r.Output)" }
        Write-Done (($r.Output -split "`r?`n") -join '; ')
        return 'ok'
    }
}
