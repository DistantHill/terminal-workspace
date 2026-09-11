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
WTwork save -n 地图1
WTwork open -n 地图1
WTwork open -tmux
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

## 命令与默认行为

```powershell
WTwork
WTwork save [-n <workspace>] [-tmux] [-Force]
WTwork open [-n <workspace>] [-tmux]
WTwork list
```

`WTwork` 等同于 `WTwork open -n TempTab`。旧形式 `WTwork 地图1`、`WTwork save 地图1` 和 `--tmux` 仍然兼容；新脚本应使用 `open`、`-n`、`-tmux`。

### Windows Terminal Tab/Pane

不带 `-tmux` 时只扫描原生 Tab/Pane：

```powershell
WTwork save
WTwork save -n 地图项目
```

不指定 `-n` 时保存为 `TempTab.json` 并自动覆盖。每个选中分组恢复为一个新 Tab，并保留 Pane 布局。指定 `-n` 时保存为对应名称；已有同名文件且没有 `-Force` 时才询问是否覆盖。

所有多选菜单使用同一套 Codex CLI 风格按键：`↑/↓` 移动，`Space` 选择或取消，`Enter` 对全部已选项执行当前命令，`Esc` 取消。保存菜单默认全选，因此不改选择直接按 `Enter` 表示保存全部。

保存列表按 `TmuxSession → WindowIndex → Title → Panes → SessionName` 排列；workspace name 和 `Title` 各占固定 16 格，`Panes` 占固定 8 格。超宽的固定列显示为 `...`，后续列不会被挤压；最后的 `SessionName` 不截断，会按终端宽度完整换行显示。

已标记 Pane 会自动聚合。第一次登记手动创建的 Pane 时，勾选要合并的单 Pane 后按 `G`，菜单会用“组1、组2……”标记；按 `U` 可解除已选 Pane 的分组。同组 Pane 保存为一个等分 Tab。恢复后的标记使后续保存无需再次分组。

### tmux sessions

```powershell
WTwork save -tmux
```

列表按 `TmuxSession` 聚类，并按真实 `WindowIndex` 展示。`SessionName` 始终是 Pane 中的 Codex 会话名；shell Pane 留空。同一 tmux window 可以同时保存 Codex 和 shell Pane。

保存菜单默认全选；直接按 `Enter` 时，每个 tmux session 自动保存为独立的同名 workspace。例如来源是 `HDOnlineMAP` 和 `Multimodal-GEO-roadnet`，就分别写入两个 JSON。自动派生的文件直接覆盖旧结果。JSON window 顺序遵循勾选顺序。

指定 `-n` 会合并为一个 workspace：

```powershell
WTwork save -tmux -n 地图项目
```

跨多个 tmux sessions 时会列出来源和目标名称并二次确认；`-Force` 不跳过合并确认。合并后的 window 名为 `<TmuxSession>-<WindowName>`，单一来源则保留原名。

名称中的 Windows 非法文件名字符统一替换为 `_`，文件名、JSON 内部名称和恢复出的 tmux session 名称一致。保存后会明确提醒名称变化；多个自动名称清洗后冲突时会在写文件前报错。

### 打开

```powershell
WTwork open -n 地图项目
WTwork open -tmux
```

新版 JSON 根据根级 `mode` 自动选择恢复器，`-n` 已足够。名称不存在时会显示最多三个相似名称。`open -tmux` 会列出所有 v2 `mode=tmux` workspace，初始不选中任何项；用 `Space` 多选后按 `Enter`，它们会按勾选顺序打开在同一个新 Windows Terminal window 中，每个 workspace 一个 Tab。未选择时按 `Enter` 或按 `Esc` 都会取消。已有同名 live tmux session 时直接附着，否则重建。

命令执行后会另起一行报告实际逻辑分支：tmux 明确显示“检测到同名 session，附着”或“未检测到同名 session，重建并附着”；原生模式显示提交重建的 Tab/Pane 数。保存也会逐个 workspace 显示本次走“新建”还是“覆盖”分支。

恢复时 Codex Pane 使用精确 Session UUID 执行 `codex resume <UUID>`，shell Pane 启动登录 zsh。

### 管理 workspace

`WTwork list` 会进入同样的多选界面。选择一个或多个 workspace 后，可继续选择“打开”或“删除”；只选择一个时还可“改名”。也可直接按 `Ctrl+D` 删除所有已选项，或按 `Ctrl+R` 改名唯一的已选项。`Ctrl+T` 展开/收起当前 workspace 的 window/tab、Pane 数和 layout；`Ctrl+E` 切换 dense 与宽松行距。多选打开会按勾选顺序进入同一个新 Windows Terminal window。删除操作有独立确认菜单，未选择确认项或按 `Esc` 不会删除。改名会同时更新 JSON 文件名和内部 workspace 名称；目标名称已存在时直接报错，不覆盖。

## workspace JSON v2

新文件包含 `schemaVersion: 2` 和根级 `mode`（`tmux` 或 `terminal`）。Codex/shell 类型保存在 `tmux.windows[].panes[].session_type` 或 `terminal.tabs[].panes[].session_type`，布局位于各 window/tab 的 `layout`。例如：

```json
{
  "schemaVersion": 2,
  "name": "地图项目",
  "mode": "tmux",
  "distribution": "Ubuntu-22.04",
  "profile": "Ubuntu-22.04",
  "tmux": {
    "windows": [{
      "index": 0,
      "name": "并行计算",
      "layout": "b25f,240x60,0,0[240x29,0,0,1,240x30,0,30,2]",
      "activePane": 0,
      "panes": [
        { "index": 0, "directory": "/home/reed/project", "session_type": "codex", "sessionId": "11111111-1111-4111-8111-111111111111", "sessionName": "流式计算和并行数据一致性" },
        { "index": 1, "directory": "/home/reed/project", "session_type": "shell", "sessionId": null, "sessionName": null }
      ]
    }]
  }
}
```

原生模式的完整示例见 `workspace.example.json`。未带版本号的 v1 JSON 仍可读取；它在未传 `-tmux` 时按 Windows Terminal 恢复，传入时按 tmux 恢复。

## 其他命令

列出 workspace：

```powershell
.\TerminalWorkspace.ps1 list
```

强制覆盖显式命名的 workspace：

```powershell
WTwork save -n 地图1 -Force
```

检查启动参数但不打开 Terminal：

```powershell
.\Open-TerminalWorkspace.ps1 -Config .\workspace.example.json -DryRun
```

运行测试：

```powershell
.\Test-TerminalWorkspace.ps1
```

## 限制

Windows Terminal 没有公开的实时布局查询 API。未被本工具标记的现有原生 Pane，需要在第一次保存时用 `+` 登记父 Tab 关系；以后由环境标记自动识别。退出 Windows Terminal 后写入的 persisted layout 可以用于人工核对，但不作为日常实时保存的依赖。
