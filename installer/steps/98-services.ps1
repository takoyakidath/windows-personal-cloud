# Start the services for the current mode (same path as boot recovery).
@{
    Name = 'Services'
    Run  = {
        param($Ctx)
        & (Join-Path (Get-WinctlPath Bin) 'winctl.cmd') recover --reason install
        return 'ok'
    }
}
