[CmdletBinding()]
param(
    [string]$Name,
    [string]$Distribution = "Ubuntu-22.04",
    [string]$Profile = "Ubuntu-22.04",
    [switch]$Tmux,
    [switch]$All,
    [switch]$Force,
    [switch]$DryRun,
    [scriptblock]$SelectionKeyReader
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Interactive-Selection.ps1")
$dataRoot = if ($env:WTWORK_DATA_HOME) {
    [IO.Path]::GetFullPath($env:WTWORK_DATA_HOME)
} elseif ($env:LOCALAPPDATA) {
    Join-Path $env:LOCALAPPDATA "WTwork"
} else {
    throw "LOCALAPPDATA is required unless WTWORK_DATA_HOME is set."
}
$workspacesDirectory = Join-Path $dataRoot "workspaces"
$explicitName = -not [string]::IsNullOrWhiteSpace($Name)

function ConvertTo-WorkspaceName {
    param([string]$Value, [string]$Mode)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "Workspace name cannot be empty."
    }
    $invalidCharacters = [IO.Path]::GetInvalidFileNameChars()
    -join @(
        for ($index = 0; $index -lt $Value.Length; $index++) {
            $character = $Value[$index]
            if (
                $character -in $invalidCharacters -or
                ($Mode -eq 'tmux' -and $character -eq '.') -or
                ($index -eq $Value.Length - 1 -and $character -in @('.', ' '))
            ) {
                '_'
            } else {
                $character
            }
        }
    )
}

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw "wsl.exe was not found on PATH."
}

function Get-Pane {
    param([object[]]$Processes, [int]$Index)

    $codexProcesses = @($Processes | Where-Object { $_.IsCodex -and $_.SessionId })
    $selectedProcess = $codexProcesses | Select-Object -First 1
    if (-not $selectedProcess) {
        $selectedProcess = $Processes | Where-Object { -not $_.IsCodex } | Select-Object -First 1
    }
    if (-not $selectedProcess) {
        $selectedProcess = $Processes[0]
    }

    [pscustomobject]@{
        Index = $Index
        Directory = [string]$selectedProcess.Directory
        Mode = if ($codexProcesses.Count -gt 0) { "codex" } else { "shell" }
        SessionId = [string]$selectedProcess.SessionId
        SessionName = [string]$selectedProcess.SessionName
        Active = [bool]($Processes | Where-Object TmuxPaneActive)
    }
}

function New-SequentialLayout {
    param([int]$PaneCount, [int]$ActivePane = 0, [string]$TmuxLayout = "")

    [ordered]@{
        activePane = $ActivePane
        splits = @(
            for ($paneIndex = 1; $paneIndex -lt $PaneCount; $paneIndex++) {
                $remainingPanes = $PaneCount - $paneIndex + 1
                [ordered]@{
                    direction = "right"
                    size = ($remainingPanes - 1) / $remainingPanes
                }
            }
        )
        tmux = if ($TmuxLayout) { $TmuxLayout } else { $null }
    }
}

function Get-SourceProject {
    param([string]$WorkspaceName, [string]$TabId)

    if ([string]::IsNullOrWhiteSpace($WorkspaceName) -or $TabId -notmatch '^\d+$') {
        return $null
    }
    $sourcePath = Join-Path $workspacesDirectory "$WorkspaceName.json"
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        return $null
    }
    $sourceWorkspace = Get-Content -LiteralPath $sourcePath -Raw | ConvertFrom-Json
    $sourceProjects = if ([int]$sourceWorkspace.schemaVersion -eq 2 -and [string]$sourceWorkspace.mode -eq "terminal") {
        @($sourceWorkspace.terminal.tabs)
    } else {
        @($sourceWorkspace.projects)
    }
    $index = [int]$TabId
    if ($index -ge $sourceProjects.Count) {
        return $null
    }
    $sourceProjects[$index]
}

$scannerPath = Join-Path $PSScriptRoot "Get-WslTerminalSessions.sh"
$previousConsoleOutputEncoding = [Console]::OutputEncoding
try {
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    $scannerWslPath = (& wsl.exe -d $Distribution --exec wslpath -a -u $scannerPath).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Could not translate the WSL session scanner path."
    }
    $scannerOutput = & wsl.exe -d $Distribution -- sh $scannerWslPath
    if ($LASTEXITCODE -ne 0) {
        throw "Could not scan running Ubuntu Terminal sessions."
    }
} finally {
    [Console]::OutputEncoding = $previousConsoleOutputEncoding
}

$processes = foreach ($line in $scannerOutput) {
    $parts = $line -split "`t", 16
    if ($parts.Count -eq 16) {
        [pscustomobject]@{
            Session = $parts[0]
            Directory = $parts[1]
            IsCodex = $parts[2] -eq "1"
            Workspace = $parts[3]
            TabId = $parts[4]
            PaneIndex = $parts[5]
            SessionId = $parts[6]
            SessionName = $parts[7]
            TmuxSession = $parts[8]
            TmuxWindowId = $parts[9]
            TmuxWindowIndex = $parts[10]
            TmuxWindow = $parts[11]
            TmuxLayout = $parts[12]
            TmuxPane = $parts[13]
            TmuxPaneIndex = $parts[14]
            TmuxPaneActive = $parts[15] -eq "1"
        }
    }
}

if ($Tmux) {
    $candidateProcesses = @($processes | Where-Object TmuxPane)
    $sessionGroups = @($candidateProcesses | Group-Object { "$($_.TmuxSession)`0$($_.TmuxWindowId)" })
} else {
    $tmuxTerminalSessions = @($processes | Where-Object { $_.TmuxPane -and $_.Session } | Select-Object -ExpandProperty Session -Unique)
    $candidateProcesses = @($processes | Where-Object {
        -not $_.TmuxPane -and $_.Session -notin $tmuxTerminalSessions
    })
    $sessionGroups = @(
        $candidateProcesses | Group-Object {
            if ($_.Workspace -and $_.TabId -match '^\d+$') {
                "managed`0$($_.Workspace)`0$($_.TabId)"
            } else {
                "native`0$($_.Session)"
            }
        }
    )
}

$sessions = @(
    foreach ($group in $sessionGroups) {
        $firstProcess = $group.Group[0]
        $isTmux = [bool]$firstProcess.TmuxPane
        if ($isTmux) {
            $paneGroups = @($group.Group | Group-Object TmuxPane | Sort-Object { [int]$_.Group[0].TmuxPaneIndex })
        } elseif ($firstProcess.Workspace -and $firstProcess.TabId -match '^\d+$') {
            $paneGroups = @($group.Group | Group-Object PaneIndex | Sort-Object { [int]$_.Name })
        } else {
            $paneGroups = @($group)
        }

        $panes = @(
            for ($paneIndex = 0; $paneIndex -lt $paneGroups.Count; $paneIndex++) {
                Get-Pane -Processes @($paneGroups[$paneIndex].Group) -Index $paneIndex
            }
        )
        $activePane = $panes | Where-Object Active | Select-Object -First 1
        if (-not $activePane) {
            $activePane = $panes[0]
        }

        $sourceProject = Get-SourceProject -WorkspaceName $firstProcess.Workspace -TabId $firstProcess.TabId
        $title = if ($isTmux) {
            [string]$firstProcess.TmuxWindow
        } elseif ($sourceProject -and $sourceProject.name) {
            [string]$sourceProject.name
        } else {
            Split-Path -Leaf $activePane.Directory
        }
        if ([string]::IsNullOrWhiteSpace($title)) {
            $title = $Distribution
        }

        $layout = if (-not $isTmux -and $sourceProject -and $sourceProject.layout -and @($sourceProject.panes).Count -eq $panes.Count) {
            $sourceProject.layout
        } else {
            New-SequentialLayout -PaneCount $panes.Count -ActivePane $activePane.Index -TmuxLayout ([string]$firstProcess.TmuxLayout)
        }

        [pscustomobject]@{
            Index = 0
            Title = $title
            Directory = $panes[0].Directory
            Mode = if ($isTmux) { "tmux" } elseif ($panes.Count -gt 1) { "native" } else { $panes[0].Mode }
            Panes = $panes.Count
            SessionName = ($panes | Where-Object SessionName | ForEach-Object SessionName) -join " | "
            TmuxSession = if ($isTmux) { [string]$firstProcess.TmuxSession } else { "" }
            WindowIndex = if ($isTmux) { [int]$firstProcess.TmuxWindowIndex } else { 0 }
            SessionId = if ($panes.Count -eq 1) { $panes[0].SessionId } else { "" }
            ExistingWorkspace = [string]$firstProcess.Workspace
            PanesData = $panes
            Layout = $layout
        }
    }
)

$sessions = @($sessions | Sort-Object TmuxSession,WindowIndex)

if ($sessions.Count -eq 0) {
    $kind = if ($Tmux) { "tmux windows" } else { "native Windows Terminal Ubuntu panes" }
    throw "No running $kind with WT_SESSION metadata were found."
}

for ($index = 0; $index -lt $sessions.Count; $index++) {
    $sessions[$index].Index = $index + 1
}

if ($All) {
    $selectedSessions = $sessions
} else {
    if ($Tmux) {
        if ($explicitName) {
            $targetName = ConvertTo-WorkspaceName -Value $Name -Mode 'tmux'
            Write-Host "保存目标：全部选中 window 将写入同一个 workspace [$targetName]；跨 tmux session 时还会要求确认。"
        } else {
            $automaticNames = @($sessions.TmuxSession | Select-Object -Unique | ForEach-Object {
                ConvertTo-WorkspaceName -Value $_ -Mode 'tmux'
            })
            Write-Host "保存目标：按 TmuxSession 分别写入 [$($automaticNames -join '], [')]；同名文件自动覆盖。"
        }
    } else {
        $targetName = if ($explicitName) { ConvertTo-WorkspaceName -Value $Name -Mode 'terminal' } else { 'TempTab' }
        $overwriteNote = if ($explicitName) { "同名文件存在时会要求确认" } else { "同名文件自动覆盖" }
        Write-Host "保存目标：写入 workspace [$targetName]，$overwriteNote；每个选中分组恢复为一个新 Tab。"
    }
    $menuItems = @(
        foreach ($session in $sessions) {
            $label = if ($Tmux) {
                "$(Format-WTworkColumn $session.TmuxSession 16)$(Format-WTworkColumn "window $($session.WindowIndex)" 16)$(Format-WTworkColumn $session.Title 16)$(Format-WTworkColumn "$($session.Panes) panes" 8)$($session.SessionName)"
            } else {
                "$(Format-WTworkColumn $session.Title 16)$(Format-WTworkColumn "$($session.Panes) panes" 8)$($session.SessionName)"
            }
            [pscustomobject]@{ Label = $label; Groupable = -not $Tmux -and $session.Panes -eq 1; SingleLine = $true }
        }
    )
    $selectionResult = Select-WTworkItems -Items $menuItems -Title "选择本次要保存的项目" -DefaultAll -AllowGrouping:(-not $Tmux) -KeyReader $SelectionKeyReader
    if ($selectionResult.Indexes.Count -eq 0) {
        Write-Host "没有选中项目：已取消保存，没有写入或覆盖 workspace。"
        exit 0
    }
    $emittedGroups = @{}
    $selectedSessions = @(
        foreach ($selectedIndex in $selectionResult.Indexes) {
            $groupId = $selectionResult.Groups[$selectedIndex]
            if ($groupId -and $emittedGroups[$groupId]) { continue }
            $chosen = if ($groupId) {
                $emittedGroups[$groupId] = $true
                @($selectionResult.Indexes | Where-Object { $selectionResult.Groups[$_] -eq $groupId } | ForEach-Object { $sessions[$_] })
            } else {
                @($sessions[$selectedIndex])
            }
            if ($chosen.Count -eq 1) { $chosen[0]; continue }
            $joinedPanes = @(
                for ($paneIndex = 0; $paneIndex -lt $chosen.Count; $paneIndex++) {
                    $pane = $chosen[$paneIndex].PanesData[0]
                    [pscustomobject]@{ Index = $paneIndex; Directory = $pane.Directory; Mode = $pane.Mode; SessionId = $pane.SessionId; SessionName = $pane.SessionName; Active = $paneIndex -eq 0 }
                }
            )
            [pscustomobject]@{
                Index = $chosen[0].Index; Title = $chosen[0].Title; Directory = $joinedPanes[0].Directory; Mode = "native"
                Panes = $joinedPanes.Count; SessionName = ($joinedPanes | Where-Object SessionName | ForEach-Object SessionName) -join " | "
                TmuxSession = ""; SessionId = ""; ExistingWorkspace = ""; PanesData = $joinedPanes
                Layout = New-SequentialLayout -PaneCount $joinedPanes.Count
            }
        }
    )
    Write-Host "已选择 $($selectionResult.Indexes.Count) 项，得到 $($selectedSessions.Count) 个保存分组；顺序遵循勾选顺序。"
}

if ($Tmux -and $explicitName -and -not $DryRun) {
    $sourceTmuxSessions = @($selectedSessions.TmuxSession | Select-Object -Unique)
    if ($sourceTmuxSessions.Count -gt 1) {
        $mergeTargetName = ConvertTo-WorkspaceName -Value $Name -Mode 'tmux'
        $confirmation = Read-Host "当前有多个 tmux sessions：[$($sourceTmuxSessions -join ', ')]，将合并保存为 [$mergeTargetName]。是否确认？(y/N，直接回车=取消)"
        if ($confirmation -notin @('y', 'Y', 'yes', 'YES')) {
            throw "已取消保存；没有写入或覆盖 workspace。"
        }
    }
}

function New-TmuxWorkspace {
    param([object[]]$WorkspaceSessions, [string]$WorkspaceName, [bool]$PrefixWindowNames)

    [ordered]@{
        schemaVersion = 2
        name = $WorkspaceName
        mode = "tmux"
        distribution = $Distribution
        profile = $Profile
        tmux = [ordered]@{
            windows = @(
                for ($windowIndex = 0; $windowIndex -lt $WorkspaceSessions.Count; $windowIndex++) {
                    $session = $WorkspaceSessions[$windowIndex]
                    [ordered]@{
                        index = $windowIndex
                        name = if ($PrefixWindowNames) { "$($session.TmuxSession)-$($session.Title)" } else { $session.Title }
                        layout = if ($session.Layout.tmux) { [string]$session.Layout.tmux } else { $null }
                        activePane = [int]$session.Layout.activePane
                        panes = @(
                            foreach ($pane in $session.PanesData) {
                                [ordered]@{
                                    index = $pane.Index
                                    directory = $pane.Directory
                                    session_type = $pane.Mode
                                    sessionId = if ($pane.Mode -eq "codex") { $pane.SessionId } else { $null }
                                    sessionName = if ($pane.Mode -eq "codex") { $pane.SessionName } else { $null }
                                }
                            }
                        )
                    }
                }
            )
        }
    }
}

$workspaces = if ($Tmux) {
    if ([string]::IsNullOrWhiteSpace($Name)) {
        @(
            foreach ($group in ($selectedSessions | Group-Object TmuxSession)) {
                New-TmuxWorkspace -WorkspaceSessions @($group.Group) -WorkspaceName $group.Name -PrefixWindowNames $false
            }
        )
    } else {
        $sourceTmuxSessions = @($selectedSessions.TmuxSession | Select-Object -Unique)
        @(New-TmuxWorkspace -WorkspaceSessions @($selectedSessions) -WorkspaceName $Name -PrefixWindowNames ($sourceTmuxSessions.Count -gt 1))
    }
} else {
    $workspaceName = if ([string]::IsNullOrWhiteSpace($Name)) { "TempTab" } else { $Name }
    @(
        [ordered]@{
            schemaVersion = 2
            name = $workspaceName
            mode = "terminal"
            distribution = $Distribution
            profile = $Profile
            terminal = [ordered]@{
                tabs = @(
                    for ($tabIndex = 0; $tabIndex -lt $selectedSessions.Count; $tabIndex++) {
                        $session = $selectedSessions[$tabIndex]
                        [ordered]@{
                            index = $tabIndex
                            name = $session.Title
                            layout = [ordered]@{
                                activePane = [int]$session.Layout.activePane
                                splits = @($session.Layout.splits)
                            }
                            panes = @(
                                foreach ($pane in $session.PanesData) {
                                    [ordered]@{
                                        index = $pane.Index
                                        directory = $pane.Directory
                                        session_type = $pane.Mode
                                        sessionId = if ($pane.Mode -eq "codex") { $pane.SessionId } else { $null }
                                        sessionName = if ($pane.Mode -eq "codex") { $pane.SessionName } else { $null }
                                    }
                                }
                            )
                        }
                    }
                )
            }
        }
    )
}

$workspaceNameRecords = @(
    foreach ($workspace in $workspaces) {
        $originalName = [string]$workspace.name
        $sanitizedName = ConvertTo-WorkspaceName -Value $originalName -Mode $workspace.mode
        $workspace.name = $sanitizedName
        [pscustomobject]@{ Original = $originalName; Sanitized = $sanitizedName }
    }
)
$nameChanges = @($workspaceNameRecords | Where-Object { $_.Original -cne $_.Sanitized })
$nameCollisions = @($workspaceNameRecords | Group-Object { $_.Sanitized.ToLowerInvariant() } | Where-Object Count -gt 1)
if ($nameCollisions.Count -gt 0) {
    $collisionNames = @(
        $nameCollisions | ForEach-Object {
            "$(@($_.Group.Original) -join ', ') -> $($_.Group[0].Sanitized)"
        }
    ) -join '; '
    throw "Workspace names collide after invalid characters are replaced: $collisionNames"
}

$json = if ($workspaces.Count -eq 1) {
    $workspaces[0] | ConvertTo-Json -Depth 10
} else {
    ConvertTo-Json -InputObject $workspaces -Depth 10
}
if ($DryRun) {
    $json
    exit 0
}

New-Item -ItemType Directory -Path $workspacesDirectory -Force | Out-Null
foreach ($workspace in $workspaces) {
    $workspacePath = Join-Path $workspacesDirectory "$($workspace.name).json"
    $workspaceExisted = Test-Path -LiteralPath $workspacePath
    if ($workspaceExisted -and -not $Force -and $explicitName) {
        $confirmation = Read-Host "已有 workspace name [$($workspace.name)]。是否覆盖？(y/N，直接回车=取消)"
        if ($confirmation -notin @('y', 'Y', 'yes', 'YES')) {
            throw "已取消保存；现有 workspace [$($workspace.name)] 未修改。"
        }
    }
    $workspaceJson = $workspace | ConvertTo-Json -Depth 10
    Set-Content -LiteralPath $workspacePath -Value $workspaceJson -Encoding utf8
    $nameChange = $nameChanges | Where-Object Sanitized -CEQ $workspace.name | Select-Object -First 1
    if ($nameChange) {
        Write-Host "Workspace name '$($nameChange.Original)' was saved as '$($nameChange.Sanitized)'."
    }
    $saveBranch = if ($workspaceExisted) { '覆盖' } else { '新建' }
    Write-Host ""
    Write-Host "操作结果：workspace [$($workspace.name)] 已走${saveBranch}分支，写入 $workspacePath"
}
