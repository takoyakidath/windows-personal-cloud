# Firewall: SSH / RDP / SMB reachable only from Tailscale and the local subnet (product.txt §2.3, §16).
# Rules are addressed by their internal Name, which is not localized (works on Japanese Windows).
@{
    Name = 'Windows Firewall'
    Run  = {
        param($Ctx)
        Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled True

        $allowed = @($Ctx.System.network.allowed_remote_addresses)
        # Tailscale IPv6 range is always allowed alongside the configured ranges.
        if ($allowed -notcontains 'fd7a:115c:a1e0::/48') { $allowed += 'fd7a:115c:a1e0::/48' }

        $groups = [ordered]@{
            ssh = @('OpenSSH-Server-In-TCP')
            rdp = @('RemoteDesktop-UserMode-In-TCP', 'RemoteDesktop-UserMode-In-UDP')
            smb = @('FPS-SMB-In-TCP')
        }
        foreach ($key in $groups.Keys) {
            $enabled = [bool](Get-WinctlProp $Ctx.System.remote $key $false)
            foreach ($ruleName in $groups[$key]) {
                $rule = Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
                if (-not $rule) { continue }
                if ($enabled) {
                    Set-NetFirewallRule -Name $ruleName -Enabled True -Profile Any -RemoteAddress $allowed
                    Write-Done "$ruleName -> $($allowed -join ', ')"
                } else {
                    Set-NetFirewallRule -Name $ruleName -Enabled False
                    Write-Done "$ruleName disabled"
                }
            }
        }
        # Never expose the Docker API: it only listens on the WSL unix socket (installer/wsl/install-docker.sh).
        return 'ok'
    }
}
