$ErrorActionPreference = 'Stop'
$global:saveDetectionRows = @(
    "tmux-tab`t/home/reed/personal`t0`t`t`t`t`t`t`t`t`t`t`t`t`t`t"
    "shell-tab`t/home/reed/workspace`t0`t`t`t`t`t`t`t`t`t`t`t`t`t`t"
    "tmux-tab`t/project/a`t1`t`t`t`tthread-a`tConversation A`tmy-tmux`t@0`t2`tconfig`tlayout-a`t%8`t1`t1"
    "tmux-tab`t/project/b`t1`t`t`t`tthread-b`tConversation B`tmy-tmux`t@0`t2`tconfig`tlayout-a`t%10`t2`t0"
    "tmux-tab`t/project/c`t0`t`t`t`t`t`tmy-tmux`t@0`t2`tconfig`tlayout-a`t%9`t3`t0"
    "other-tab`t/project/z`t1`t`t`t`tthread-z`tConversation Z`talpha-tmux`t@1`t1`tconfig`tlayout-z`t%11`t1`t1"
    "tmux-tab`t/project/d`t1`t`t`t`tthread-d`tConversation D`tmy-tmux`t@3`t0`tsecond`tlayout-d`t%13`t1`t1"
)
function wsl.exe {
    $global:LASTEXITCODE = 0
    if ($args -contains 'wslpath') { '/scanner.sh' } else { $global:saveDetectionRows }
}
$save = Join-Path $PSScriptRoot '../Save-TerminalWorkspace.ps1'
foreach ($tmuxOnly in @($false, $true)) {
    $output = (& $save -Name regression -All -DryRun -Tmux:$tmuxOnly | Out-String)
    $workspace = $output.Substring($output.IndexOf('{')) | ConvertFrom-Json
    $table = $output.Substring(0, $output.IndexOf('{'))
    if ($tmuxOnly) {
        $windows = @($workspace.tmux.windows)
        if (
            $workspace.mode -ne 'tmux' -or
            $windows.Count -ne 3 -or
            $windows[2].panes.Count -ne 3 -or
            $windows[2].panes[0].sessionId -ne 'thread-a' -or
            $windows[2].layout -ne 'layout-a' -or
            $table -notmatch 'TmuxSession\s+WindowIndex\s+Title\s+Mode\s+Panes\s+SessionName'
        ) {
            throw 'Expected distinct tmux windows, panes, session names, and layouts.'
        }
    } elseif (
        $workspace.mode -ne 'terminal' -or
        $workspace.terminal.tabs.Count -ne 1 -or
        $workspace.terminal.tabs[0].panes[0].directory -ne '/home/reed/workspace'
    ) {
        throw 'Native save must exclude the outer tmux terminal and preserve the independent shell tab.'
    }
}
Write-Host 'Save detection regression tests passed.'

