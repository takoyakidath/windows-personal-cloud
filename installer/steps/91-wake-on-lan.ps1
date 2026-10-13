# Wake-on-LAN on the built-in Ethernet, and nothing else may wake the PC (product.txt §9, §10).
# BIOS settings must be set by hand (docs/bios.md).
@{
    Name = 'Wake-on-LAN (Windows side)'
    Run  = {
        param($Ctx)
        . (Join-Path $Ctx.RepoRoot 'winctl\lib\Power.ps1')
        $adapter = Get-WinctlWakeAdapter $Ctx.System
        if (-not $adapter) { Add-ManualAction 'No wired Ethernet adapter found; Wake-on-LAN not configured.'; return 'ok' }

        # The WoL adapter is a link to the Pi only: no gateway, last in routing order, so internet traffic never uses it.
        # Only when it is the adapter named in config - the fallback pick may be the primary NIC, which must keep its route.
        $alias = $adapter.Name
        if ($alias -eq $Ctx.System.machine.ethernet_adapter) {
            $linkAddress = Get-WinctlProp $Ctx.System.machine 'wol_link_address' ''
            if ($linkAddress) {
                # Static config: with DHCP off no lease can bring a gateway back.
                Set-NetIPInterface -InterfaceAlias $alias -AddressFamily IPv4 -Dhcp Disabled
                $have = Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq $linkAddress }
                if (-not $have) {
                    Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
                    New-NetIPAddress -InterfaceAlias $alias -IPAddress $linkAddress -PrefixLength 24 | Out-Null
                }
                Write-Done "WoL link $alias = $linkAddress/24 (no gateway)"
            }
            Get-NetRoute -InterfaceAlias $alias -DestinationPrefix 0.0.0.0/0 -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
            Set-NetIPInterface -InterfaceAlias $alias -AddressFamily IPv4 -AutomaticMetric Disabled -InterfaceMetric 9999 -ErrorAction SilentlyContinue
            Set-DnsClient -InterfaceAlias $alias -RegisterThisConnectionsAddress $false -ErrorAction SilentlyContinue
        } else {
            Add-ManualAction "WoL adapter '$($Ctx.System.machine.ethernet_adapter)' not found; used '$alias' for wake only (routes untouched). Fix machine.ethernet_adapter."
        }

        # Magic packet only: pattern wake would let ordinary traffic (ARP, pings, scans) wake the PC.
        Set-NetAdapterPowerManagement -Name $adapter.Name -WakeOnMagicPacket Enabled -WakeOnPattern Disabled -ErrorAction SilentlyContinue
        $wol = Get-NetAdapterAdvancedProperty -Name $adapter.Name -RegistryKeyword '*WakeOnMagicPacket' -ErrorAction SilentlyContinue
        if ($wol -and $wol.RegistryValue -ne '1') {
            Set-NetAdapterAdvancedProperty -Name $adapter.Name -RegistryKeyword '*WakeOnMagicPacket' -RegistryValue 1
        }
        # powercfg can refuse for some devices (e.g. virtual NICs); report instead of aborting the install.
        $r = Invoke-WinctlNative powercfg.exe @('/deviceenablewake', $adapter.InterfaceDescription)
        if ($r.ExitCode -ne 0) { Write-Done "powercfg could not arm $($adapter.InterfaceDescription): $($r.Error)$($r.Output)" }

        if ([bool](Get-WinctlProp $Ctx.System.power 'lan_only_wake' $true)) {
            # Disarm every other wake device (mouse, keyboard, Wi-Fi, ...).
            foreach ($device in Select-WinctlWakeDevicesToDisarm -Armed (Get-WinctlWakeArmedDevices) -Keep $adapter.InterfaceDescription) {
                $r = Invoke-WinctlNative powercfg.exe @('/devicedisablewake', $device)
                if ($r.ExitCode -eq 0) { Write-Done "Wake disabled: $device" }
                else { Add-ManualAction "Could not disable wake for '$device' (Device Manager > Power Management)." }
            }
            # Wake timers (Windows Update, scheduled tasks) and automatic maintenance must not wake the PC.
            foreach ($a in @(@('/setacvalueindex', 'SCHEME_CURRENT', 'SUB_SLEEP', 'RTCWAKE', '0'),
                             @('/setdcvalueindex', 'SCHEME_CURRENT', 'SUB_SLEEP', 'RTCWAKE', '0'),
                             @('/setactive', 'SCHEME_CURRENT'))) {
                $r = Invoke-WinctlNative powercfg.exe $a
                if ($r.ExitCode -ne 0) { Add-ManualAction "powercfg $($a -join ' ') failed: $($r.Error)$($r.Output)" }
            }
            $maintenance = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance'
            New-Item -Path $maintenance -Force | Out-Null
            Set-ItemProperty -Path $maintenance -Name WakeUp -Value 0 -Type DWord

            $armed = @(Get-WinctlWakeArmedDevices)
            if ($armed -notcontains $adapter.InterfaceDescription) {
                Add-ManualAction "Ethernet is not armed for wake (powercfg /devicequery wake_armed). Enable 'Allow this device to wake the computer' in Device Manager."
            } else {
                Write-Done 'Wake sources: LAN only (magic packet); wake timers off'
            }
        }

        # Fast Startup makes "shutdown" a hybrid hibernate and commonly breaks WoL from S5.
        Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -Value 0 -Type DWord

        $mac = ($adapter.MacAddress -replace '-', ':').ToLowerInvariant()
        $Ctx.Facts['WolMac'] = $mac
        Write-Done "$($adapter.Name) ($($adapter.InterfaceDescription)) MAC $mac"
        if ($Ctx.System.machine.mac_address -ne $mac) {
            Add-ManualAction "Set machine.mac_address to `"$mac`" in config/system.json and in the Raspberry Pi controller config."
        }
        Add-ManualAction 'Check BIOS Wake-on-LAN settings and run the WoL verification in docs/wol-verification.md.'
        return 'ok'
    }
}
