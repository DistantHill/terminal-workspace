[CmdletBinding()]
param(
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

if ($PSVersionTable.PSEdition -ne "Core" -or $PSVersionTable.PSVersion.Major -lt 7) {
    throw "Install-WTwork.ps1 must run in PowerShell 7 (pwsh)."
}

$installRoot = Join-Path $env:LOCALAPPDATA "WTwork"
$binDirectory = Join-Path $installRoot "bin"
$workspaceDirectory = Join-Path $installRoot "workspaces"
$sourceWorkspaceDirectory = Join-Path $PSScriptRoot "workspaces"
$launcherPath = Join-Path $binDirectory "WTwork.cmd"
$entryScript = Join-Path $installRoot "TerminalWorkspace.ps1"
$runtimeFiles = @(
    "TerminalWorkspace.ps1"
    "Save-TerminalWorkspace.ps1"
    "Open-TerminalWorkspace.ps1"
    "Interactive-Selection.ps1"
    "Get-WslTerminalSessions.py"
    "Get-WslTerminalSessions.sh"
    "Restore-TmuxTab.py"
    "workspace.example.json"
    "README.md"
)

foreach ($fileName in $runtimeFiles) {
    $sourcePath = Join-Path $PSScriptRoot $fileName
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Installation source file is missing: $sourcePath"
    }
}

$launcher = @"
@echo off
pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$entryScript" %*
"@

$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
$pathEntries = @($userPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$pathRegistered = [bool]($pathEntries | Where-Object { $_.TrimEnd('\') -ieq $binDirectory.TrimEnd('\') })

$plan = [ordered]@{
    command = "WTwork"
    installRoot = $installRoot
    binDirectory = $binDirectory
    launcher = $launcherPath
    entryScript = $entryScript
    workspaceDirectory = $workspaceDirectory
    runtimeFiles = $runtimeFiles
    pathChangeRequired = -not $pathRegistered
}

if ($DryRun) {
    $plan | ConvertTo-Json -Depth 4
    exit 0
}

New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
New-Item -ItemType Directory -Path $binDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $workspaceDirectory -Force | Out-Null

foreach ($fileName in $runtimeFiles) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $fileName) -Destination (Join-Path $installRoot $fileName) -Force
}
Set-Content -LiteralPath $launcherPath -Value $launcher -Encoding ascii

if (Test-Path -LiteralPath $sourceWorkspaceDirectory -PathType Container) {
    foreach ($workspaceFile in (Get-ChildItem -LiteralPath $sourceWorkspaceDirectory -Filter "*.json" -File)) {
        $targetWorkspacePath = Join-Path $workspaceDirectory $workspaceFile.Name
        if (-not (Test-Path -LiteralPath $targetWorkspacePath)) {
            Copy-Item -LiteralPath $workspaceFile.FullName -Destination $targetWorkspacePath
        }
    }
}

if (-not $pathRegistered) {
    $newUserPath = if ([string]::IsNullOrWhiteSpace($userPath)) {
        $binDirectory
    } elseif ($userPath.EndsWith(';')) {
        "$userPath$binDirectory"
    } else {
        "$userPath;$binDirectory"
    }
    [Environment]::SetEnvironmentVariable("Path", $newUserPath, "User")
}

Write-Host "WTwork installed to $installRoot"
Write-Host "Command registered: WTwork"
Write-Host "Open a new terminal, then run: WTwork list"
