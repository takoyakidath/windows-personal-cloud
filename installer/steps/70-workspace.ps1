# Workspace folders (product.txt §13). Only creates; never deletes or moves anything.
@{
    Name = 'Workspace'
    Run  = {
        param($Ctx)
        $root = Get-WinctlWorkspacePath $Ctx.System
        if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root | Out-Null; Write-Done "Created $root" }
        foreach ($name in @($Ctx.System.workspace.folders)) {
            $dir = Join-Path $root $name
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null; Write-Done "Created $dir" }
        }
        $Ctx.Facts['Workspace'] = $root
        return 'ok'
    }
}
