# 可 · Windows 11 x64 测试版

这是一个无安装器、自包含 .NET 运行时的便携测试版。解压完整 ZIP，然后双击
`可.exe`。只支持 Windows 11 x64，不需要预先安装 .NET。

## 当前能力

- 只向 Codex 或 Visual Studio Code 中已聚焦、且为空的聊天输入框发送“可”。
- 输入框已有草稿、目标不确定、非聊天控件或目标权限高于本程序时，按钮闪红拒绝，不覆盖、不发送、不重试。
- 拖动悬浮按钮可移动位置；右键可查看“关于”或退出。
- 没有全局快捷键、系统托盘或周额度功能。

## 测试版限制

本版的 Codex/VS Code UI Automation 识别配置是保守的 bootstrap profile。在 W10
完成真机界面捕获和复核前，即使真实聊天输入框安全，此测试版也可能闪红拒绝。
这是预期的失败关闭行为。

`可.exe` 尚未进行代码签名，Windows 可能显示 SmartScreen“未知发布者”警告。
本文档不提供绕过系统安全保护的步骤。

## 校验下载文件

在解压目录打开 PowerShell，原样执行：

```powershell
$expected = (Get-Content -LiteralPath .\SHA256SUMS.txt).Split(' ')[0]; $actual = (Get-FileHash -LiteralPath .\可.exe -Algorithm SHA256).Hash; if ($actual -cne $expected) { throw 'SHA-256 mismatch' } else { "SHA-256 verified: $actual" }
```

输出 `SHA-256 verified` 和哈希值才表示校验通过。
