[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$ActionOrName,
    [Parameter(Position = 1)]
    [string]$Name,
    [Parameter(Position = 2)]
    [string]$Option,
    [switch]$Tmux
)

$ErrorActionPreference = "Stop"
$workspacesDirectory = Join-Path $PSScriptRoot "workspaces"

if ($Name -eq "--tmux") {
    $Name = $null
    $Tmux = $true
}
if ($Option) {
    if ($Option -ne "--tmux") {
        throw "Unknown option: $Option"
    }
    $Tmux = $true
}

if ([string]::IsNullOrWhiteSpace($ActionOrName)) {
    $ActionOrName = Read-Host "输入 workspace 名称"
}

switch ($ActionOrName) {
    "save" {
        if ([string]::IsNullOrWhiteSpace($Name)) {
            $Name = Read-Host "输入新 workspace 名称"
        }
        & (Join-Path $PSScriptRoot "Save-TerminalWorkspace.ps1") -Name $Name -Tmux:$Tmux
        exit $LASTEXITCODE
    }
    "list" {
        if (-not (Test-Path -LiteralPath $workspacesDirectory -PathType Container)) {
            Write-Host "还没有保存的 workspace。"
            exit 0
        }

        $items = foreach ($file in (Get-ChildItem -LiteralPath $workspacesDirectory -Filter "*.json" -File)) {
            $workspace = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            [pscustomobject]@{
                Name = $workspace.name
                Tabs = $workspace.projects.Count
                Path = $file.FullName
            }
        }
        $items | Format-Table Name,Tabs,Path -AutoSize
        exit 0
    }
    default {
        $workspaceName = $ActionOrName
        if (
            [string]::IsNullOrWhiteSpace($workspaceName) -or
            $workspaceName -in @(".", "..") -or
            $workspaceName -ne [IO.Path]::GetFileName($workspaceName) -or
            $workspaceName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0
        ) {
            throw "Invalid workspace name: $workspaceName"
        }

        $workspacePath = Join-Path $workspacesDirectory "$workspaceName.json"
        if (-not (Test-Path -LiteralPath $workspacePath -PathType Leaf)) {
            throw "Workspace '$workspaceName' does not exist. Run '.\TerminalWorkspace.ps1 list' to see saved names."
        }

        & (Join-Path $PSScriptRoot "Open-TerminalWorkspace.ps1") -Config $workspacePath -Tmux:$Tmux
        exit $LASTEXITCODE
    }
}
