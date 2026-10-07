# Wake-on-LAN on the built-in Ethernet (product.txt §9). BIOS settings must be set by hand (docs/bios.md).
@{
    Name = 'Wake-on-LAN (Windows side)'
    Run  = {
        param($Ctx)
        $name = $Ctx.System.machine.ethernet_adapter
        $adapter = Get-NetAdapter -Name $name -Physical -ErrorAction SilentlyContinue
        if (-not $adapter) {
            # Fall back to the first physical wired adapter that is not USB.
            $adapter = Get-NetAdapter -Physical | Where-Object { $_.PhysicalMediaType -eq '802.3' -and $_.InterfaceDescription -notmatch 'USB' } | Select-Object -First 1
        }
        if (-not $adapter) { Add-ManualAction 'No built-in Ethernet adapter found; Wake-on-LAN not configured.'; return 'ok' }

        Set-NetAdapterPowerManagement -Name $adapter.Name -WakeOnMagicPacket Enabled -ErrorAction SilentlyContinue
        $wol = Get-NetAdapterAdvancedProperty -Name $adapter.Name -RegistryKeyword '*WakeOnMagicPacket' -ErrorAction SilentlyContinue
        if ($wol -and $wol.RegistryValue -ne '1') {
            Set-NetAdapterAdvancedProperty -Name $adapter.Name -RegistryKeyword '*WakeOnMagicPacket' -RegistryValue 1
        }
        & powercfg.exe /deviceenablewake "$($adapter.InterfaceDescription)" 2>$null | Out-Null

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
