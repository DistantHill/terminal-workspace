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
        & (Join-Path $PSScriptRoot "Save-TerminalWorkspace.ps1") -Name $Name -Tmux:$Tmux -Force:$Force -DryRun:$DryRun -SelectionKeyReader $SelectionKeyReader
        exit $LASTEXITCODE
    }
    "list" {
        if (-not (Test-Path -LiteralPath $workspacesDirectory -PathType Container)) {
            Write-Host "还没有保存的 workspace。"
            exit 0
        }

        $items = @(
            foreach ($file in (Get-ChildItem -LiteralPath $workspacesDirectory -Filter "*.json" -File | Sort-Object Name)) {
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
        )
        if ($items.Count -eq 0) {
            Write-Host "还没有保存的 workspace。"
            exit 0
        }
        $workspaceMenuItems = @($items | ForEach-Object {
            [pscustomobject]@{ Label = "$(Format-WTworkColumn $_.Name 16)$(Format-WTworkColumn $_.Mode 8)$(Format-WTworkColumn "$($_.Tabs) tabs" 8)$($_.Path)"; Groupable = $false }
        })
        $workspaceSelection = Select-WTworkItems -Items $workspaceMenuItems -Title "选择 workspace" -KeyReader $SelectionKeyReader
        if ($workspaceSelection.Indexes.Count -eq 0) {
            Write-Host "没有选中 workspace：已取消操作。"
            exit 0
        }
        $selectedItems = @($workspaceSelection.Indexes | ForEach-Object { $items[$_] })
        $actions = @('打开', '删除')
        if ($selectedItems.Count -eq 1) { $actions += '改名' }
        $actionItems = @($actions | ForEach-Object { [pscustomobject]@{ Label = $_; Groupable = $false } })
        $actionSelection = Select-WTworkItems -Items $actionItems -Title "对 [$($selectedItems.Name -join '], [')] 执行操作" -Single -KeyReader $SelectionKeyReader
        if ($actionSelection.Indexes.Count -eq 0) {
            Write-Host "没有选择操作：已取消。"
            exit 0
        }
        $selectedAction = $actions[$actionSelection.Indexes[0]]
        if ($selectedAction -eq '打开') {
            $sharedWindowTarget = "WTwork-list-$PID"
            if ($DryRun) {
                $plans = @(
                    foreach ($item in $selectedItems) {
                        $workspace = Get-Content -LiteralPath $item.Path -Raw | ConvertFrom-Json
                        $openWithTmux = [int]$workspace.schemaVersion -eq 2 -and [string]$workspace.mode -eq 'tmux'
                        & (Join-Path $PSScriptRoot "Open-TerminalWorkspace.ps1") -Config $item.Path -Tmux:$openWithTmux -WindowTarget $sharedWindowTarget -DryRun | ConvertFrom-Json
                    }
                )
                ConvertTo-Json -InputObject $plans -Depth 10
            } else {
                foreach ($item in $selectedItems) {
                    $workspace = Get-Content -LiteralPath $item.Path -Raw | ConvertFrom-Json
                    $openWithTmux = [int]$workspace.schemaVersion -eq 2 -and [string]$workspace.mode -eq 'tmux'
                    & (Join-Path $PSScriptRoot "Open-TerminalWorkspace.ps1") -Config $item.Path -Tmux:$openWithTmux -WindowTarget $sharedWindowTarget
                }
            }
            exit $LASTEXITCODE
        }
        if ($selectedAction -eq '删除') {
            $confirmationItems = @(
                [pscustomobject]@{ Label = "确认永久删除 [$($selectedItems.Name -join '], [')]"; Groupable = $false }
                [pscustomobject]@{ Label = '取消'; Groupable = $false }
            )
            $confirmation = Select-WTworkItems -Items $confirmationItems -Title "删除后无法由 WTwork 恢复" -Single -KeyReader $SelectionKeyReader
            if ($confirmation.Indexes.Count -eq 0 -or $confirmation.Indexes[0] -ne 0) {
                Write-Host "已取消删除；workspace 文件未修改。"
                exit 0
            }
            foreach ($item in $selectedItems) { Remove-Item -LiteralPath $item.Path }
            Write-Host "已删除 workspace：[$($selectedItems.Name -join '], [')]。"
            exit 0
        }

        $newName = Read-Host "输入新的 workspace name"
        if ([string]::IsNullOrWhiteSpace($newName)) {
            Write-Host "未输入新名称：已取消改名。"
            exit 0
        }
        $workspace = Get-Content -LiteralPath $selectedItems[0].Path -Raw | ConvertFrom-Json
        $invalidCharacters = [IO.Path]::GetInvalidFileNameChars()
        $sanitizedName = -join @(
            for ($index = 0; $index -lt $newName.Length; $index++) {
                $character = $newName[$index]
                if (
                    $character -in $invalidCharacters -or
                    ([string]$workspace.mode -eq 'tmux' -and $character -eq '.') -or
                    ($index -eq $newName.Length - 1 -and $character -in @('.', ' '))
                ) { '_' } else { $character }
            }
        )
        $renamedPath = Join-Path $workspacesDirectory "$sanitizedName.json"
        if ($renamedPath -ine $selectedItems[0].Path -and (Test-Path -LiteralPath $renamedPath)) {
            throw "Workspace '$sanitizedName' already exists."
        }
        $workspace.name = $sanitizedName
        $workspace | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $renamedPath -Encoding utf8
        if ($renamedPath -ine $selectedItems[0].Path) { Remove-Item -LiteralPath $selectedItems[0].Path }
        if ($newName -cne $sanitizedName) { Write-Host "Workspace name '$newName' was renamed as '$sanitizedName'." }
        Write-Host "已将 workspace [$($selectedItems[0].Name)] 改名为 [$sanitizedName]。"
        exit 0
    }
    "open" {
        if ([string]::IsNullOrWhiteSpace($Name)) {
            if ($Tmux) {
                if (-not (Test-Path -LiteralPath $workspacesDirectory -PathType Container)) {
                    throw "No saved tmux workspaces were found."
                }
                $tmuxWorkspaces = @(
                    foreach ($file in (Get-ChildItem -LiteralPath $workspacesDirectory -Filter "*.json" -File | Sort-Object Name)) {
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
                Write-Host "打开方式：可勾选多个 workspace；将按勾选顺序在同一个新 Windows Terminal window 中打开，每个 workspace 一个 Tab。"
                $menuItems = @($tmuxWorkspaces | ForEach-Object {
                    [pscustomobject]@{ Label = "$(Format-WTworkColumn $_.Name 16)$($_.Windows) windows"; Groupable = $false }
                })
                $selectionResult = Select-WTworkItems -Items $menuItems -Title "选择本次要打开的 tmux workspace" -KeyReader $SelectionKeyReader
                if ($selectionResult.Indexes.Count -eq 0) {
                    Write-Host "没有选中 workspace：已取消打开，没有启动任何 workspace。"
                    exit 0
                }
                $selectedWorkspaces = @($selectionResult.Indexes | ForEach-Object { $tmuxWorkspaces[$_] })
                Write-Host "将打开：[$($selectedWorkspaces.Name -join '], [')]。"
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
            Write-Host "未指定 workspace：正在打开默认 workspace [TempTab]。"
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
        $rendererDescription = if ($openWithTmux) { "tmux；同名 session 已存在则附着，否则重建" } else { "Windows Terminal；每个已保存分组重建为新 Tab" }
        Write-Host "正在打开 workspace [$Name]，模式：$rendererDescription。"
        & (Join-Path $PSScriptRoot "Open-TerminalWorkspace.ps1") -Config $workspacePath -Tmux:$openWithTmux -DryRun:$DryRun
        exit $LASTEXITCODE
    }
}
