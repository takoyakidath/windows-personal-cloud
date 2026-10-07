# Wake-on-LAN on the built-in Ethernet, and nothing else may wake the PC (product.txt §9, §10).
# BIOS settings must be set by hand (docs/bios.md).
@{
    Name = 'Wake-on-LAN (Windows side)'
    Run  = {
        param($Ctx)
        . (Join-Path $Ctx.RepoRoot 'winctl\lib\Power.ps1')
        $adapter = Get-WinctlWakeAdapter $Ctx.System
        if (-not $adapter) { Add-ManualAction 'No built-in Ethernet adapter found; Wake-on-LAN not configured.'; return 'ok' }

        # Magic packet only: pattern wake would let ordinary traffic (ARP, pings, scans) wake the PC.
        Set-NetAdapterPowerManagement -Name $adapter.Name -WakeOnMagicPacket Enabled -WakeOnPattern Disabled -ErrorAction SilentlyContinue
        $wol = Get-NetAdapterAdvancedProperty -Name $adapter.Name -RegistryKeyword '*WakeOnMagicPacket' -ErrorAction SilentlyContinue
        if ($wol -and $wol.RegistryValue -ne '1') {
            Set-NetAdapterAdvancedProperty -Name $adapter.Name -RegistryKeyword '*WakeOnMagicPacket' -RegistryValue 1
        }
        & powercfg.exe /deviceenablewake "$($adapter.InterfaceDescription)" 2>$null | Out-Null

        if ([bool](Get-WinctlProp $Ctx.System.power 'lan_only_wake' $true)) {
            # Disarm every other wake device (mouse, keyboard, Wi-Fi, ...).
            foreach ($device in Select-WinctlWakeDevicesToDisarm -Armed (Get-WinctlWakeArmedDevices) -Keep $adapter.InterfaceDescription) {
                & powercfg.exe /devicedisablewake "$device" 2>$null | Out-Null
                Write-Done "Wake disabled: $device"
            }
            # Wake timers (Windows Update, scheduled tasks) and automatic maintenance must not wake the PC.
            & powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE 0
            & powercfg.exe /setdcvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE 0
            & powercfg.exe /setactive SCHEME_CURRENT
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
        Write-Done "$($adapter.Name) ($($adapter.InterfaceDescription)) MAC $mac"
        if ($Ctx.System.machine.mac_address -ne $mac) {
            Add-ManualAction "Set machine.mac_address to `"$mac`" in config/system.json and in the Raspberry Pi controller config."
        }
        Add-ManualAction 'Check BIOS Wake-on-LAN settings and run the WoL verification in docs/wol-verification.md.'
        return 'ok'
    }
}
