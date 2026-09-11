$ErrorActionPreference = 'Stop'
function New-TestKeyReader {
    param([string[]]$Keys)
    $queue = [Collections.Generic.Queue[string]]::new()
    foreach ($key in $Keys) { $queue.Enqueue($key) }
    { $queue.Dequeue() }.GetNewClosure()
}
. (Join-Path $PSScriptRoot '../Interactive-Selection.ps1')
$longSessionName = '会话' * 100
$wrappedSessionName = ConvertTo-WTworkDisplayLines -Text $longSessionName -MaximumWidth 40
if ($wrappedSessionName.Count -lt 2 -or ($wrappedSessionName -join '') -ne $longSessionName) {
    throw 'Interactive rows must wrap long session names without truncating them.'
}
$groupingItems = 1..4 | ForEach-Object { [pscustomobject]@{ Label = "Pane $_"; Groupable = $true } }
$groupingKeys = @(
    'DownArrow', 'DownArrow', 'Spacebar', 'DownArrow', 'Spacebar', 'G',
    'DownArrow', 'Spacebar', 'DownArrow', 'Spacebar',
    'DownArrow', 'Spacebar', 'DownArrow', 'Spacebar', 'G',
    'DownArrow', 'Spacebar', 'DownArrow', 'Spacebar', 'Enter'
)
$groupingResult = Select-WTworkItems -Items $groupingItems -Title 'test' -DefaultAll -AllowGrouping -KeyReader (New-TestKeyReader $groupingKeys)
if (
    $groupingResult.Groups[0] -ne $groupingResult.Groups[1] -or
    $groupingResult.Groups[2] -ne $groupingResult.Groups[3] -or
    $groupingResult.Groups[0] -eq $groupingResult.Groups[2]
) {
    throw 'Interactive selection must preserve multiple independent Pane groups.'
}
$global:v2SaveRows = @(
    "tmux-tab`t/home/reed/personal`t0`t`t`t`t`t`t`t`t`t`t`t`t`t"
    "shell-tab`t/home/reed/workspace`t0`t`t`t`t`t`t`t`t`t`t`t`t`t`t"
    "native-a`t/native/a`t1`t`t`t`tthread-na`tNative A`t`t`t`t`t`t`t`t`t"
    "native-b`t/native/b`t0`t`t`t`t`t`t`t`t`t`t`t`t`t`t"
    "tmux-tab`t/project/a`t1`t`t`t`tthread-a`tConversation A`tmy-tmux`t@0`t2`tconfig`tlayout-a`t%8`t1`t1"
    "tmux-tab`t/project/b`t1`t`t`t`tthread-b`tConversation B`tmy-tmux`t@0`t2`tconfig`tlayout-a`t%10`t2`t0"
    "tmux-tab`t/project/c`t0`t`t`t`t`t`tmy-tmux`t@0`t2`tconfig`tlayout-a`t%9`t3`t0"
    "other-tab`t/project/z`t1`t`t`t`tthread-z`tConversation Z`talpha-tmux`t@1`t1`tconfig`tlayout-z`t%11`t1`t1"
    "tmux-tab`t/project/d`t1`t`t`t`tthread-d`tConversation D`tmy-tmux`t@3`t0`tsecond`tlayout-d`t%13`t1`t1"
)
$baseV2SaveRows = @($global:v2SaveRows)
function wsl.exe {
    $global:LASTEXITCODE = 0
    if ($args -contains 'wslpath') { '/scanner.sh' } else { $global:v2SaveRows }
}

$save = Join-Path $PSScriptRoot '../Save-TerminalWorkspace.ps1'
$output = (& $save -Name regression -All -DryRun -Tmux | Out-String)
$workspace = $output.Substring($output.IndexOf('{')) | ConvertFrom-Json

if ($workspace.schemaVersion -ne 2 -or $workspace.mode -ne 'tmux' -or $workspace.name -ne 'regression') {
    throw 'Expected a named v2 tmux workspace.'
}
$windows = @($workspace.tmux.windows)
if ($windows.Count -ne 3) {
    throw 'Expected all three tmux windows in the named workspace.'
}
if (
    $windows[0].name -ne 'alpha-tmux-config' -or
    $windows[1].name -ne 'my-tmux-second' -or
    $windows[2].name -ne 'my-tmux-config'
) {
    throw 'Expected tmux windows in displayed window-index order with source prefixes.'
}
if (
    $windows[2].panes.Count -ne 3 -or
    $windows[2].panes[0].session_type -ne 'codex' -or
    $windows[2].panes[0].sessionId -ne 'thread-a' -or
    $windows[2].panes[2].session_type -ne 'shell' -or
    $windows[2].layout -ne 'layout-a'
) {
    throw 'Expected v2 tmux panes, session types, and layout.'
}
$automaticOutput = (& $save -DryRun -Tmux -SelectionKeyReader (New-TestKeyReader @('Enter')) 6>&1 | Out-String)
$automaticJsonStart = $automaticOutput.IndexOf("[`r`n")
$automaticWorkspaces = @($automaticOutput.Substring($automaticJsonStart) | ConvertFrom-Json)
if (
    $automaticWorkspaces.Count -ne 2 -or
    $automaticWorkspaces[0].name -ne 'alpha-tmux' -or
    $automaticWorkspaces[0].tmux.windows[0].name -ne 'config' -or
    $automaticWorkspaces[1].name -ne 'my-tmux' -or
    $automaticWorkspaces[1].tmux.windows.Count -ne 2 -or
    $automaticWorkspaces[1].tmux.windows[0].name -ne 'second' -or
    $automaticWorkspaces[1].tmux.windows[1].name -ne 'config' -or
    $automaticOutput -notmatch '按 TmuxSession 分别写入' -or
    $automaticOutput -notmatch '已选择 3 项，得到 3 个保存分组' -or
    $automaticOutput.IndexOf('my-tmux  window 0  second') -gt $automaticOutput.IndexOf('my-tmux  window 2  config')
) {
    throw 'Expected unnamed tmux saves to split by tmux session and preserve window order.'
}

$terminalOutput = (& $save -Name terminal-test -DryRun -SelectionKeyReader (New-TestKeyReader @('G', 'Enter')) 6>&1 | Out-String)
$terminalWorkspace = $terminalOutput.Substring($terminalOutput.IndexOf('{')) | ConvertFrom-Json
$terminalTab = $terminalWorkspace.terminal.tabs[0]
if (
    $terminalWorkspace.schemaVersion -ne 2 -or
    $terminalWorkspace.mode -ne 'terminal' -or
    $terminalWorkspace.name -ne 'terminal-test' -or
    $terminalWorkspace.terminal.tabs.Count -ne 1 -or
    $terminalTab.panes.Count -ne 3 -or
    $terminalTab.panes[0].session_type -ne 'codex' -or
    $terminalTab.panes[1].session_type -ne 'shell' -or
    $terminalTab.panes[2].session_type -ne 'shell' -or
    [math]::Abs([double]$terminalTab.layout.splits[0].size - (2.0 / 3.0)) -gt 0.000001 -or
    [double]$terminalTab.layout.splits[1].size -ne 0.5 -or
    $terminalOutput -notmatch '保存目标：写入 workspace \[terminal-test\]' -or
    $terminalOutput -notmatch '已选择 3 项，得到 1 个保存分组'
) {
    throw 'Expected a v2 terminal workspace with one evenly split three-pane tab.'
}

$global:v2SaveRows = @(
    "managed-tab`t/home/test-user/project`t1`tterminal-v2-test`t0`t0`tthread-a`tConversation A`t`t`t`t`t`t`t`t`t"
    "managed-tab`t/home/test-user/project`t0`tterminal-v2-test`t0`t1`t`t`t`t`t`t`t`t`t`t`t"
    "managed-tab`t/home/test-user`t0`tterminal-v2-test`t0`t2`t`t`t`t`t`t`t`t`t`t`t"
)
$roundTripRoot = Join-Path ([IO.Path]::GetTempPath()) "wtwork-roundtrip-$([guid]::NewGuid())"
$roundTripWorkspaceDirectory = Join-Path $roundTripRoot 'workspaces'
$roundTripPreviousDataRoot = $env:WTWORK_DATA_HOME
try {
    New-Item -ItemType Directory -Path $roundTripWorkspaceDirectory -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'terminal-v2-workspace.json') -Destination (Join-Path $roundTripWorkspaceDirectory 'terminal-v2-test.json')
    $env:WTWORK_DATA_HOME = $roundTripRoot
    $roundTripOutput = (& $save -Name terminal-roundtrip -All -DryRun | Out-String)
    $roundTripWorkspace = $roundTripOutput.Substring($roundTripOutput.IndexOf('{')) | ConvertFrom-Json
    if (
        $roundTripWorkspace.terminal.tabs[0].layout.activePane -ne 1 -or
        [math]::Abs([double]$roundTripWorkspace.terminal.tabs[0].layout.splits[0].size - (2.0 / 3.0)) -gt 0.000001
    ) {
        throw 'A restored v2 terminal tab must preserve its layout when saved again.'
    }
} finally {
    $env:WTWORK_DATA_HOME = $roundTripPreviousDataRoot
    if (Test-Path -LiteralPath $roundTripRoot) {
        Remove-Item -LiteralPath $roundTripRoot -Recurse -Force
    }
}

$global:v2SaveRows = $baseV2SaveRows
$orderedKeys = @('Spacebar', 'DownArrow', 'Spacebar', 'DownArrow', 'Spacebar', 'Spacebar', 'DownArrow', 'Spacebar', 'DownArrow', 'Spacebar', 'Enter')
$orderedOutput = (& $save -Name ordered -DryRun -Tmux -SelectionKeyReader (New-TestKeyReader $orderedKeys) | Out-String)
$orderedWorkspace = $orderedOutput.Substring($orderedOutput.IndexOf('{')) | ConvertFrom-Json
if (
    $orderedWorkspace.tmux.windows[0].name -ne 'my-tmux-config' -or
    $orderedWorkspace.tmux.windows[1].name -ne 'alpha-tmux-config' -or
    $orderedWorkspace.tmux.windows[2].name -ne 'my-tmux-second'
) {
    throw 'Expected explicit selection order to control saved tmux window order.'
}

$global:v2SaveRows = @(
    "shell-leaf`t/home/reed`t1`t`t`t`t`t`tleaf-tmux`t@8`t0`tzsh`tlayout-leaf`t%18`t0`t1"
)
$shellLeafOutput = (& $save -Name shell-leaf -All -DryRun -Tmux | Out-String)
$shellLeafWorkspace = $shellLeafOutput.Substring($shellLeafOutput.IndexOf('{')) | ConvertFrom-Json
if ($shellLeafWorkspace.tmux.windows[0].panes[0].session_type -ne 'shell') {
    throw 'A tmux Pane without a resumable Codex session must be saved as shell.'
}

$global:v2SaveRows = @(
    "invalid-tab`t/project/invalid`t1`t`t`t`tthread-invalid`tInvalid Name`troad:test.foo`t@9`t0`twork`tlayout-invalid`t%19`t0`t1"
)
$testDataRoot = Join-Path ([IO.Path]::GetTempPath()) "wtwork-v2-$([guid]::NewGuid())"
$previousDataRoot = $env:WTWORK_DATA_HOME
try {
    $env:WTWORK_DATA_HOME = $testDataRoot
    $savedOutput = (& $save -All -Tmux 6>&1 | Out-String)
    $savedPath = Join-Path $testDataRoot 'workspaces/road_test_foo.json'
    $savedWorkspace = Get-Content -LiteralPath $savedPath -Raw | ConvertFrom-Json
    if (
        $savedWorkspace.name -ne 'road_test_foo' -or
        $savedOutput -notmatch "Workspace name 'road:test\.foo' was saved as 'road_test_foo'\."
    ) {
        throw 'Expected invalid workspace characters to be replaced and reported.'
    }
} finally {
    $env:WTWORK_DATA_HOME = $previousDataRoot
    if (Test-Path -LiteralPath $testDataRoot) {
        Remove-Item -LiteralPath $testDataRoot -Recurse -Force
    }
}

$global:v2SaveRows = @(
    "invalid-a`t/project/a`t0`t`t`t`t`t`troad:test`t@20`t0`ta`tlayout-a`t%20`t0`t1"
    "invalid-b`t/project/b`t0`t`t`t`t`t`troad?test`t@21`t0`tb`tlayout-b`t%21`t0`t1"
)
$collisionMessage = try {
    & $save -All -DryRun -Tmux | Out-Null
    ''
} catch [System.Management.Automation.RuntimeException] {
    $_.Exception.Message
}
if (
    $collisionMessage -notmatch 'road:test' -or
    $collisionMessage -notmatch 'road\?test' -or
    $collisionMessage -notmatch 'road_test'
) {
    throw 'Sanitized workspace collisions must identify both source names and the target name.'
}

$global:v2SaveRows = $baseV2SaveRows
$confirmationRoot = Join-Path ([IO.Path]::GetTempPath()) "wtwork-confirm-$([guid]::NewGuid())"
$global:capturedPrompts = @()
function Read-Host {
    param([string]$Prompt)
    $global:capturedPrompts += $Prompt
    'y'
}
try {
    $env:WTWORK_DATA_HOME = $confirmationRoot
    & $save -Name merged -All -Tmux 6>&1 | Out-Null
    & $save -Name merged -All -Tmux 6>&1 | Out-Null
    if (
        @($global:capturedPrompts | Where-Object { $_ -match '当前有多个 tmux sessions' }).Count -ne 2 -or
        @($global:capturedPrompts | Where-Object { $_ -match '已有 workspace name \[merged\]' }).Count -ne 1 -or
        @($global:capturedPrompts | Where-Object { $_ -match '直接回车=取消' }).Count -ne 3
    ) {
        throw 'Expected merge and existing-workspace confirmations.'
    }
} finally {
    $env:WTWORK_DATA_HOME = $previousDataRoot
    if (Test-Path -LiteralPath $confirmationRoot) {
        Remove-Item -LiteralPath $confirmationRoot -Recurse -Force
    }
}

Write-Host 'V2 save regression tests passed.'
