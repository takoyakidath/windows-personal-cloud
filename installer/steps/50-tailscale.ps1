# Tailscale: the remote network (product.txt §16). Login is interactive unless TS_AUTHKEY is set.
@{
    Name = 'Tailscale'
    Run  = {
        param($Ctx)
        $svc = Get-Service -Name Tailscale -ErrorAction SilentlyContinue
        if (-not $svc) { Add-ManualAction 'Tailscale service not found; check the Tailscale.Tailscale package.'; return 'ok' }
        Set-Service -Name Tailscale -StartupType Automatic
        if ($svc.Status -ne 'Running') { Start-Service -Name Tailscale }

        $exe = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
        $state = $null
        try { $state = (& $exe status --json 2>$null | Out-String | ConvertFrom-Json).BackendState } catch { }
        if ($state -eq 'Running') { Write-Done 'Tailscale connected'; return 'ok' }

        $hostname = $Ctx.System.machine.tailscale_hostname
        if ($env:TS_AUTHKEY) {
            # Auth key comes from the environment only; it is never written to disk or git.
            & $exe up --authkey $env:TS_AUTHKEY --hostname $hostname --unattended
            if ($LASTEXITCODE -ne 0) { Add-ManualAction 'tailscale up with TS_AUTHKEY failed.' }
        } else {
            Add-ManualAction "Log in to Tailscale: tailscale up --hostname $hostname --unattended"
        }
        return 'ok'
    }
}
