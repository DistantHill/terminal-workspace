$ErrorActionPreference = 'Stop'
$global:saveDetectionRows = @(
    "tmux-tab`t/home/reed/personal`t0`t`t`t`t`t`t`t`t`t`t`t`t"
    "shell-tab`t/home/reed/workspace`t0`t`t`t`t`t`t`t`t`t`t`t`t"
    "tmux-tab`t/project/a`t1`t`t`t`tthread-a`tConversation A`tmy-tmux`t@0`tconfig`tlayout-a`t%8`t1`t1"
    "tmux-tab`t/project/b`t1`t`t`t`tthread-b`tConversation B`tmy-tmux`t@0`tconfig`tlayout-a`t%10`t2`t0"
    "tmux-tab`t/project/c`t0`t`t`t`t`t`tmy-tmux`t@0`tconfig`tlayout-a`t%9`t3`t0"
)
function wsl.exe {
    $global:LASTEXITCODE = 0
    if ($args -contains 'wslpath') { '/scanner.sh' } else { $global:saveDetectionRows }
}
$save = Join-Path $PSScriptRoot '../Save-TerminalWorkspace.ps1'
foreach ($tmuxOnly in @($false, $true)) {
    $output = (& $save -Name regression -All -DryRun -Tmux:$tmuxOnly | Out-String)
    $workspace = $output.Substring($output.IndexOf('{')) | ConvertFrom-Json
    $layout = @($workspace.projects | Where-Object mode -eq 'layout')
    if ($layout.Count -ne 1 -or $layout[0].panes.Count -ne 3) {
        throw 'Expected the three-pane tmux window in save output.'
    }
    if ($layout[0].panes[0].sessionId -ne 'thread-a' -or $layout[0].panes[1].sessionId -ne 'thread-b' -or $layout[0].layout.tmux -ne 'layout-a') {
        throw 'Lost Codex sessions or tmux layout.'
    }
    $expectedCount = if ($tmuxOnly) { 1 } else { 2 }
    if ($workspace.projects.Count -ne $expectedCount -or $output -notmatch 'tmux\s+3') {
        throw 'Incorrect mode or duplicate outer shell.'
    }
    if (-not $tmuxOnly -and @($workspace.projects | Where-Object directory -eq '/home/reed/workspace').Count -ne 1) {
        throw 'Lost the independent shell tab.'
    }
}
Write-Host 'Save detection regression tests passed.'

