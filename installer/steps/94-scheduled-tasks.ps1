# Scheduled tasks (all under \winctl\):
#   WinCtl-Night          daily at power.night_check_time: game check -> winctl sleep
#   WinCtl-RecoverLogon   at boot and at logon: recovery (also when nobody logs in after a reboot)
#   WinCtl-Sync           daily 12:00 (or at next boot if missed): git pull
#   WinCtl-RecoverResume  on resume from sleep/hibernate (Power-Troubleshooter event 1): recovery
#   WinCtl-Sleep/Update/Reboot/Shutdown   on demand, started by `winctl remote` so they outlive the SSH session
#   WinCtl-WslKeepAlive   on demand: keeps the WSL distro (and Docker) running
# Tasks run as the user (WSL is per-user) with LogonType S4U: "run whether the user is logged on or
# not", without storing a password. So /win sleep, reboot, update and modes also work at the login
# screen after a reboot or power cut. `conhost.exe --headless` keeps any console window hidden.
@{
    Name = 'Scheduled tasks'
    Run  = {
        param($Ctx)
        $path = '\winctl\'
        $winctl = Join-Path (Get-WinctlPath Bin) 'winctl.cmd'
        $principal = New-ScheduledTaskPrincipal -UserId $Ctx.UserId -LogonType S4U -RunLevel Highest

        function New-HiddenAction { param([string]$CommandLine)
            New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless $CommandLine"
        }
        function New-WinctlAction { param([string]$Arguments)
            New-HiddenAction "cmd.exe /c `"$winctl`" $Arguments"
        }
        function Register-WinctlTask { param([string]$Name, $Action, $Trigger, $Settings)
            $params = @{ TaskName = $Name; TaskPath = $path; Action = $Action; Principal = $principal; Settings = $Settings; Force = $true }
            if ($Trigger) { $params.Trigger = $Trigger }
            Register-ScheduledTask @params | Out-Null
            Write-Done "$path$Name"
        }

        $default = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2) -MultipleInstances IgnoreNew
        # Never run a missed 21:00 check at the next boot: that would hibernate right after waking.
        $night = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew
        $night.StartWhenAvailable = $false
        $forever = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew

        $at = [datetime]::ParseExact($Ctx.System.power.night_check_time, 'HH:mm', $null)
        Register-WinctlTask -Name 'WinCtl-Night' -Action (New-WinctlAction 'night') -Trigger (New-ScheduledTaskTrigger -Daily -At $at) -Settings $night

        $boot = New-ScheduledTaskTrigger -AtStartup
        $boot.Delay = 'PT60S'
        $logon = New-ScheduledTaskTrigger -AtLogOn -User $Ctx.UserId
        $logon.Delay = 'PT30S'
        Register-WinctlTask -Name 'WinCtl-RecoverLogon' -Action (New-WinctlAction 'recover --reason boot') -Trigger @($boot, $logon) -Settings $default

        $class = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
        $resume = $class | New-CimInstance -ClientOnly
        $resume.Enabled = $true
        $resume.Delay = 'PT20S'
        $resume.Subscription = '<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name=''Microsoft-Windows-Power-Troubleshooter''] and EventID=1]]</Select></Query></QueryList>'
        Register-WinctlTask -Name 'WinCtl-RecoverResume' -Action (New-WinctlAction 'recover --reason resume') -Trigger $resume -Settings $default

        # Daily git pull. A missed run happens at next boot (pull only, so that is safe).
        $sync = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -MultipleInstances IgnoreNew
        Register-WinctlTask -Name 'WinCtl-Sync' -Action (New-WinctlAction 'sync --auto') -Trigger (New-ScheduledTaskTrigger -Daily -At '12:00') -Settings $sync

        foreach ($cmd in 'sleep', 'update', 'reboot', 'shutdown') {
            $name = 'WinCtl-' + (Get-Culture).TextInfo.ToTitleCase($cmd)
            Register-WinctlTask -Name $name -Action (New-WinctlAction $cmd) -Trigger $null -Settings $default
        }

        $keepAlive = New-HiddenAction "wsl.exe -d $($Ctx.System.wsl.distro) -u root -- sleep infinity"
        Register-WinctlTask -Name 'WinCtl-WslKeepAlive' -Action $keepAlive -Trigger $null -Settings $forever
        return 'ok'
    }
}
