# Remote Desktop host for Windows App / RDP (requires Pro/Enterprise; Home uses Parsec instead).
@{
    Name = 'Remote Desktop'
    Run  = {
        param($Ctx)
        if (-not $Ctx.System.remote.rdp) { Write-Done 'Disabled in config'; return 'ok' }
        $caption = (Get-CimInstance Win32_OperatingSystem).Caption
        if ($caption -match 'Home') {
            Add-ManualAction 'Windows Home cannot host RDP; use Parsec for GUI access.'
            return 'ok'
        }
        Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
        # Network Level Authentication on.
        Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -Value 1
        Write-Done 'RDP enabled with NLA (firewall scope set in 90-firewall)'
        return 'ok'
    }
}
