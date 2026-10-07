# OS / architecture / storage detection. Fails early on unsupported systems.
@{
    Name = 'Preflight: OS, architecture, storage'
    Run  = {
        param($Ctx)
        $os = Get-CimInstance Win32_OperatingSystem
        $build = [int]$os.BuildNumber
        $arch = $env:PROCESSOR_ARCHITECTURE
        Write-Done "OS: $($os.Caption) build $build ($arch)"
        if ($build -lt 19041) { throw "Windows build $build is too old for WSL2 (need 19041+)." }
        if (@('AMD64', 'ARM64') -notcontains $arch) { throw "Unsupported architecture: $arch" }

        $Ctx.Facts['IsHomeEdition'] = ($os.Caption -match 'Home')
        $Ctx.Facts['Build'] = $build

        $workspace = Get-WinctlWorkspacePath $Ctx.System
        if ($workspace -ne $Ctx.System.workspace.path) {
            Add-ManualAction "Drive for $($Ctx.System.workspace.path) not found; using fallback $workspace."
        }
        $Ctx.Facts['Workspace'] = $workspace
        foreach ($d in Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3') {
            Write-Done ('Disk {0} {1} GB free' -f $d.DeviceID, [math]::Round($d.FreeSpace / 1GB, 0))
        }
        if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
            Add-ManualAction 'winget not found: update "App Installer" from the Microsoft Store, then run winctl update.'
        }
        return 'ok'
    }
}
