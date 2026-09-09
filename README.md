# Terminal Workspace

把 Ubuntu shell/Codex 会话保存成命名 workspace。同一份 workspace 布局可以由 Windows Terminal 原生 Pane 或 tmux 渲染。

## 安装

### GitHub Release + curl（推荐）

在 PowerShell 7 中下载并执行 bootstrap：

```powershell
curl.exe -fsSLo "$env:TEMP\install-wtwork.ps1" `
  https://raw.githubusercontent.com/DistanceHill/SaveTerminalWorkSpace/main/install.ps1

pwsh -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\install-wtwork.ps1"
```

bootstrap 会从最新 GitHub Release 下载 `WTwork.zip` 和 `WTwork.zip.sha256`，通过 SHA256 校验后安装。

### 从 GitHub Release 使用 npm 安装

已经安装 Node/npm 的 Windows 用户也可以直接安装 Release 中的 npm 包：

```powershell
npm install -g https://github.com/DistanceHill/SaveTerminalWorkSpace/releases/latest/download/wtwork.tgz
```

npm 会根据 `package.json.bin` 创建 `WTwork` 命令；Node shim 会把参数原样转发给 PowerShell 7。

### 从源码安装

在 PowerShell 7 中运行：

```powershell
pwsh -ExecutionPolicy Bypass -File .\Install-WTwork.ps1
```

安装脚本会把运行文件复制到 `%LOCALAPPDATA%\WTwork`，创建 `WTwork.cmd`，并把 `%LOCALAPPDATA%\WTwork\bin` 注册到当前用户 PATH。workspace 数据统一保存在 `%LOCALAPPDATA%\WTwork\workspaces`；从旧源码目录安装时会迁移尚未存在的 workspace，升级安装不会删除或覆盖已有数据。

重新打开终端后，可以在任意目录运行：

```powershell
WTwork list
WTwork save 地图1
WTwork 地图1
WTwork 地图1 --tmux
```

只检查安装计划、不修改文件或 PATH：

```powershell
.\Install-WTwork.ps1 -DryRun
```

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

默认保存同时列出原生 shell/Codex Tab 和 tmux windows；tmux 自动按 window 聚合全部 pane，保留布局及 Codex 会话，不重复列出其外层 shell。无需将 tmux Tab 切回前台。Codex 会话解析会在数据库句柄关闭后按会话锁定位数据目录，读取版本号最高的 state 数据库。

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

仅列出并保存 tmux windows（不包含原生 shell Tab）：

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
