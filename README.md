# Dynamic Claude Island

一个 macOS 顶部悬浮“灵动岛”，用于和本机已打开的 Claude Code 会话交互。

## 功能

- 桌面顶部中间常驻一个窄悬浮条，鼠标悬停后展开，移开后收起。
- 自动扫描 `~/.claude/projects` 和 `~/.claude/sessions`，展示当前 Claude Code 会话。
- 支持切换会话、查看最近消息、向选中的 Claude Code 会话发送指令。
- 优先把输入发送回原始 Terminal 标签页对应的 Claude Code 会话，避免多个 Terminal 窗口时发错。
- Claude 有新回复、运行完成、出错、需要确认或授权时，灵动岛会变色提示并发送 macOS 通知。
- 已完成状态使用醒目的绿色提示；需要确认使用橙色提示；错误使用红色提示。
- 支持手动关闭，关闭按钮会直接退出应用。

## 实现方式

这个应用不是 Claude Code 官方远程控制协议客户端。

它主要通过两部分工作：

- 会话发现：读取 Claude Code 写入本地的 session JSON 和 transcript JSONL。
- 消息发送：通过 Terminal AppleScript 定位目标标签页的 `tty`，并只向匹配的 Terminal 标签页执行输入。

发送前会重新校验 Claude Code 进程 PID 对应的 `tty`，如果进程和终端不匹配，会拒绝直接发送，避免多个 Terminal 窗口时误发。

## 使用

先确保本机已经安装并能运行 Claude Code。

构建并打开调试版 app：

```bash
Scripts/package-app.sh
open .build/debug/DynamicClaudeIsland.app
```

构建 release 版 app：

```bash
Scripts/package-app.sh release
open .build/release/DynamicClaudeIsland.app
```

首次运行时，macOS 可能会请求通知权限和 Terminal 自动化权限，请允许，否则通知或发送到原 Terminal 会话会受影响。

## 打包 DMG

生成 release app 和 DMG：

```bash
Scripts/package-dmg.sh
```

生成文件位于：

```text
dist/DynamicClaudeIsland-0.1.0.dmg
```

## 开发

直接编译：

```bash
swift build
```

运行：

```bash
swift run
```

项目结构：

- `Sources/DynamicClaudeIsland/AppDelegate.swift`：应用生命周期、会话同步、通知事件处理。
- `Sources/DynamicClaudeIsland/IslandPanelController.swift`：灵动岛窗口和交互 UI。
- `Sources/DynamicClaudeIsland/ClaudeSessionScanner.swift`：扫描 Claude Code 会话和 transcript。
- `Sources/DynamicClaudeIsland/ClaudeSessionEventMonitor.swift`：增量监控 Claude 回复、完成、确认和错误状态。
- `Sources/DynamicClaudeIsland/TerminalSessionSender.swift`：按 `tty` 向原 Terminal 标签页发送消息。

## Release

当前版本：`0.1.0`

发布包为未签名 macOS app。如果 macOS 拦截打开，可以在 Finder 中右键 app 后选择“打开”，或在系统设置的隐私与安全性里允许打开。
