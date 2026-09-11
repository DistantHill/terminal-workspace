$ErrorActionPreference = 'Stop'
function New-TestKeyReader {
    param([string[]]$Keys)
    $queue = [Collections.Generic.Queue[string]]::new()
    foreach ($key in $Keys) { $queue.Enqueue($key) }
    { $queue.Dequeue() }.GetNewClosure()
}
$entry = Join-Path $PSScriptRoot '../TerminalWorkspace.ps1'
$testDataRoot = Join-Path ([IO.Path]::GetTempPath()) "wtwork-cli-$([guid]::NewGuid())"
$workspaceDirectory = Join-Path $testDataRoot 'workspaces'
$previousDataRoot = $env:WTWORK_DATA_HOME

try {
    New-Item -ItemType Directory -Path $workspaceDirectory -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'tmux-v2-workspace.json') -Destination (Join-Path $workspaceDirectory 'tmux-v2-test.json')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'terminal-v2-workspace.json') -Destination (Join-Path $workspaceDirectory 'TempTab.json')
    $secondTmux = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'tmux-v2-workspace.json') -Raw | ConvertFrom-Json
    $secondTmux.name = 'tmux-v2-second'
    $secondTmux | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $workspaceDirectory 'tmux-v2-second.json')
    $env:WTWORK_DATA_HOME = $testDataRoot

    $namedPlan = & $entry open -n tmux-v2-test -DryRun | ConvertFrom-Json
    if ($namedPlan.renderer -ne 'tmux') {
        throw 'A named v2 workspace must select its renderer without -tmux.'
    }

    $defaultPlan = & $entry -DryRun | ConvertFrom-Json
    if ($defaultPlan.renderer -ne 'windows-terminal') {
        throw 'Bare wtwork must open TempTab as a terminal workspace.'
    }

    $multiKeys = New-TestKeyReader @('DownArrow', 'Spacebar', 'UpArrow', 'Spacebar', 'Enter')
    $multiPlans = @(& $entry open -Tmux -DryRun -SelectionKeyReader $multiKeys | ConvertFrom-Json)
    $payloadNames = @(
        foreach ($plan in $multiPlans) {
            $pythonIndex = [Array]::IndexOf($plan.arguments, 'python3')
            ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($plan.arguments[$pythonIndex + 2])) | ConvertFrom-Json).workspaceName
        }
    )
    if (
        $multiPlans.Count -ne 2 -or
        $payloadNames[0] -ne 'tmux-v2-test' -or
        $payloadNames[1] -ne 'tmux-v2-second' -or
        $multiPlans[0].arguments[1] -ne $multiPlans[1].arguments[1]
    ) {
        throw 'Tmux workspace selection must follow input order in one Windows Terminal window.'
    }

    $cancelOutput = (& $entry open -Tmux -SelectionKeyReader (New-TestKeyReader @('Enter')) 6>&1 | Out-String)
    if (
        $cancelOutput -notmatch '同一个新 Windows Terminal window' -or
        $cancelOutput -notmatch '没有选中 workspace：已取消打开，没有启动任何 workspace'
    ) {
        throw 'Tmux workspace browsing must explain and confirm the direct-Enter cancellation result.'
    }

    $missingMessage = try {
        & $entry open -n tmux-v2-tes -DryRun
        ''
    } catch [System.Management.Automation.RuntimeException] {
        $_.Exception.Message
    }
    if ($missingMessage -notmatch "Workspace 'tmux-v2-tes' does not exist" -or $missingMessage -notmatch 'tmux-v2-test') {
        throw 'A missing workspace must report similar saved names.'
    }

    $global:cliSaveRows = @(
        "native-cli`t/cli/project`t0`t`t`t`t`t`t`t`t`t`t`t`t`t`t"
    )
    function wsl.exe {
        $global:LASTEXITCODE = 0
        if ($args -contains 'wslpath') { '/scanner.sh' } else { $global:cliSaveRows }
    }
    $namedSaveOutput = (& $entry save -n cli-save -DryRun -SelectionKeyReader (New-TestKeyReader @('Enter')) | Out-String)
    $namedSave = $namedSaveOutput.Substring($namedSaveOutput.IndexOf('{')) | ConvertFrom-Json
    $defaultSaveOutput = (& $entry save -DryRun -SelectionKeyReader (New-TestKeyReader @('Enter')) | Out-String)
    $defaultSave = $defaultSaveOutput.Substring($defaultSaveOutput.IndexOf('{')) | ConvertFrom-Json
    $legacySaveOutput = (& $entry save legacy-save -DryRun -SelectionKeyReader (New-TestKeyReader @('Enter')) | Out-String)
    $legacySave = $legacySaveOutput.Substring($legacySaveOutput.IndexOf('{')) | ConvertFrom-Json
    if (
        $namedSave.name -ne 'cli-save' -or
        $defaultSave.name -ne 'TempTab' -or
        $legacySave.name -ne 'legacy-save' -or
        $namedSave.mode -ne 'terminal'
    ) {
        throw 'CLI save must support -n, default TempTab, and the legacy positional name.'
    }
} finally {
    $env:WTWORK_DATA_HOME = $previousDataRoot
    if (Test-Path -LiteralPath $testDataRoot) {
        Remove-Item -LiteralPath $testDataRoot -Recurse -Force
    }
}

Write-Host 'CLI regression tests passed.'
