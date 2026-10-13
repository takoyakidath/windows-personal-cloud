# Final health check. Problems are reported, not fatal: the PC is usable and `winctl doctor` explains.
@{
    Name = 'Health check'
    Run  = {
        param($Ctx)
        & (Join-Path (Get-WinctlPath Bin) 'winctl.cmd') doctor
        if ($LASTEXITCODE -ne 0) { Add-ManualAction 'Health check is not fully green. See the details with:' 'winctl doctor' }
        return 'ok'
    }
}
