# OpenSSH Server with key auth. The Raspberry Pi key gets a forced command (winctl remote) so it
# can only run allowlisted winctl commands (product.txt §6.2, §32).
@{
    Name = 'OpenSSH Server'
    Run  = {
        param($Ctx)
        if (-not $Ctx.System.remote.ssh) { Write-Done 'Disabled in config'; return 'ok' }

        # Newer Windows ships sshd preinstalled; otherwise add the optional capability.
        if (-not (Get-Service -Name sshd -ErrorAction SilentlyContinue)) {
            $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
            if (-not $cap) { throw 'OpenSSH.Server capability not found on this Windows.' }
            Write-Done 'Installing OpenSSH.Server capability'
            Add-WindowsCapability -Online -Name $cap.Name | Out-Null
        }
        Set-Service -Name sshd -StartupType Automatic
        Start-Service -Name sshd

        # PowerShell as the SSH shell (forced commands are run through it as well).
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value $ps

        # Managed block in administrators_authorized_keys; lines outside the block are preserved.
        $sshDir = Join-Path $env:ProgramData 'ssh'
        $keysFile = Join-Path $sshDir 'administrators_authorized_keys'
        $begin = '# BEGIN windows-personal-cloud (managed by installer/steps/60-openssh.ps1)'
        $end = '# END windows-personal-cloud'

        $managed = @()
        $personal = @()   # keys that give a human a full shell (not the controller's forced-command key)
        $userKeys = Join-Path $Ctx.RepoRoot 'config\ssh\authorized_keys'
        if (Test-Path -LiteralPath $userKeys) {
            $personal = @(Get-Content -LiteralPath $userKeys | Where-Object { $_ -match '^(ssh-|ecdsa-|sk-)' })
            $managed += $personal
        }
        $controllerKey = Join-Path $Ctx.RepoRoot 'config\ssh\controller.pub'
        if (Test-Path -LiteralPath $controllerKey) {
            $winctlCmd = Join-Path (Get-WinctlPath Bin) 'winctl.cmd'
            $opts = "command=`"$winctlCmd remote`",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty"
            foreach ($k in Get-Content -LiteralPath $controllerKey | Where-Object { $_ -match '^(ssh-|ecdsa-|sk-)' }) {
                $managed += "$opts $k"
            }
        }

        $existing = @()
        if (Test-Path -LiteralPath $keysFile) { $existing = @(Get-Content -LiteralPath $keysFile) }
        $kept = @()
        $inBlock = $false
        foreach ($line in $existing) {
            if ($line -eq $begin) { $inBlock = $true; continue }
            if ($line -eq $end) { $inBlock = $false; continue }
            if (-not $inBlock) { $kept += $line }
        }
        $content = @($kept) + @($begin) + $managed + @($end)
        Set-Content -LiteralPath $keysFile -Value $content -Encoding ASCII
        # sshd ignores this file unless only Administrators and SYSTEM can access it (SIDs: locale-independent).
        & icacls.exe $keysFile /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
        Write-Done "$($managed.Count) managed key(s) installed"

        # Only turn off passwords when a person can still get in with a key. The controller key alone
        # must not lock the owner out (it can only run `winctl remote`).
        $loginKeys = @($kept | Where-Object { $_ -match '^(ssh-|ecdsa-|sk-)' }) + $personal
        $config = Join-Path $sshDir 'sshd_config'
        if ($loginKeys.Count -gt 0 -and (Test-Path -LiteralPath $config)) {
            $text = Get-Content -LiteralPath $config -Raw
            $desired = 'PasswordAuthentication no'
            if ($text -notmatch '(?m)^PasswordAuthentication no\s*$') {
                $text = $text -replace '(?m)^#?\s*PasswordAuthentication\s+\S+\s*$', $desired
                if ($text -notmatch '(?m)^PasswordAuthentication no\s*$') { $text = "$desired`r`n" + $text }
                Set-Content -LiteralPath $config -Value $text -Encoding ASCII -NoNewline
                Restart-Service -Name sshd
                Write-Done 'Password authentication disabled'
            }
        } else {
            Add-ManualAction 'No personal SSH key (config/ssh/authorized_keys); password authentication left enabled.'
        }
        return 'ok'
    }
}
