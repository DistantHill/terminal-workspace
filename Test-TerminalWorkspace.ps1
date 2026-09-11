$ErrorActionPreference = "Stop"

& (Join-Path $PSScriptRoot "tests/Test-V2Save.ps1")
& (Join-Path $PSScriptRoot "tests/Test-Cli.ps1")
& (Join-Path $PSScriptRoot "tests/Test-SaveDetection.ps1")

$launcher = Join-Path $PSScriptRoot "Open-TerminalWorkspace.ps1"
$codexConfig = Join-Path $PSScriptRoot "workspace.example.json"
$shellConfig = Join-Path $PSScriptRoot "tests\shell-workspace.json"
$legacyTmuxConfig = Join-Path $PSScriptRoot "tests\tmux-workspace.json"
$v2TmuxConfig = Join-Path $PSScriptRoot "tests\tmux-v2-workspace.json"
$v2TerminalConfig = Join-Path $PSScriptRoot "tests\terminal-v2-workspace.json"
$tmuxThreeWindowConfig = Join-Path $PSScriptRoot "tests\tmux-three-window-workspace.json"
$installer = Join-Path $PSScriptRoot "Install-WTwork.ps1"
$bootstrap = Join-Path $PSScriptRoot "install.ps1"
$packageConfig = Join-Path $PSScriptRoot "package.json"

$installPlan = & $installer -DryRun | ConvertFrom-Json
if (
    $installPlan.command -ne "WTwork" -or
    -not $installPlan.launcher.EndsWith("WTwork\bin\WTwork.cmd") -or
    -not $installPlan.entryScript.EndsWith("WTwork\TerminalWorkspace.ps1") -or
    -not $installPlan.workspaceDirectory.EndsWith("WTwork\workspaces") -or
    $installPlan.runtimeFiles -notcontains "TerminalWorkspace.ps1" -or
    $installPlan.runtimeFiles -notcontains "Interactive-Selection.ps1" -or
    $installPlan.runtimeFiles -notcontains "Restore-TmuxTab.py"
) {
    throw "WTwork installation plan is invalid."
}

$bootstrapPlan = & $bootstrap -DryRun | ConvertFrom-Json
if (
    $bootstrapPlan.archiveUrl -ne "https://github.com/DistanceHill/SaveTerminalWorkSpace/releases/latest/download/WTwork.zip" -or
    $bootstrapPlan.checksumUrl -ne "https://github.com/DistanceHill/SaveTerminalWorkSpace/releases/latest/download/WTwork.zip.sha256" -or
    $bootstrapPlan.command -ne "WTwork"
) {
    throw "WTwork remote bootstrap plan is invalid."
}

$package = Get-Content -LiteralPath $packageConfig -Raw | ConvertFrom-Json
if (
    $package.name -ne "wtwork" -or
    $package.version -ne "0.1.0" -or
    $package.bin.WTwork -ne "bin/wtwork.js" -or
    $package.files -notcontains "TerminalWorkspace.ps1"
) {
    throw "WTwork npm package metadata is invalid."
}

$terminalWorkspaceSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot "TerminalWorkspace.ps1") -Raw
$saveWorkspaceSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot "Save-TerminalWorkspace.ps1") -Raw
if ($terminalWorkspaceSource -notmatch 'WTWORK_DATA_HOME' -or $saveWorkspaceSource -notmatch 'WTWORK_DATA_HOME') {
    throw "Workspace data must resolve outside the installed package directory."
}

$codexPlan = & $launcher -Config $codexConfig -DryRun | ConvertFrom-Json
$codexCommands = @($codexPlan.arguments | Where-Object { $_ -like "exec codex resume *" })
$workspaceMarkers = @($codexPlan.arguments | Where-Object { $_ -eq "TERMINAL_WORKSPACE_NAME=地图项目" })
$tabMarkers = @($codexPlan.arguments | Where-Object { $_ -like "TERMINAL_WORKSPACE_TAB_ID=*" })
$paneMarkers = @($codexPlan.arguments | Where-Object { $_ -eq "TERMINAL_WORKSPACE_PANE_INDEX=0" })
$sessionNameMarkers = @($codexPlan.arguments | Where-Object { $_ -like "TERMINAL_CODEX_SESSION_NAME=*" })

if ($codexPlan.renderer -ne "windows-terminal" -or $codexPlan.arguments[1] -ne "地图项目") {
    throw "Windows Terminal must be the default renderer."
}
if ($codexCommands.Count -ne 2 -or $workspaceMarkers.Count -ne 2 -or $tabMarkers.Count -ne 2 -or $paneMarkers.Count -ne 2) {
    throw "Codex workspace plan is missing tabs, panes, or workspace markers."
}
if (
    $codexCommands -contains "exec codex resume --last" -or
    $codexCommands -notcontains "exec codex resume 11111111-1111-4111-8111-111111111111" -or
    $codexCommands -notcontains "exec codex resume 22222222-2222-4222-8222-222222222222"
) {
    throw "Codex tabs were not bound to their exact session IDs."
}
if ($sessionNameMarkers.Count -ne 0) {
    throw "Shell-sensitive session names must not be passed through wsl.exe."
}

$shellPlan = & $launcher -Config $shellConfig -DryRun | ConvertFrom-Json
if (@($shellPlan.arguments | Where-Object { $_ -eq "zsh" }).Count -ne 1) {
    throw "Shell workspace plan was not generated."
}

$legacyTmuxPlan = & $launcher -Config $legacyTmuxConfig -Tmux -DryRun | ConvertFrom-Json
$legacyPythonIndex = [Array]::IndexOf($legacyTmuxPlan.arguments, "python3")
if ($legacyTmuxPlan.renderer -ne "tmux" -or $legacyPythonIndex -lt 0) {
    throw "--tmux did not invoke the tmux workspace helper."
}
$legacyPayload = [Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String($legacyTmuxPlan.arguments[$legacyPythonIndex + 2])
) | ConvertFrom-Json
if (
    $legacyPayload.workspaceName -ne "地图分屏" -or
    $legacyPayload.tabs.Count -ne 1 -or
    $legacyPayload.tabs[0].layout.tmux -ne "2919,129x31,0,0{64x31,0,0,1,64x31,65,0,2}" -or
    $legacyPayload.tabs[0].panes.Count -ne 2
) {
    throw "Legacy tmux layout compatibility was not preserved."
}

$v2TmuxPlan = & $launcher -Config $v2TmuxConfig -DryRun | ConvertFrom-Json
$v2TmuxPythonIndex = [Array]::IndexOf($v2TmuxPlan.arguments, "python3")
$v2TmuxPayload = [Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String($v2TmuxPlan.arguments[$v2TmuxPythonIndex + 2])
) | ConvertFrom-Json
if (
    $v2TmuxPlan.renderer -ne "tmux" -or
    $v2TmuxPayload.workspaceName -ne "tmux-v2-test" -or
    $v2TmuxPayload.tabs[0].name -ne "mixed" -or
    $v2TmuxPayload.tabs[0].layout.activePane -ne 1 -or
    $v2TmuxPayload.tabs[0].layout.tmux -ne "2919,129x31,0,0{64x31,0,0,1,64x31,65,0,2}" -or
    $v2TmuxPayload.tabs[0].panes[0].mode -ne "codex" -or
    $v2TmuxPayload.tabs[0].panes[1].mode -ne "shell"
) {
    throw "V2 tmux mode must select the renderer and normalize its windows."
}

$v2TerminalPlan = & $launcher -Config $v2TerminalConfig -DryRun | ConvertFrom-Json
$v2TerminalSplits = @($v2TerminalPlan.arguments | Where-Object { $_ -eq "split-pane" })
$v2TerminalSizes = for ($index = 0; $index -lt $v2TerminalPlan.arguments.Count; $index++) {
    if ($v2TerminalPlan.arguments[$index] -eq "--size") { $v2TerminalPlan.arguments[$index + 1] }
}
if (
    $v2TerminalPlan.renderer -ne "windows-terminal" -or
    $v2TerminalSplits.Count -ne 2 -or
    $v2TerminalSizes[0] -ne "0.66666667" -or
    $v2TerminalSizes[1] -ne "0.5" -or
    $v2TerminalPlan.arguments -notcontains "exec codex resume thread-a" -or
    $v2TerminalPlan.arguments -notcontains "exec codex" -or
    @($v2TerminalPlan.arguments | Where-Object { $_ -eq "zsh" }).Count -ne 3
) {
    throw "V2 terminal mode must preserve its tab panes and session types."
}

$tmuxThreeWindowPlan = & $launcher -Config $tmuxThreeWindowConfig -Tmux -DryRun | ConvertFrom-Json
$tmuxThreeWindowPythonIndex = [Array]::IndexOf($tmuxThreeWindowPlan.arguments, "python3")
$tmuxThreeWindowPayload = [Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String($tmuxThreeWindowPlan.arguments[$tmuxThreeWindowPythonIndex + 2])
) | ConvertFrom-Json
$sixPaneTmuxLayout = "c7a6,120x40,0,0{59x40,0,0[59x19,0,0,0,59x20,0,20,3],29x40,60,0[29x19,60,0,1,29x20,60,20,4],30x40,90,0[30x19,90,0,2,30x20,90,20,5]}"
if (
    $tmuxThreeWindowPlan.renderer -ne "tmux" -or
    $tmuxThreeWindowPayload.workspaceName -ne "tmux-three-window-test" -or
    $tmuxThreeWindowPayload.tabs.Count -ne 3 -or
    $tmuxThreeWindowPayload.tabs[0].name -ne "six-pane-layout" -or
    $tmuxThreeWindowPayload.tabs[0].panes.Count -ne 6 -or
    $tmuxThreeWindowPayload.tabs[0].layout.splits.Count -ne 5 -or
    $tmuxThreeWindowPayload.tabs[0].layout.tmux -ne $sixPaneTmuxLayout -or
    $tmuxThreeWindowPayload.tabs[1].name -ne "shell-only" -or
    $tmuxThreeWindowPayload.tabs[1].panes.Count -ne 1 -or
    $tmuxThreeWindowPayload.tabs[1].panes[0].mode -ne "shell" -or
    $tmuxThreeWindowPayload.tabs[1].panes[0].directory -ne "/home/test-user" -or
    $tmuxThreeWindowPayload.tabs[2].name -ne "codex-new" -or
    $tmuxThreeWindowPayload.tabs[2].panes.Count -ne 1 -or
    $tmuxThreeWindowPayload.tabs[2].panes[0].mode -ne "codex" -or
    $tmuxThreeWindowPayload.tabs[2].panes[0].directory -ne "/home/test-user" -or
    -not [string]::IsNullOrWhiteSpace($tmuxThreeWindowPayload.tabs[2].panes[0].sessionId)
) {
    throw "The tmux workspace must map to three windows with 6, 1, and 1 panes."
}
$sixPanes = $tmuxThreeWindowPayload.tabs[0].panes
if (
    $sixPanes[0].mode -ne "codex" -or $sixPanes[0].sessionId -ne "last" -or $sixPanes[0].directory -ne "/home/test-user" -or
    $sixPanes[3].mode -ne "codex" -or $sixPanes[3].sessionId -ne "last" -or $sixPanes[3].directory -ne "/home/test-user/workspace" -or
    $sixPanes[1].mode -ne "codex" -or -not [string]::IsNullOrWhiteSpace($sixPanes[1].sessionId) -or
    $sixPanes[4].sessionId -ne "01a08f61-8199-7691-85d6-d3eb663c02c9" -or
    $sixPanes[2].mode -ne "shell" -or $sixPanes[2].directory -ne "/home/test-user" -or
    $sixPanes[5].mode -ne "shell" -or $sixPanes[5].directory -ne "/home/test-user/workspace"
) {
    throw "The six-pane tmux window does not preserve its commands, sessions, or directories."
}

Write-Host "Terminal Workspace tests passed."
