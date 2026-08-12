# 可 Windows 测试版

本预发布版用于 Windows 11 x64 真机测试。下载 `可-windows-x64.zip`，完整解压后
运行 `可.exe`；包内已自包含 .NET 运行时。

- 仅支持 Codex 和 Visual Studio Code 的空聊天输入框。
- 已有草稿、目标不确定、非聊天控件或高权限目标会闪红拒绝，不重试。
- 可拖动；右键可查看关于或退出。
- 不包含全局快捷键、托盘和周额度。

## 已知限制

Codex/VS Code 识别目前使用保守的 bootstrap profile。W10 的去标识化真机 fixture、
已登录交互 harness、聚焦/拖动/辅助功能检查以及 100 次验收尚未完成。因此，
对真实 UI Automation 结构不确定时，此测试版会安全地闪红拒绝。

本版 `可.exe` 未签名，发布者为未知，SmartScreen 可能显示警告。请先使用同页下载的
`SHA256SUMS.txt` 或 ZIP 包内的同名文件校验。不提供绕过 SmartScreen 的步骤。
