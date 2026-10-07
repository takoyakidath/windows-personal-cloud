# SMB share of the Workspace for the Mac (product.txt §14). SMB1 off, encryption on.
@{
    Name = 'SMB share'
    Run  = {
        param($Ctx)
        if (-not $Ctx.System.remote.smb) { Write-Done 'Disabled in config'; return 'ok' }
        Set-Service -Name LanmanServer -StartupType Automatic
        Start-Service -Name LanmanServer
        Set-SmbServerConfiguration -EnableSMB1Protocol $false -Confirm:$false

        $name = $Ctx.System.workspace.smb_share_name
        $path = Get-WinctlWorkspacePath $Ctx.System
        $share = Get-SmbShare -Name $name -ErrorAction SilentlyContinue
        if (-not $share) {
            New-SmbShare -Name $name -Path $path -FullAccess $Ctx.UserId -EncryptData $true | Out-Null
            Write-Done "Shared $path as \\$env:COMPUTERNAME\$name (access: $($Ctx.UserId))"
        } elseif ($share.Path -ne $path) {
            Add-ManualAction "SMB share '$name' already points to $($share.Path), not $path. Left unchanged."
        } else {
            if (-not $share.EncryptData) { Set-SmbShare -Name $name -EncryptData $true -Force }
            Write-Done "Share '$name' already configured"
        }
        return 'ok'
    }
}
