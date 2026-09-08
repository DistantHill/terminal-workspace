[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Name,
    [string]$Distribution = "Ubuntu-22.04",
    [string]$Profile = "Ubuntu-22.04",
    [switch]$Tmux,
    [switch]$All,
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

if (
    [string]::IsNullOrWhiteSpace($Name) -or
    $Name -in @(".", "..") -or
    $Name -ne [IO.Path]::GetFileName($Name) -or
    $Name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0
) {
    throw "Workspace name is not a valid Windows file name."
}

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw "wsl.exe was not found on PATH."
}

function Get-Pane {
    param([object[]]$Processes, [int]$Index)

    $codexProcesses = @($Processes | Where-Object IsCodex)
    $selectedProcess = $codexProcesses | Where-Object SessionId | Select-Object -First 1
    if (-not $selectedProcess) {
        $selectedProcess = if ($codexProcesses.Count -gt 0) {
            $codexProcesses[0]
        } else {
            $Processes[0]
        }
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
                [ordered]@{
                    direction = "right"
                    size = 0.5
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
    $sourceProjects = @($sourceWorkspace.projects)
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
    $parts = $line -split "`t", 15
    if ($parts.Count -eq 15) {
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
            TmuxWindow = $parts[10]
            TmuxLayout = $parts[11]
            TmuxPane = $parts[12]
            TmuxPaneIndex = $parts[13]
            TmuxPaneActive = $parts[14] -eq "1"
        }
    }
}

if ($Tmux) {
    $candidateProcesses = @($processes | Where-Object TmuxPane)
    $sessionGroups = @($candidateProcesses | Group-Object { "$($_.TmuxSession)`0$($_.TmuxWindowId)" })
} else {
    $candidateProcesses = @($processes | Where-Object { -not $_.TmuxPane })
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
        if ($Tmux) {
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
        $title = if ($Tmux) {
            [string]$firstProcess.TmuxWindow
        } elseif ($sourceProject -and $sourceProject.name) {
            [string]$sourceProject.name
        } else {
            Split-Path -Leaf $activePane.Directory
        }
        if ([string]::IsNullOrWhiteSpace($title)) {
            $title = $Distribution
        }

        $layout = if ($sourceProject -and $sourceProject.layout -and @($sourceProject.panes).Count -eq $panes.Count) {
            $sourceProject.layout
        } else {
            New-SequentialLayout -PaneCount $panes.Count -ActivePane $activePane.Index -TmuxLayout ([string]$firstProcess.TmuxLayout)
        }

        [pscustomobject]@{
            Index = 0
            Title = $title
            Directory = $panes[0].Directory
            Mode = if ($Tmux) { "tmux" } elseif ($panes.Count -gt 1) { "native" } else { $panes[0].Mode }
            Panes = $panes.Count
            SessionName = ($panes | Where-Object SessionName | ForEach-Object SessionName) -join " | "
            SessionId = if ($panes.Count -eq 1) { $panes[0].SessionId } else { "" }
            ExistingWorkspace = [string]$firstProcess.Workspace
            PanesData = $panes
            Layout = $layout
        }
    }
)

if ($sessions.Count -eq 0) {
    $kind = if ($Tmux) { "tmux windows" } else { "native Windows Terminal Ubuntu panes" }
    throw "No running $kind with WT_SESSION metadata were found."
}

for ($index = 0; $index -lt $sessions.Count; $index++) {
    $sessions[$index].Index = $index + 1
}

$titleCounts = @{}
foreach ($session in $sessions) {
    $baseTitle = $session.Title
    $titleCounts[$baseTitle] = 1 + [int]$titleCounts[$baseTitle]
    if ($titleCounts[$baseTitle] -gt 1) {
        $session.Title = "$baseTitle-$($titleCounts[$baseTitle])"
    }
}

$sessions | Format-Table Index,Title,Mode,Panes,SessionName,SessionId,Directory,ExistingWorkspace -AutoSize

if ($All) {
    $selectedSessions = $sessions
} else {
    $prompt = if ($Tmux) {
        "选择 tmux window 编号（逗号分隔；直接回车选择全部）"
    } else {
        "选择 Ubuntu Tab/Pane 编号（逗号分隔；同一原生 Tab 用 + 连接；直接回车选择全部）"
    }
    $selection = Read-Host $prompt
    if ([string]::IsNullOrWhiteSpace($selection)) {
        $selectedSessions = $sessions
    } else {
        $selectedSessions = @(
            foreach ($selectionGroup in ($selection -split ',')) {
                $indexes = @($selectionGroup -split '\+' | ForEach-Object { [int]$_.Trim() })
                if ($indexes | Where-Object { $_ -lt 1 -or $_ -gt $sessions.Count }) {
                    throw "One or more selected numbers are invalid."
                }
                if ($Tmux -and $indexes.Count -gt 1) {
                    throw "tmux windows are already grouped; do not join them with '+'."
                }
                $chosen = @($indexes | ForEach-Object { $sessions[$_ - 1] })
                if ($chosen.Count -eq 1) {
                    $chosen[0]
                    continue
                }
                if ($chosen | Where-Object { $_.Panes -ne 1 }) {
                    throw "Only ungrouped single panes can be joined with '+'."
                }
                $joinedPanes = @(
                    for ($paneIndex = 0; $paneIndex -lt $chosen.Count; $paneIndex++) {
                        $pane = $chosen[$paneIndex].PanesData[0]
                        [pscustomobject]@{
                            Index = $paneIndex
                            Directory = $pane.Directory
                            Mode = $pane.Mode
                            SessionId = $pane.SessionId
                            SessionName = $pane.SessionName
                            Active = $paneIndex -eq 0
                        }
                    }
                )
                [pscustomobject]@{
                    Index = $chosen[0].Index
                    Title = $chosen[0].Title
                    Directory = $joinedPanes[0].Directory
                    Mode = "native"
                    Panes = $joinedPanes.Count
                    SessionName = ($joinedPanes | Where-Object SessionName | ForEach-Object SessionName) -join " | "
                    SessionId = ""
                    ExistingWorkspace = ""
                    PanesData = $joinedPanes
                    Layout = New-SequentialLayout -PaneCount $joinedPanes.Count
                }
            }
        )
    }
}

$unresolved = @(
    foreach ($session in $selectedSessions) {
        foreach ($pane in ($session.PanesData | Where-Object { $_.Mode -eq "codex" -and [string]::IsNullOrWhiteSpace($_.SessionId) })) {
            "Tab $($session.Index) Pane $($pane.Index)"
        }
    }
)
if ($unresolved.Count -gt 0) {
    throw "Codex $($unresolved -join ', ') has no active resumable Session. Open a conversation there, then save again."
}

$projects = @(
    foreach ($session in $selectedSessions) {
        if ($session.PanesData.Count -gt 1) {
            [ordered]@{
                name = $session.Title
                directory = $session.Directory
                mode = "layout"
                sessionId = $null
                sessionName = $null
                layout = $session.Layout
                panes = @(
                    foreach ($pane in $session.PanesData) {
                        [ordered]@{
                            index = $pane.Index
                            directory = $pane.Directory
                            mode = $pane.Mode
                            sessionId = if ($pane.Mode -eq "codex") { $pane.SessionId } else { $null }
                            sessionName = if ($pane.Mode -eq "codex") { $pane.SessionName } else { $null }
                        }
                    }
                )
            }
        } else {
            $pane = $session.PanesData[0]
            [ordered]@{
                name = $session.Title
                directory = $pane.Directory
                mode = $pane.Mode
                sessionId = if ($pane.Mode -eq "codex") { $pane.SessionId } else { $null }
                sessionName = if ($pane.Mode -eq "codex") { $pane.SessionName } else { $null }
            }
        }
    }
)

$workspace = [ordered]@{
    name = $Name
    distribution = $Distribution
    profile = $Profile
    projects = $projects
}

$json = $workspace | ConvertTo-Json -Depth 10
if ($DryRun) {
    $json
    exit 0
}

New-Item -ItemType Directory -Path $workspacesDirectory -Force | Out-Null
$workspacePath = Join-Path $workspacesDirectory "$Name.json"
if ((Test-Path -LiteralPath $workspacePath) -and -not $Force) {
    throw "Workspace '$Name' already exists. Use -Force to replace it."
}

Set-Content -LiteralPath $workspacePath -Value $json -Encoding utf8
Write-Host "Saved workspace '$Name' to $workspacePath"
