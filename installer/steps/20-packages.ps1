# Applications from config/system.json "packages" (winget ids).
@{
    Name = 'Packages (winget)'
    Run  = {
        param($Ctx)
        foreach ($id in @($Ctx.System.packages)) {
            & winget.exe list --id $id --exact --accept-source-agreements --disable-interactivity | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-Done "$id already installed"; continue }
            Write-Done "Installing $id"
            & winget.exe install --id $id --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
            if ($LASTEXITCODE -ne 0) { Add-ManualAction "winget install $id failed (exit $LASTEXITCODE)." }
        }
        # Pick up PATH changes from installers in this session.
        $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
        return 'ok'
    }
}
