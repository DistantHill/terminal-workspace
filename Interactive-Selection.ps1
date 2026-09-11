function ConvertTo-WTworkDisplayLines {
    param([string]$Text, [int]$MaximumWidth, [string]$ContinuationPrefix = '')

    $width = 0
    $result = [Text.StringBuilder]::new()
    $lines = [Collections.Generic.List[string]]::new()
    $elements = [Globalization.StringInfo]::GetTextElementEnumerator($Text)
    while ($elements.MoveNext()) {
        $element = $elements.GetTextElement()
        $elementWidth = if ($element -eq "`t") {
            8 - ($width % 8)
        } elseif ([int][char]$element[0] -le 0x7f) {
            1
        } else {
            2
        }
        if ($width + $elementWidth -gt $MaximumWidth) {
            $lines.Add($result.ToString())
            [void]$result.Clear()
            [void]$result.Append($ContinuationPrefix)
            $width = $ContinuationPrefix.Length
            if ($element -eq "`t") { $elementWidth = 8 - ($width % 8) }
        }
        [void]$result.Append($element)
        $width += $elementWidth
    }
    $lines.Add($result.ToString())
    $lines.ToArray()
}

function Limit-WTworkDisplayText {
    param([string]$Text, [int]$MaximumWidth)

    $elements = [Collections.Generic.List[string]]::new()
    $textWidth = 0
    $enumerator = [Globalization.StringInfo]::GetTextElementEnumerator($Text)
    while ($enumerator.MoveNext()) {
        $element = $enumerator.GetTextElement()
        $elements.Add($element)
        $textWidth += if ($element -eq "`t") { 8 - ($textWidth % 8) } elseif ([int][char]$element[0] -le 0x7f) { 1 } else { 2 }
    }
    if ($textWidth -le $MaximumWidth) { return $Text }

    $result = [Text.StringBuilder]::new()
    $displayWidth = 0
    foreach ($element in $elements) {
        $elementWidth = if ($element -eq "`t") { 8 - ($displayWidth % 8) } elseif ([int][char]$element[0] -le 0x7f) { 1 } else { 2 }
        if ($displayWidth + $elementWidth -gt $MaximumWidth - 3) { break }
        [void]$result.Append($element)
        $displayWidth += $elementWidth
    }
    [void]$result.Append('...')
    $result.ToString()
}

function Format-WTworkColumn {
    param([string]$Text, [int]$Width)

    $elements = [Collections.Generic.List[string]]::new()
    $textWidth = 0
    $enumerator = [Globalization.StringInfo]::GetTextElementEnumerator($Text)
    while ($enumerator.MoveNext()) {
        $element = $enumerator.GetTextElement()
        $elements.Add($element)
        $textWidth += if ([int][char]$element[0] -le 0x7f) { 1 } else { 2 }
    }

    $result = [Text.StringBuilder]::new()
    $displayWidth = 0
    $contentWidth = if ($textWidth -gt $Width) { $Width - 3 } else { $Width }
    foreach ($element in $elements) {
        $elementWidth = if ([int][char]$element[0] -le 0x7f) { 1 } else { 2 }
        if ($displayWidth + $elementWidth -gt $contentWidth) { break }
        [void]$result.Append($element)
        $displayWidth += $elementWidth
    }
    if ($textWidth -gt $Width) {
        [void]$result.Append('...')
        $displayWidth += 3
    }
    [void]$result.Append(' ' * ($Width - $displayWidth))
    $result.ToString()
}

function Select-WTworkItems {
    param(
        [Parameter(Mandatory)]
        [object[]]$Items,
        [Parameter(Mandatory)]
        [string]$Title,
        [switch]$DefaultAll,
        [switch]$Single,
        [switch]$AllowGrouping,
        [switch]$AllowLayoutToggle,
        [switch]$AllowDensityToggle,
        [string[]]$ActionKeys,
        [string]$ActionHelp,
        [scriptblock]$KeyReader
    )

    $selected = [bool[]]::new($Items.Count)
    $selectionOrder = [Collections.Generic.List[int]]::new()
    if ($DefaultAll) {
        for ($index = 0; $index -lt $Items.Count; $index++) {
            $selected[$index] = $true
            $selectionOrder.Add($index)
        }
    }
    $groups = [int[]]::new($Items.Count)
    $expanded = [bool[]]::new($Items.Count)
    $dense = $true
    $nextGroup = 1
    $cursor = 0
    $escape = [char]27

    $render = -not [bool]$KeyReader
    $maximumWidth = if ($render) { [math]::Max(20, [Console]::WindowWidth - 1) } else { 120 }
    if (-not $KeyReader) {
        $KeyReader = { [Console]::ReadKey($true) }
    }

    try {
        if ($render) { Write-Host "$escape[?25l" -NoNewline }
        $previousLineCount = 0
        while ($true) {
            if ($render) {
                if ($previousLineCount) {
                    Write-Host "$escape[$($previousLineCount)A" -NoNewline
                }
                $renderLines = [Collections.Generic.List[string]]::new()
                foreach ($line in (ConvertTo-WTworkDisplayLines -Text $Title -MaximumWidth $maximumWidth)) { $renderLines.Add($line) }
                for ($index = 0; $index -lt $Items.Count; $index++) {
                    $pointer = if ($index -eq $cursor) { '>' } else { ' ' }
                    $check = if ($selected[$index]) { '[x]' } else { '[ ]' }
                    $group = if ($groups[$index]) { " 组$($groups[$index])" } else { '' }
                    $itemText = "$pointer $check $($Items[$index].Label)$group"
                    if ($Items[$index].SingleLine) {
                        $renderLines.Add((Limit-WTworkDisplayText -Text $itemText -MaximumWidth $maximumWidth))
                    } else {
                        foreach ($line in (ConvertTo-WTworkDisplayLines -Text $itemText -MaximumWidth $maximumWidth -ContinuationPrefix '      ')) {
                            $renderLines.Add($line)
                        }
                    }
                    if ($expanded[$index]) {
                        foreach ($detail in @($Items[$index].Details)) {
                            foreach ($line in (ConvertTo-WTworkDisplayLines -Text "      $detail" -MaximumWidth $maximumWidth -ContinuationPrefix '      ')) {
                                $renderLines.Add($line)
                            }
                        }
                    }
                    if (-not $dense) { $renderLines.Add('') }
                }
                $groupHelp = if ($AllowGrouping) { '；G 将未分组的已选 Pane 编组；U 解除已选 Pane 分组' } else { '' }
                $shortcutHelp = if ($ActionHelp) { "；$ActionHelp" } else { '' }
                $layoutHelp = if ($AllowLayoutToggle) { '；Ctrl+T 展开/收起 layout' } else { '' }
                $densityHelp = if ($AllowDensityToggle) { '；Ctrl+E 切换 dense/宽松' } else { '' }
                foreach ($line in (ConvertTo-WTworkDisplayLines -Text "↑/↓ 移动；Space 选择/取消；Enter 执行；Esc 取消$groupHelp$shortcutHelp$layoutHelp$densityHelp" -MaximumWidth $maximumWidth)) { $renderLines.Add($line) }
                $renderLines.Add("已选择 $($selectionOrder.Count) 项")
                foreach ($line in $renderLines) { Write-Host "$escape[2K$line" }
                $previousLineCount = $renderLines.Count
            }

            $keyInput = & $KeyReader
            if ($keyInput -is [ConsoleKeyInfo]) {
                $key = [string]$keyInput.Key
                $actionKey = if ($keyInput.Modifiers -band [ConsoleModifiers]::Control) { "Ctrl+$key" } else { $key }
            } else {
                $key = [string]$keyInput
                $actionKey = $key
            }
            if ($actionKey -eq 'Ctrl+T' -and $AllowLayoutToggle) {
                $expanded[$cursor] = -not $expanded[$cursor]
                continue
            }
            if ($actionKey -eq 'Ctrl+E' -and $AllowDensityToggle) {
                $dense = -not $dense
                continue
            }
            if ($ActionKeys -contains $actionKey) {
                return [pscustomobject]@{ Indexes = @($selectionOrder); Groups = $groups; Action = $actionKey; Dense = $dense; Expanded = $expanded }
            }
            switch ($key) {
                'UpArrow' { $cursor = ($cursor - 1 + $Items.Count) % $Items.Count }
                'DownArrow' { $cursor = ($cursor + 1) % $Items.Count }
                'Spacebar' {
                    if ($Single -and -not $selected[$cursor]) {
                        for ($index = 0; $index -lt $selected.Count; $index++) { $selected[$index] = $false }
                        $selectionOrder.Clear()
                    }
                    $selected[$cursor] = -not $selected[$cursor]
                    if ($selected[$cursor]) {
                        $selectionOrder.Add($cursor)
                    } else {
                        [void]$selectionOrder.Remove($cursor)
                    }
                }
                'G' {
                    if ($AllowGrouping) {
                        $groupable = @($selectionOrder | Where-Object { $selected[$_] -and $Items[$_].Groupable -and $groups[$_] -eq 0 })
                        if ($groupable.Count -gt 1) {
                            foreach ($index in $groupable) { $groups[$index] = $nextGroup }
                            $nextGroup++
                        }
                    }
                }
                'U' {
                    if ($AllowGrouping) {
                        foreach ($index in $selectionOrder) { $groups[$index] = 0 }
                    }
                }
                'Enter' {
                    return [pscustomobject]@{ Indexes = @($selectionOrder); Groups = $groups; Action = ''; Dense = $dense; Expanded = $expanded }
                }
                'Escape' {
                    return [pscustomobject]@{ Indexes = @(); Groups = $groups; Action = ''; Dense = $dense; Expanded = $expanded }
                }
            }
        }
    } finally {
        if ($render) { Write-Host "$escape[?25h" -NoNewline }
    }
}
