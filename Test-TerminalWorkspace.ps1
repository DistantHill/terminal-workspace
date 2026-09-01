$ErrorActionPreference = "Stop"

$launcher = Join-Path $PSScriptRoot "Open-TerminalWorkspace.ps1"
$codexConfig = Join-Path $PSScriptRoot "workspace.example.json"
$shellConfig = Join-Path $PSScriptRoot "tests\shell-workspace.json"
$legacyTmuxConfig = Join-Path $PSScriptRoot "tests\tmux-workspace.json"
$map1Config = Join-Path $PSScriptRoot "workspaces\地图1.json"
$installer = Join-Path $PSScriptRoot "Install-WTwork.ps1"

$installPlan = & $installer -DryRun | ConvertFrom-Json
if (
    $installPlan.command -ne "WTwork" -or
    -not $installPlan.launcher.EndsWith("WTwork\bin\WTwork.cmd") -or
    -not $installPlan.entryScript.EndsWith("WTwork\TerminalWorkspace.ps1") -or
    $installPlan.runtimeFiles -notcontains "TerminalWorkspace.ps1" -or
    $installPlan.runtimeFiles -notcontains "Restore-TmuxTab.py"
) {
    throw "WTwork installation plan is invalid."
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

$map1NativePlan = & $launcher -Config $map1Config -DryRun | ConvertFrom-Json
$splitIndexes = @(
    for ($index = 0; $index -lt $map1NativePlan.arguments.Count; $index++) {
        if ($map1NativePlan.arguments[$index] -eq "split-pane") { $index }
    }
)
if ($map1NativePlan.renderer -ne "windows-terminal" -or $splitIndexes.Count -ne 2) {
    throw "地图1 must default to one native Windows Terminal tab with three panes."
}
foreach ($splitIndex in $splitIndexes) {
    if (
        $map1NativePlan.arguments[$splitIndex + 1] -ne "-V" -or
        $map1NativePlan.arguments[$splitIndex + 2] -ne "--size" -or
        $map1NativePlan.arguments[$splitIndex + 3] -ne "0.5"
    ) {
        throw "地图1 must use two recursive 50% right splits."
    }
}
foreach ($paneIndex in 0..2) {
    if ($map1NativePlan.arguments -notcontains "TERMINAL_WORKSPACE_PANE_INDEX=$paneIndex") {
        throw "地图1 native pane $paneIndex is missing its persistent marker."
    }
}

$map1TmuxPlan = & $launcher -Config $map1Config -Tmux -DryRun | ConvertFrom-Json
$map1PythonIndex = [Array]::IndexOf($map1TmuxPlan.arguments, "python3")
$map1Payload = [Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String($map1TmuxPlan.arguments[$map1PythonIndex + 2])
) | ConvertFrom-Json
if (
    $map1TmuxPlan.renderer -ne "tmux" -or
    $map1Payload.workspaceName -ne "地图1" -or
    $map1Payload.tabs.Count -ne 1 -or
    $map1Payload.tabs[0].panes.Count -ne 3
) {
    throw "地图1 --tmux must map to session 地图1, one window, and three panes."
}

Write-Host "Terminal Workspace tests passed."
