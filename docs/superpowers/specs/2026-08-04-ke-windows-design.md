# 「可」Windows 11 版设计

## 目标

为开源工具「可」增加 Windows 11 x64 版本。首版保持单一核心动作：用户在 Codex 或
Visual Studio Code 中聚焦空聊天输入框，点击始终置顶的“可”按钮，应用安全确认目标后
输入“可”并发送 Enter。

Windows 版以独立 C# 实现复刻 macOS 版的行为规则，不尝试在两个平台间共享 Swift
二进制。现有 macOS 源码、构建与发布流程保持不变。

## 首版范围

包含：

- Windows 11 x64。
- Codex 与 Visual Studio Code 聊天输入框。
- 可拖动、始终置顶、不会抢走键盘焦点的圆形悬浮按钮。
- 空聊天框识别、已有草稿拒绝、发送前目标复核、输入“可”和 Enter。
- 待命、按下、成功、安全拒绝四种视觉状态。
- 右键“关于”和“退出”。
- 无管理员权限、免安装、自包含单文件 EXE。

不包含：

- Codex 周额度光环。
- 微信或通用聊天软件适配器。
- 全局快捷键、托盘图标、任务栏按钮。
- 开机自启、自动更新、安装包、MSIX、WinGet。
- Windows ARM64、Windows 10。
- 管理员权限提升、跨完整性级别输入。
- Authenticode 商业证书签名。首版需在发布说明中说明 Windows SmartScreen 可能提示
  未知发布者，不提供关闭 SmartScreen 的脚本或指引。

## 技术路线

- 语言与运行时：C#、.NET 10 LTS。
- UI：WPF。
- 焦点与控件检查：Microsoft UI Automation。
- 窗口、前台进程与输入：Win32 P/Invoke。
- 测试：xUnit、Windows 专用集成测试窗口、PowerShell 打包检查。
- 发布：`net10.0-windows`、`win-x64`、self-contained、single-file、
  `PublishTrimmed=false`。

选择 WPF 而不是 WinUI 3，是因为本产品只有一个定制绘制的悬浮圆形窗口。WPF 能直接
支持无边框、透明、置顶窗口和自包含单文件发布，避免免安装 WinUI 3 额外的 Windows App
SDK runtime 与启动解压配置。选择 .NET 10 是因为它是当前受支持的 LTS，支持周期延续到
2028 年。

## 仓库结构

Windows 实现固定放在仓库根目录的 `windows/` 下：

```text
windows/
├── Ke.Windows.slnx
├── Directory.Build.props
├── src/
│   ├── Ke.Windows.Core/
│   ├── Ke.Windows.Automation/
│   └── Ke.Windows.App/
├── tests/
│   ├── Ke.Windows.Core.Tests/
│   ├── Ke.Windows.Automation.Tests/
│   └── Ke.Windows.IntegrationHarness/
├── scripts/
│   ├── build-portable.ps1
│   └── verify-portable.ps1
└── README.md
```

职责边界：

- `Ke.Windows.Core`：不可引用 WPF、UI Automation 或 Win32；只包含不可变快照、目标分类、
  发送状态机、错误模型和手势判断。
- `Ke.Windows.Automation`：专用 UI Automation 线程、前台窗口捕获、Codex/VS Code
  适配器、输入写入和复核。
- `Ke.Windows.App`：WPF 生命周期、悬浮按钮、位置保存、反馈、右键菜单和单实例。
- 测试项目：用纯值快照覆盖安全规则，用真实测试窗口覆盖 UI Automation 边界；不让单元
  测试依赖真实 Codex 或 VS Code。

## 架构

架构源文件：
[2026-08-04-ke-windows-architecture.architecture.json](2026-08-04-ke-windows-architecture.architecture.json)

可交互架构图：
[2026-08-04-ke-windows-architecture.html](2026-08-04-ke-windows-architecture.html)

WPF UI 线程只处理按钮、拖动和反馈。所有 UI Automation 调用都在一个长期存活的专用
MTA 线程执行；UI Automation 对象不离开该线程，只向 Core 返回不可变快照。这样避免
扫描自身 WPF 树时的死锁和 UI 卡顿。

一次点击只创建一个发送尝试。`SendCoordinator` 在尝试完成前拒绝第二次点击，结果通过
不可变 `SendResult` 回到 UI 线程。窗口使用命名 mutex `Local\\Ke.Windows.SingleInstance`
保证每个登录会话只有一个实例；第二次启动直接退出，不创建第二个悬浮按钮。

单次尝试的用户可见期限为 2.5 秒。到期后 UI 显示 `automationTimeout`，但 coordinator 仍
持有该尝试，直到自动化线程真正返回；期间继续拒绝点击，不创建第二条线程。自动化线程在
每个可能产生副作用的步骤前检查取消状态，因此超时后最多可能留下未发送的“可”，绝不会
继续按 Enter，也不会重试。

## 悬浮窗口与交互

窗口为 64 × 64 DIP 的圆形 WPF Window：

- `WindowStyle=None`、`AllowsTransparency=true`、透明背景、`Topmost=true`、
  `ShowActivated=false`、`ShowInTaskbar=false`。
- Win32 扩展样式包含 `WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW`。
- `WM_MOUSEACTIVATE` 返回 `MA_NOACTIVATE`，鼠标点击不会把键盘焦点从目标聊天框移走。
- 按下立即显示反馈；松开时才决定拖动或发送。
- 指针位移超过 6 DIP 后锁定为拖动，即使回到起点也不会误判为点击。
- 拖动时保留抓取偏移，窗口不会跳到指针中心。
- 位置写入 `%LOCALAPPDATA%\\Ke\\settings.json`，记录显示器 device name、DPI 和相对
  work-area 坐标；恢复时按当前 DPI 换算并夹紧到可见工作区。
- 不提供隐藏功能。右键菜单只有“关于”和“退出”，避免无托盘时无法恢复。

视觉状态：

- 待命：`#1E1E1F` 煤灰底、`#F6F7F8`“可”、`#55D6BE` 薄荷环；不循环动画。
- 按下：从当前呈现值缩小到 96%，松开或取消时从当前值恢复。
- 成功：薄荷底、煤灰字、米白描边，保持 650 ms 后恢复。
- 失败：煤灰底、`#FF5A5F` 红环，保持 900 ms，并显示具体中文 Tooltip。
- Windows 关闭客户端动画时，禁用缩放和光环过渡，只保留即时颜色反馈。
- AutomationPeer 暴露名称“可”和当前状态，并在成功或失败时发出通知事件。

## 焦点快照

自动化线程一次捕获以下不可变信息：

- `GetForegroundWindow()` 返回的顶层 `HWND`。
- `GetWindowThreadProcessId()` 返回的进程 ID。
- 当前进程与目标进程的 integrity level。
- 规范化进程映像名。
- `AutomationElement.FocusedElement`。
- focused element 的 runtime id、control type、class name、automation id、name、
  bounding rectangle、enabled、keyboard-focusable、password 和 read-only 状态。
- 从 focused element 向上最多 30 层、总计最多 512 个元素的有界 UIA 上下文。
- 使用 `ValuePattern` 或 `TextPattern.DocumentRange.GetText(4097)` 得到的有界输入内容；
  超过 4096 UTF-16 code units 视为不可安全读取并拒绝。

任一 UIA 属性返回不支持、陈旧元素、COM 异常、超时、越界或结构截断时失败关闭。应用
不记录 UIA 树、窗口标题或输入内容；Release 构建只允许记录不含用户数据的诊断代码。
focused element 未提供稳定 runtime id 时同样拒绝，不能用名称或坐标代替目标身份。

## 目标适配器

首版没有通用回退适配器。目标必须先匹配进程，再由对应适配器确认：

- Codex：进程映像名为 `Codex.exe`；focused control 为可编辑 Edit/Document；祖先上下文
  同时包含对话区域证据，并且不包含搜索、设置、原生审批、终端或代码编辑器证据。
- Visual Studio Code：进程映像名为 `Code.exe`；focused control 为可编辑
  Edit/Document；祖先上下文必须包含 Chat/Copilot 对话证据，并且不包含编辑器、终端、
  Command Palette、Quick Open、搜索或设置证据。

具体 UIA automation id、class name 与可访问名称必须来自 Windows 11 实机的只读探针。
实施顺序固定为：先运行探针并保存去标识化 fixture，再基于 fixture 编写失败测试，最后实现
适配器。fixture 只保留 control type、class、automation id、通用角色标签和树关系，删除
窗口标题、路径、对话内容及账号信息。

## 草稿与内容规则

接受的“空输入框”只有两类：

1. UIA 内容为零长度字符串。
2. UIA 明确暴露的空 contenteditable 结构换行；规范化后为零长度。

普通空格、制表符、用户输入的换行、零宽字符或任何可见字符都算草稿并拒绝。适配器可以
移除的占位 artifact 必须以 fixture 和回归测试逐项登记，禁止使用宽泛的 `Trim()`。

密码控件、read-only、disabled、不可键盘聚焦、无法完整读取或不支持可验证文本模式的
控件全部拒绝。

## 写入与发送流程

发送尝试严格执行：

1. 捕获前台窗口与 focused element。
2. 适配器分类并确认输入内容为空。
3. 重新捕获，要求 HWND、PID、runtime id、适配器类型与规范化内容全部相同。
4. 若控件支持可写 `ValuePattern`，调用 `SetValue("可")`；否则使用 Unicode
   `SendInput` 输入“可”。不使用剪贴板。
5. 再次捕获同一目标，要求内容严格等于“可”。
6. 再次确认前台 HWND 与 PID 未变化。
7. 使用 `SendInput` 发送一次 Enter key-down 和一次 key-up。
8. 不重试 Enter。任何失败都结束尝试并返回明确错误。

`TextPattern` 只用于读取，不假设它能写入。若使用键盘写入，先检查物理 Ctrl、Alt、Shift、
Windows 键均未按下；有修饰键按下时拒绝，避免合成组合键。Unicode 输入不依赖当前键盘
布局或中文输入法。

普通完整性级别进程不能向管理员权限目标可靠注入输入。取得前台 HWND 与 PID 后先比较
integrity level；目标高于自身时直接返回 `elevatedTarget`，不继续读取其 UIA 树，也不请求
提权。

## 错误与反馈

所有错误都不自动重试：

| 错误 | 用户提示 |
|---|---|
| `unsupportedApplication` | 当前只支持 Codex 和 VS Code |
| `notChatComposer` | 请先点击 Codex 或 VS Code 的聊天输入框 |
| `draftPresent` | 输入框已有内容，未发送 |
| `targetChanged` | 焦点已变化，未发送 |
| `automationUnavailable` | 无法安全读取当前输入框 |
| `automationTimeout` | 读取输入框超时，没有按回车 |
| `modifierKeyDown` | 请松开 Ctrl、Alt、Shift 或 Windows 键后重试 |
| `elevatedTarget` | 目标可能以管理员身份运行，未发送 |
| `writeUnconfirmed` | 写入未确认，没有按回车 |
| `returnDeliveryFailed` | 无法发送回车，不会重试 |

Tooltip 不抢焦点，最多显示 2.5 秒。错误只包含本地化文案和稳定诊断代码，不包含窗口标题、
输入内容、路径或 UIA 树。

## 构建与发布

`windows/scripts/build-portable.ps1` 在 Windows 11 x64 上执行：

1. 检查 .NET 10 SDK 与 Windows 11 x64。
2. 运行全部非交互测试。
3. `dotnet publish` 为 self-contained、single-file、win-x64 Release。
4. 不 trim WPF 程序；包含原生运行时库的自解压配置。
5. 将唯一运行文件重命名为 `可.exe`，输出到 `windows/dist/可-windows-x64/`。
6. 生成 SHA-256 文件和包含 LICENSE、README 的 ZIP；ZIP 是发布物，EXE 仍可单独运行。

`verify-portable.ps1` 在干净目录验证：ZIP 只包含允许文件、EXE 为 x64 GUI 程序、无外部
.NET runtime 依赖、版本资源与图标存在、启动后只产生一个实例、退出后无后台进程。

## 测试策略

### Core 单元测试

- Codex/VS Code 正向聊天 fixture。
- 搜索、设置、代码编辑器、终端、Command Palette、Quick Open、原生审批负向 fixture。
- 草稿、空格、制表符、换行、零宽字符和超长文本拒绝。
- runtime id、PID、HWND、内容或适配器变化时拒绝。
- 同一时间只有一个尝试，失败不会重试 Enter。
- 6 DIP 拖动阈值与拖动锁存。

### Automation 测试

- 有界 UIA 遍历的深度 30、元素 512、文本 4096 限制。
- ValuePattern 写入与 TextPattern 只读路径。
- Unicode SendInput 序列、修饰键保护、Enter 恰好一组 key-down/key-up。
- 高完整性级别目标拒绝。
- UIA 超时、陈旧元素和 COM 异常失败关闭。

### Windows 集成测试

`Ke.Windows.IntegrationHarness` 提供 Edit、Document、search、editor、terminal、password、
read-only、disabled 和会变化焦点的真实 WPF 窗口。交互测试在登录桌面会话运行，不在无桌面
CI 中伪装通过。

### 实机验收

在 Windows 11 x64 上对当前发布版 Codex 与 VS Code 逐项验证：

- 空聊天框点击一次，只出现一个“可”并发送一次。
- 已有草稿不改写、不发送。
- 代码编辑器、终端、搜索、设置、Command Palette、Quick Open 均拒绝。
- 拖动不发送；快速连点不重复发送。
- 点击按钮前后目标应用仍保持键盘焦点。
- 焦点在写入前变化时不写入；写入确认失败时不按 Enter。
- 管理员权限目标拒绝。
- 100 次空聊天框发送循环无重复 Enter、无悬浮窗失焦、无残留进程。
- 便携 ZIP 在未安装 .NET 的 Windows 11 x64 测试机解压后可直接运行。

## 风险与缓解

- Electron 版本变化可能改变 UIA 树：适配器由去标识化 fixture 和拒绝优先规则驱动；不匹配
  时闪红，不退回通用键盘发送。
- UIA/焦点与输入之间存在不可消除的竞态：写入前、写入后和 Enter 前分阶段复核，且 Enter
  永不重试。
- 单文件自包含体积较大并可能在首次启动解压原生依赖：以免安装和无 runtime 前置条件为
  优先，发布说明披露首次启动行为。
- 未签名 EXE 可能触发 SmartScreen：首版公开 SHA-256 和可复现构建步骤；后续单独设计
  Authenticode 发布流程。

## 完成标准

- Windows 代码与 macOS 代码边界清晰，现有 macOS 测试继续通过。
- Windows 非交互测试、交互 harness、便携发布验证全部通过。
- Codex 与 VS Code 实机验收全部通过。
- `可.exe` 无需管理员权限、安装程序或预装 .NET 即可运行。
- 不支持或无法确认的目标始终失败关闭，不覆盖草稿，不重试 Enter。

## 官方参考

- [.NET 支持策略](https://dotnet.microsoft.com/en-us/platform/support/policy)
- [WPF 概览](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/overview/)
- [UI Automation FocusedElement](https://learn.microsoft.com/en-us/dotNet/API/system.windows.automation.automationelement.focusedelement)
- [UI Automation 线程模型](https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-threading)
- [UI Automation 文本模式](https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-about-text-and-textrange-patterns)
- [SendInput 与 UIPI](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput)
- [.NET 单文件部署](https://learn.microsoft.com/en-us/dotnet/core/deploying/single-file/overview)
