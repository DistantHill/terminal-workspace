# Terminal Workspace

把 Ubuntu shell/Codex 会话保存成命名 workspace。同一份 workspace 布局可以由 Windows Terminal 原生 Pane 或 tmux 渲染。

## 运行环境

使用 PowerShell 7：

```powershell
pwsh
cd '<clone-path>\terminal-workspace'
```

## 默认：Windows Terminal 原生 Tab/Pane

保存：

```powershell
.\TerminalWorkspace.ps1 save 地图1
```

列表中的已标记 Pane 会自动聚合成同一个 Tab。第一次登记手动创建的 Windows Terminal Pane 时，用 `+` 表示同一个 Tab、用逗号分隔不同 Tab：

```text
2+3+4,5
```

`2+3+4` 会保存为一个三 Pane Tab；第一次登记采用连续向右 50% 分割，所以结果为 50% / 25% / 25%。恢复后，每个 Pane 都带 workspace、Tab 和 Pane 序号标记，后续 `save` 可自动识别分组，不必再次输入 `+`。

默认恢复：

```powershell
.\TerminalWorkspace.ps1 地图1
```

恢复使用 Windows Terminal 的 `new-tab`、`split-pane` 和 `move-focus`。Codex Pane 使用精确 Session UUID 执行 `codex resume <UUID>`；shell Pane 启动登录 zsh。

## 显式选择 tmux

保存当前 tmux session 的 windows：

```powershell
.\TerminalWorkspace.ps1 save 地图1 --tmux
```

使用 tmux 恢复同一份 workspace：

```powershell
.\TerminalWorkspace.ps1 地图1 --tmux
```

tmux 映射规则：

- workspace 名称 = tmux session 名称；
- workspace 中每个逻辑 Tab = 一个 tmux window；
- 每个逻辑 Pane = 一个 tmux pane。

如果同名 tmux session 已存在，命令直接附着；不存在时按 workspace 创建完整 session/window/pane 布局。

PowerShell 自身不把 `--tmux` 当作普通 switch，入口脚本已专门兼容该字面参数。直接调用内部脚本时使用 `-Tmux`。

## 其他命令

列出 workspace：

```powershell
.\TerminalWorkspace.ps1 list
```

同名 workspace 默认拒绝覆盖：

```powershell
.\Save-TerminalWorkspace.ps1 -Name 地图1 -Force
```

检查启动参数但不打开 Terminal：

```powershell
.\Open-TerminalWorkspace.ps1 -Config .\workspaces\地图1.json -DryRun
.\Open-TerminalWorkspace.ps1 -Config .\workspaces\地图1.json -Tmux -DryRun
```

运行测试：

```powershell
.\Test-TerminalWorkspace.ps1
```

## 限制

Windows Terminal 没有公开的实时布局查询 API。未被本工具标记的现有原生 Pane，需要在第一次保存时用 `+` 登记父 Tab 关系；以后由环境标记自动识别。退出 Windows Terminal 后写入的 persisted layout 可以用于人工核对，但不作为日常实时保存的依赖。
