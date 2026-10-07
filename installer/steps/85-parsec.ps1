# Parsec for gaming / GUI. Installed by 20-packages; login is interactive.
@{
    Name = 'Parsec'
    Run  = {
        param($Ctx)
        if (-not $Ctx.System.remote.parsec) { Write-Done 'Disabled in config'; return 'ok' }
        $svc = Get-Service -Name Parsec -ErrorAction SilentlyContinue
        if (-not $svc) { Add-ManualAction 'Parsec service not found; check the Parsec.Parsec package.'; return 'ok' }
        Set-Service -Name Parsec -StartupType Automatic
        Add-ManualAction 'Open Parsec once and log in (host settings are per-account).'
        return 'ok'
    }
}
