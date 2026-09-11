function ConvertTo-WTworkDisplayLine {
    param([string]$Text, [int]$MaximumWidth)

    $width = 0
    $result = [Text.StringBuilder]::new()
    $elements = [Globalization.StringInfo]::GetTextElementEnumerator($Text)
    while ($elements.MoveNext()) {
        $element = $elements.GetTextElement()
        $elementWidth = if ([int][char]$element[0] -le 0x7f) { 1 } else { 2 }
        if ($width + $elementWidth -gt $MaximumWidth - 1) {
            [void]$result.Append('…')
            return $result.ToString()
        }
        [void]$result.Append($element)
        $width += $elementWidth
    }
    $result.ToString()
}

function Select-WTworkItems {
    param(
        [Parameter(Mandatory)]
        [object[]]$Items,
        [Parameter(Mandatory)]
        [string]$Title,
        [switch]$DefaultAll,
        [switch]$AllowGrouping,
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
    $nextGroup = 1
    $cursor = 0
    $escape = [char]27
    $lineCount = $Items.Count + 3

    $render = -not [bool]$KeyReader
    $maximumWidth = if ($render) { [math]::Max(20, [Console]::WindowWidth - 1) } else { 120 }
    if (-not $KeyReader) {
        $KeyReader = { [Console]::ReadKey($true).Key }
    }

    try {
        if ($render) { Write-Host "$escape[?25l" -NoNewline }
        $firstRender = $true
        while ($true) {
            if ($render) {
                if (-not $firstRender) {
                    Write-Host "$escape[$($lineCount)A" -NoNewline
                }
                $firstRender = $false
                Write-Host "$escape[2K$(ConvertTo-WTworkDisplayLine -Text $Title -MaximumWidth $maximumWidth)"
                for ($index = 0; $index -lt $Items.Count; $index++) {
                    $pointer = if ($index -eq $cursor) { '>' } else { ' ' }
                    $check = if ($selected[$index]) { '[x]' } else { '[ ]' }
                    $group = if ($groups[$index]) { " 组$($groups[$index])" } else { '' }
                    $line = ConvertTo-WTworkDisplayLine -Text "$pointer $check $($Items[$index].Label)$group" -MaximumWidth $maximumWidth
                    Write-Host "$escape[2K$line"
                }
                $groupHelp = if ($AllowGrouping) { '；G 将未分组的已选 Pane 编组；U 解除已选 Pane 分组' } else { '' }
                $help = ConvertTo-WTworkDisplayLine -Text "↑/↓ 移动；Space 选择/取消；Enter 执行；Esc 取消$groupHelp" -MaximumWidth $maximumWidth
                Write-Host "$escape[2K$help"
                Write-Host "$escape[2K已选择 $($selectionOrder.Count) 项"
            }

            $key = & $KeyReader
            switch ([string]$key) {
                'UpArrow' { $cursor = ($cursor - 1 + $Items.Count) % $Items.Count }
                'DownArrow' { $cursor = ($cursor + 1) % $Items.Count }
                'Spacebar' {
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
                    return [pscustomobject]@{ Indexes = @($selectionOrder); Groups = $groups }
                }
                'Escape' {
                    return [pscustomobject]@{ Indexes = @(); Groups = $groups }
                }
            }
        }
    } finally {
        if ($render) { Write-Host "$escape[?25h" -NoNewline }
    }
}
