# WSL2 + Ubuntu with systemd and a default (non-root) user.
@{
    Name = 'WSL2 + Ubuntu'
    Run  = {
        param($Ctx)
        . (Join-Path $Ctx.RepoRoot 'winctl\lib\Services.ps1')
        $distro = $Ctx.System.wsl.distro
        $user = $Ctx.System.wsl.default_user

        $needReboot = $false
        foreach ($feature in 'Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform') {
            $state = (Get-WindowsOptionalFeature -Online -FeatureName $feature).State
            if ($state -ne 'Enabled') {
                Write-Done "Enabling $feature"
                Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart | Out-Null
                $needReboot = $true
            }
        }
        if ($needReboot) { return 'reboot' }

        Invoke-WinctlWsl -Arguments @('--update') | Out-Null
        Invoke-WinctlWsl -Arguments @('--set-default-version', '2') | Out-Null

        function Test-DistroRegistered {
            $list = Invoke-WinctlWsl -Arguments @('--list', '--quiet')
            return (($list.Output -split "`r?`n" | ForEach-Object { $_.Trim() }) -contains $distro)
        }

        if (-not (Test-DistroRegistered)) {
            Write-Done "Installing $distro"
            Invoke-WinctlWsl -Arguments @('--install', '-d', $distro, '--no-launch') | Out-Null
            if (-not (Test-DistroRegistered)) {
                # Appx-based distros register on first launch; "install --root" skips the interactive user prompt.
                $launcher = ($distro -replace '[-.]', '').ToLowerInvariant() + '.exe'
                if (Get-Command $launcher -ErrorAction SilentlyContinue) { & $launcher install --root | Out-Null }
            }
            if (-not (Test-DistroRegistered)) {
                Add-ManualAction "Could not register $distro automatically. Run 'wsl --install -d $distro' once, then re-run the installer."
                return 'ok'
            }
        }

        # Default user, systemd, wsl.conf (idempotent shell script).
        $script = @"
set -e
id -u '$user' >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo '$user'
cat > /etc/wsl.conf <<'CONF'
# Managed by windows-personal-cloud (installer/steps/30-wsl.ps1)
[boot]
systemd=true

[user]
default=$user
CONF
"@
        $r = Invoke-WinctlWsl -Arguments @('-d', $distro, '-u', 'root', '--', 'bash', '-c', ($script -replace "`r", ''))
        if ($r.ExitCode -ne 0) { throw "WSL configuration failed: $($r.Output)" }

        $pw = Invoke-WinctlWsl -Arguments @('-d', $distro, '-u', 'root', '--', 'passwd', '-S', $user)
        if ($pw.Output -match "^$user\s+(L|NP)\b") {
            Add-ManualAction "Set a Linux password for '$user' (needed for sudo): wsl -d $distro -u root passwd $user"
        }
        # Restart the distro so systemd / default user take effect.
        Invoke-WinctlWsl -Arguments @('--terminate', $distro) | Out-Null
        Write-Done "$distro ready (user $user, systemd on)"
        return 'ok'
    }
}
