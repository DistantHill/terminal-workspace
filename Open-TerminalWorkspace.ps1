[CmdletBinding()]
param(
    [string]$Config = (Join-Path $PSScriptRoot "workspace.json"),
    [switch]$Tmux,
    [switch]$DryRun,
    [string]$WtPath,
    [string]$WindowTarget
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $Config -PathType Leaf)) {
    throw "Workspace config not found: $Config"
}

$workspace = Get-Content -LiteralPath $Config -Raw | ConvertFrom-Json
$distribution = [string]$workspace.distribution
$profile = [string]$workspace.profile
$workspaceName = [string]$workspace.name
$schemaVersion = [int]$workspace.schemaVersion

if ([string]::IsNullOrWhiteSpace($distribution)) {
    throw "Config field 'distribution' is required."
}
if ([string]::IsNullOrWhiteSpace($profile)) {
    $profile = $distribution
}
if ($workspaceName -match '[\x00-\x1F]') {
    throw "Config field 'name' cannot contain control characters."
}

if ($schemaVersion -eq 2) {
    $workspaceMode = [string]$workspace.mode
    if ($workspaceMode -notin @("tmux", "terminal")) {
        throw "V2 config field 'mode' must be 'tmux' or 'terminal'."
    }
    if ($Tmux -and $workspaceMode -ne "tmux") {
        throw "Workspace '$workspaceName' uses terminal mode, not tmux."
    }
    $useTmux = $workspaceMode -eq "tmux"
    $workspaceProjects = @(
        $entries = if ($useTmux) { @($workspace.tmux.windows) } else { @($workspace.terminal.tabs) }
        foreach ($entry in $entries) {
            $panes = @(
                foreach ($pane in @($entry.panes)) {
                    [pscustomobject]@{
                        index = [int]$pane.index
                        directory = [string]$pane.directory
                        mode = [string]$pane.session_type
                        sessionId = [string]$pane.sessionId
                        sessionName = [string]$pane.sessionName
                    }
                }
            )
            $layout = if ($useTmux) {
                [pscustomobject]@{
                    activePane = [int]$entry.activePane
                    splits = @(
                        for ($paneIndex = 1; $paneIndex -lt $panes.Count; $paneIndex++) {
                            [pscustomobject]@{ direction = "right"; size = 0.5 }
                        }
                    )
                    tmux = [string]$entry.layout
                }
            } else {
                $entry.layout
            }
            [pscustomobject]@{
                name = [string]$entry.name
                mode = "layout"
                panes = $panes
                layout = $layout
            }
        }
    )
} elseif ($schemaVersion -eq 0) {
    $useTmux = [bool]$Tmux
    $workspaceProjects = @($workspace.projects)
} else {
    throw "Unsupported workspace schemaVersion: $schemaVersion"
}

if ($workspaceProjects.Count -lt 1) {
    throw "Config must contain at least one tab or window."
}

$wtExecutable = "wt.exe"
if ($WtPath) {
    if (-not (Test-Path -LiteralPath $WtPath -PathType Leaf)) {
        throw "wt.exe was not found at: $WtPath"
    }
    $wtExecutable = (Resolve-Path -LiteralPath $WtPath).Path
} elseif (-not $DryRun) {
    $wtCommand = Get-Command wt.exe -ErrorAction SilentlyContinue
    if (-not $wtCommand) {
        throw "wt.exe was not found on PATH. Install Windows Terminal or pass -WtPath."
    }
    $wtExecutable = if ($wtCommand.CommandType -eq 'Function') { $wtCommand.Name } else { $wtCommand.Path }
}

if (-not $DryRun -and -not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw "wsl.exe was not found on PATH."
}

function Get-NormalizedTab {
    param([object]$Project, [int]$TabIndex)

    $name = [string]$Project.name
    if ([string]::IsNullOrWhiteSpace($name)) {
        throw "Every project must have a non-empty 'name'."
    }

    $mode = [string]$Project.mode
    if ([string]::IsNullOrWhiteSpace($mode)) {
        $mode = "codex"
    }

    if ($mode -eq "layout") {
        $panes = @($Project.panes)
        $layout = $Project.layout
    } elseif ($mode -eq "tmux") {
        $panes = @($Project.tmux.panes)
        $layout = [pscustomobject]@{
            activePane = [int]$Project.tmux.activePane
            splits = @(
                for ($index = 1; $index -lt $panes.Count; $index++) {
                    [pscustomobject]@{ direction = "right"; size = 0.5 }
                }
            )
            tmux = [string]$Project.tmux.layout
        }
    } elseif ($mode -in @("codex", "shell")) {
        $panes = @(
            [pscustomobject]@{
                index = 0
                directory = [string]$Project.directory
                mode = $mode
                sessionId = [string]$Project.sessionId
                sessionName = [string]$Project.sessionName
            }
        )
        $layout = [pscustomobject]@{ activePane = 0; splits = @(); tmux = $null }
    } else {
        throw "Project '$name' has an invalid mode."
    }

    if ($panes.Count -lt 1) {
        throw "Project '$name' must contain at least one pane."
    }
    for ($paneIndex = 0; $paneIndex -lt $panes.Count; $paneIndex++) {
        $pane = $panes[$paneIndex]
        $paneMode = [string]$pane.mode
        $paneDirectory = [string]$pane.directory
        $sessionId = [string]$pane.sessionId
        if ([int]$pane.index -ne $paneIndex) {
            throw "Project '$name' pane indexes must be sequential and start at zero."
        }
        if ([string]::IsNullOrWhiteSpace($paneDirectory) -or $paneDirectory -notmatch '^/') {
            throw "Project '$name' pane $paneIndex must use an absolute WSL directory."
        }
        if ($paneMode -notin @("codex", "shell")) {
            throw "Project '$name' pane $paneIndex has an invalid mode."
        }
        if ($paneMode -eq "codex" -and -not [string]::IsNullOrWhiteSpace($sessionId) -and $sessionId -ne "last" -and $sessionId -notmatch '^[A-Za-z0-9._-]+$') {
            throw "Project '$name' pane $paneIndex has an invalid Codex session ID."
        }
    }

    $splits = @($layout.splits)
    if ($splits.Count -ne $panes.Count - 1) {
        throw "Project '$name' must define one split for every pane after pane 0."
    }
    foreach ($split in $splits) {
        if ([string]$split.direction -notin @("right", "down")) {
            throw "Project '$name' split direction must be 'right' or 'down'."
        }
        $size = [double]$split.size
        if ($size -le 0 -or $size -ge 1) {
            throw "Project '$name' split size must be between 0 and 1."
        }
    }
    $activePane = [int]$layout.activePane
    if ($activePane -lt 0 -or $activePane -ge $panes.Count) {
        throw "Project '$name' has an invalid activePane."
    }

    [pscustomobject]@{
        index = $TabIndex
        name = $name
        panes = $panes
        layout = [pscustomobject]@{
            activePane = $activePane
            splits = $splits
            tmux = [string]$layout.tmux
        }
    }
}

function Get-WslPaneArguments {
    param([object]$Pane, [int]$TabIndex, [int]$PaneIndex)

    $terminalCommand = if ([string]$Pane.mode -eq "shell") {
        $null
    } elseif ([string]::IsNullOrWhiteSpace([string]$Pane.sessionId)) {
        "exec codex"
    } elseif ([string]$Pane.sessionId -eq "last") {
        "exec codex resume --last"
    } else {
        "exec codex resume $([string]$Pane.sessionId)"
    }

    $arguments = @(
        "wsl.exe",
        "-d", $distribution,
        "--cd", [string]$Pane.directory,
        "--",
        "env",
        "TERMINAL_WORKSPACE_NAME=$workspaceName",
        "TERMINAL_WORKSPACE_TAB_ID=$TabIndex",
        "TERMINAL_WORKSPACE_PANE_INDEX=$PaneIndex"
    )
    if ([string]$Pane.mode -eq "codex") {
        if (-not [string]::IsNullOrWhiteSpace([string]$Pane.sessionId)) {
            $arguments += "TERMINAL_CODEX_SESSION_ID=$([string]$Pane.sessionId)"
        }
        $arguments += @("zsh", "-lic", $terminalCommand)
    } else {
        $arguments += @("zsh", "-l")
    }
    $arguments
}

$tabs = @(
    for ($tabIndex = 0; $tabIndex -lt $workspaceProjects.Count; $tabIndex++) {
        Get-NormalizedTab -Project $workspaceProjects[$tabIndex] -TabIndex $tabIndex
    }
)

$windowTarget = if ($WindowTarget) { $WindowTarget } elseif ($workspaceName) { $workspaceName } else { "new" }
$wtArguments = @("--window", $windowTarget)

if ($useTmux) {
    if ($workspaceName -match '[:.]') {
        throw "tmux session names cannot contain ':' or '.'. Rename the workspace before using --tmux."
    }
    $payload = [ordered]@{
        workspaceName = $workspaceName
        tabs = $tabs
    }
    $payloadJson = $payload | ConvertTo-Json -Depth 10 -Compress
    $payloadBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payloadJson))
    $restoreScriptPath = Join-Path $PSScriptRoot "Restore-TmuxTab.py"
    if ($restoreScriptPath -notmatch '^(?<drive>[A-Za-z]):\\(?<path>.+)$') {
        throw "The tmux restore helper must be stored on a Windows drive visible to WSL."
    }
    $restoreScriptWslPath = "/mnt/$($Matches.drive.ToLower())/$($Matches.path.Replace('\', '/'))"
    $firstPane = $tabs[0].panes[0]
    $wtArguments += @(
        "new-tab",
        "--profile", $profile,
        "--title", $workspaceName,
        "--suppressApplicationTitle",
        "wsl.exe",
        "-d", $distribution,
        "--cd", [string]$firstPane.directory,
        "--",
        "env", "TERMINAL_WORKSPACE_NAME=$workspaceName",
        "python3", $restoreScriptWslPath, $payloadBase64
    )
} else {
    foreach ($tab in $tabs) {
        if ($wtArguments.Count -gt 2) {
            $wtArguments += ";"
        }
        $wtArguments += @(
            "new-tab",
            "--profile", $profile,
            "--title", [string]$tab.name,
            "--suppressApplicationTitle"
        ) + (Get-WslPaneArguments -Pane $tab.panes[0] -TabIndex $tab.index -PaneIndex 0)

        for ($paneIndex = 1; $paneIndex -lt $tab.panes.Count; $paneIndex++) {
            $split = $tab.layout.splits[$paneIndex - 1]
            $orientation = if ([string]$split.direction -eq "right") { "-V" } else { "-H" }
            $size = ([double]$split.size).ToString("0.########", [Globalization.CultureInfo]::InvariantCulture)
            $wtArguments += @(
                ";",
                "split-pane",
                $orientation,
                "--size", $size,
                "--profile", $profile,
                "--title", [string]$tab.name,
                "--suppressApplicationTitle"
            ) + (Get-WslPaneArguments -Pane $tab.panes[$paneIndex] -TabIndex $tab.index -PaneIndex $paneIndex)
        }
        if ($tab.panes.Count -gt 1) {
            $wtArguments += @(";", "move-focus", "first")
            for ($focusIndex = 0; $focusIndex -lt $tab.layout.activePane; $focusIndex++) {
                $wtArguments += @(";", "move-focus", "nextInOrder")
            }
        }
    }
}

if ($DryRun) {
    [pscustomobject]@{
        executable = $wtExecutable
        renderer = if ($useTmux) { "tmux" } else { "windows-terminal" }
        arguments = $wtArguments
    } | ConvertTo-Json -Depth 5
    exit 0
}

$tmuxSessionExisted = $false
if ($useTmux) {
    & wsl.exe -d $distribution -- tmux has-session -t $workspaceName 2>$null
    if ($LASTEXITCODE -eq 0) {
        $tmuxSessionExisted = $true
    } elseif ($LASTEXITCODE -ne 1) {
        throw "Could not determine whether tmux session '$workspaceName' exists."
    }
}

& $wtExecutable @wtArguments
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

Write-Host ""
if ($useTmux) {
    if ($tmuxSessionExisted) {
        Write-Host "操作结果：检测到同名 tmux session [$workspaceName]，已走附着分支。"
    } else {
        Write-Host "操作结果：未检测到同名 tmux session [$workspaceName]，已走重建并附着分支。"
    }
} else {
    $paneCount = @($tabs | ForEach-Object { @($_.panes).Count } | Measure-Object -Sum).Sum
    Write-Host "操作结果：已走 Windows Terminal 重建分支，提交创建 $($tabs.Count) 个 Tab、$paneCount 个 Pane。"
}
