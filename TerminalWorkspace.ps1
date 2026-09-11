[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$ActionOrName,
    [Parameter(Position = 1)]
    [string]$LegacyName,
    [Parameter(Position = 2)]
    [string]$Option,
    [Alias("n")]
    [string]$Name,
    [switch]$Tmux,
    [switch]$Force,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$dataRoot = if ($env:WTWORK_DATA_HOME) {
    [IO.Path]::GetFullPath($env:WTWORK_DATA_HOME)
} elseif ($env:LOCALAPPDATA) {
    Join-Path $env:LOCALAPPDATA "WTwork"
} else {
    throw "LOCALAPPDATA is required unless WTWORK_DATA_HOME is set."
}
$workspacesDirectory = Join-Path $dataRoot "workspaces"

function Get-EditDistance {
    param([string]$Left, [string]$Right)

    $leftText = $Left.ToLowerInvariant()
    $rightText = $Right.ToLowerInvariant()
    $previous = @(0..$rightText.Length)
    for ($leftIndex = 1; $leftIndex -le $leftText.Length; $leftIndex++) {
        $current = @($leftIndex)
        for ($rightIndex = 1; $rightIndex -le $rightText.Length; $rightIndex++) {
            $cost = if ($leftText[$leftIndex - 1] -ceq $rightText[$rightIndex - 1]) { 0 } else { 1 }
            $current += [math]::Min(
                [math]::Min($current[$rightIndex - 1] + 1, $previous[$rightIndex] + 1),
                $previous[$rightIndex - 1] + $cost
            )
        }
        $previous = $current
    }
    $previous[$rightText.Length]
}

if ($LegacyName -eq "--tmux") {
    $LegacyName = $null
    $Tmux = $true
}
if ($Option) {
    if ($Option -ne "--tmux") {
        throw "Unknown option: $Option"
    }
    $Tmux = $true
}

if ([string]::IsNullOrWhiteSpace($ActionOrName)) {
    $action = "open"
} elseif ($ActionOrName -in @("save", "open", "list")) {
    $action = $ActionOrName
} else {
    $action = "open"
    if ([string]::IsNullOrWhiteSpace($Name)) {
        $Name = $ActionOrName
    }
}

if ([string]::IsNullOrWhiteSpace($Name) -and -not [string]::IsNullOrWhiteSpace($LegacyName)) {
    $Name = $LegacyName
}

switch ($action) {
    "save" {
        & (Join-Path $PSScriptRoot "Save-TerminalWorkspace.ps1") -Name $Name -Tmux:$Tmux -Force:$Force -DryRun:$DryRun
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
                Mode = if ([int]$workspace.schemaVersion -eq 2) { [string]$workspace.mode } else { "legacy" }
                Tabs = if ([int]$workspace.schemaVersion -eq 2) {
                    if ([string]$workspace.mode -eq "tmux") { @($workspace.tmux.windows).Count } else { @($workspace.terminal.tabs).Count }
                } else {
                    @($workspace.projects).Count
                }
                Path = $file.FullName
            }
        }
        $items | Format-Table Name,Mode,Tabs,Path -AutoSize
        exit 0
    }
    "open" {
        if ([string]::IsNullOrWhiteSpace($Name)) {
            if ($Tmux) {
                if (-not (Test-Path -LiteralPath $workspacesDirectory -PathType Container)) {
                    throw "No saved tmux workspaces were found."
                }
                $tmuxWorkspaces = @(
                    foreach ($file in (Get-ChildItem -LiteralPath $workspacesDirectory -Filter "*.json" -File)) {
                        $workspace = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
                        if ([int]$workspace.schemaVersion -eq 2 -and [string]$workspace.mode -eq "tmux") {
                            [pscustomobject]@{
                                Index = 0
                                Name = [string]$workspace.name
                                Windows = @($workspace.tmux.windows).Count
                                Path = $file.FullName
                            }
                        }
                    }
                )
                if ($tmuxWorkspaces.Count -eq 0) {
                    throw "No saved tmux workspaces were found."
                }
                for ($index = 0; $index -lt $tmuxWorkspaces.Count; $index++) {
                    $tmuxWorkspaces[$index].Index = $index + 1
                }
                $tmuxWorkspaces | Format-Table Index,Name,Windows -AutoSize | Out-Host
                $selection = Read-Host "选择 tmux workspace 编号（逗号分隔；直接回车取消）"
                if ([string]::IsNullOrWhiteSpace($selection)) {
                    exit 0
                }
                $tokens = @($selection -split ',' | ForEach-Object { $_.Trim() })
                if ($tokens | Where-Object { $_ -notmatch '^\d+$' }) {
                    throw "One or more selected workspace numbers are invalid."
                }
                $indexes = @($tokens | ForEach-Object { [int]$_ })
                if ($indexes | Where-Object { $_ -lt 1 -or $_ -gt $tmuxWorkspaces.Count }) {
                    throw "One or more selected workspace numbers are invalid."
                }
                $selectedWorkspaces = @($indexes | ForEach-Object { $tmuxWorkspaces[$_ - 1] })
                $sharedWindowTarget = "WTwork-open-$PID"
                if ($DryRun) {
                    $plans = @(
                        foreach ($selectedWorkspace in $selectedWorkspaces) {
                            & (Join-Path $PSScriptRoot "Open-TerminalWorkspace.ps1") -Config $selectedWorkspace.Path -WindowTarget $sharedWindowTarget -DryRun | ConvertFrom-Json
                        }
                    )
                    ConvertTo-Json -InputObject $plans -Depth 10
                } else {
                    foreach ($selectedWorkspace in $selectedWorkspaces) {
                        & (Join-Path $PSScriptRoot "Open-TerminalWorkspace.ps1") -Config $selectedWorkspace.Path -WindowTarget $sharedWindowTarget
                    }
                }
                exit $LASTEXITCODE
            }
            $Name = "TempTab"
        }

        if (
            $Name -in @(".", "..") -or
            $Name -ne [IO.Path]::GetFileName($Name) -or
            $Name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0
        ) {
            throw "Invalid workspace name: $Name"
        }
        $workspacePath = Join-Path $workspacesDirectory "$Name.json"
        if (-not (Test-Path -LiteralPath $workspacePath -PathType Leaf)) {
            $savedNames = @(
                if (Test-Path -LiteralPath $workspacesDirectory -PathType Container) {
                    foreach ($file in (Get-ChildItem -LiteralPath $workspacesDirectory -Filter "*.json" -File)) {
                        [string](Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json).name
                    }
                }
            )
            $similarNames = @($savedNames | Sort-Object { Get-EditDistance -Left $Name -Right $_ } | Select-Object -First 3)
            $similarMessage = if ($similarNames.Count -gt 0) { "`n相似 workspace:`n  $($similarNames -join "`n  ")" } else { "" }
            throw "Workspace '$Name' does not exist.$similarMessage"
        }

        $workspace = Get-Content -LiteralPath $workspacePath -Raw | ConvertFrom-Json
        $openWithTmux = if ([int]$workspace.schemaVersion -eq 2) { [string]$workspace.mode -eq "tmux" } else { [bool]$Tmux }
        & (Join-Path $PSScriptRoot "Open-TerminalWorkspace.ps1") -Config $workspacePath -Tmux:$openWithTmux -DryRun:$DryRun
        exit $LASTEXITCODE
    }
}
