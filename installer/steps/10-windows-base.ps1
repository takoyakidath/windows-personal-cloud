# Base Windows settings: hostname, hibernate, power timeouts, long paths, Explorer, mouse trails.
@{
    Name = 'Windows base settings'
    Run  = {
        param($Ctx)
        $needReboot = $false

        # Hibernate must be available (and full, not reduced) for night mode.
        & powercfg.exe /hibernate on
        & powercfg.exe /h /type full | Out-Null
        # winctl decides when to sleep; the OS idle timers must not put a remotely used PC to sleep on AC.
        & powercfg.exe /change standby-timeout-ac 0
        & powercfg.exe /change hibernate-timeout-ac 0
        Write-Done 'Hibernate enabled; AC idle sleep disabled'

        $fs = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
        if ((Get-ItemProperty -Path $fs -Name LongPathsEnabled -ErrorAction SilentlyContinue).LongPathsEnabled -ne 1) {
            Set-ItemProperty -Path $fs -Name LongPathsEnabled -Value 1 -Type DWord
        }
        Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name HideFileExt -Value 0 -Type DWord

        # Mouse pointer trails (length 2-20; 0 = off). Saved in the registry and applied to the running session.
        $trails = '7'
        Set-ItemProperty -Path 'HKCU:\Control Panel\Mouse' -Name MouseTrails -Value $trails -Type String
        try {
            if (-not ('WinctlNative.Mouse' -as [type])) {
                Add-Type -Namespace WinctlNative -Name Mouse -MemberDefinition '[DllImport("user32.dll", SetLastError = true)] public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, IntPtr pvParam, uint fWinIni);'
            }
            # SPI_SETMOUSETRAILS = 0x5D; fWinIni 3 = update the user profile + broadcast the change.
            [void][WinctlNative.Mouse]::SystemParametersInfo(0x5D, [uint32]$trails, [IntPtr]::Zero, 3)
        } catch { Write-Done "Mouse trails saved; sign out and in to apply ($($_.Exception.Message))" }
        Write-Done "Mouse trails on (length $trails)"

        $hostname = $Ctx.System.machine.hostname
        if ($hostname -and $env:COMPUTERNAME -ne $hostname.ToUpperInvariant() -and $env:COMPUTERNAME -ne $hostname) {
            Write-Done "Renaming computer $env:COMPUTERNAME -> $hostname"
            Rename-Computer -NewName $hostname -Force
            $needReboot = $true
        }
        if ($needReboot) { return 'reboot' }
        return 'ok'
    }
}
