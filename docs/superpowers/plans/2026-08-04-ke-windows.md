# 「可」Windows 11 版实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付一个 Windows 11 x64 便携版“可”，用户点击不抢焦点的悬浮按钮后，程序只向当前聚焦且为空的 Codex 或 Visual Studio Code 聊天输入框写入“可”并发送一次 Enter。

**Architecture:** Windows 版放在独立 `windows/` 目录，以 .NET 10、WPF、Microsoft UI Automation 和 Win32 实现，不改动现有 Swift/macOS 构建。WPF UI 线程只显示按钮和反馈；一个长期存活的 MTA 自动化线程串行执行有界焦点快照、应用适配、安全复核、写入和 Enter，任何不确定状态失败关闭。

**Tech Stack:** C#、.NET 10 LTS、WPF、System.Windows.Automation、Win32 P/Invoke、xUnit 2.9.3、Microsoft.NET.Test.Sdk 18.8.1、PowerShell 7、GitHub Actions Windows runner。

## Global Constraints

- 只支持 Windows 11 x64、Codex (`Codex.exe`) 与 Visual Studio Code (`Code.exe`)。
- 只提供 64 × 64 DIP 悬浮“可”按钮；不提供全局快捷键、托盘、任务栏按钮或周额度光环。
- 目标输入框必须为空；普通空格、制表符、用户换行、零宽字符及任何可见字符都算草稿。
- 只接受去标识化实机 fixture 证明过的空 contenteditable artifact；禁止宽泛 `Trim()`。
- 写入前、写入后和 Enter 前必须复核 HWND、PID、runtime id、应用类型与内容。
- UIA 调用只在一个长期存活的 MTA 线程运行；UIA 对象不能离开该线程。
- UIA 深度上限 30、元素上限 512、文本上限 4096 UTF-16 code units；越界、截断、陈旧元素、COM 异常全部失败关闭。
- 单次尝试 2.5 秒后显示 `automationTimeout`；自动化线程返回前仍保持 in-flight，超时后不得按 Enter 或重试。
- 目标完整性级别高于本进程时，在遍历 UIA 树前返回 `elevatedTarget`，不请求管理员权限。
- 发布物为 self-contained、single-file、`win-x64`、`PublishTrimmed=false` 的便携 ZIP；无安装器、无预装 .NET 要求。
- Release 日志不得包含窗口标题、输入内容、文件路径、账号信息或 UIA 树。
- 每次推送 Windows 代码时由 GitHub Actions `windows-latest` + `.NET SDK 10.0.302` 运行完整 solution 测试；最终便携 ZIP/EXE 通过 GitHub Release 提供。
- NuGet 版本固定为 [xUnit 2.9.3](https://www.nuget.org/packages/xunit/2.9.3)、[xunit.runner.visualstudio 3.1.5](https://www.nuget.org/packages/xunit.runner.visualstudio/3.1.5) 和 [Microsoft.NET.Test.Sdk 18.8.1](https://www.nuget.org/packages/Microsoft.NET.Test.Sdk/18.8.1)。

---

## 文件结构

```text
windows/
├── Ke.Windows.slnx
├── Directory.Build.props
├── Directory.Packages.props
├── .gitignore
├── README.md
├── fixtures/
│   ├── codex-chat-empty.json
│   ├── codex-negative.json
│   ├── vscode-chat-empty.json
│   └── vscode-negative.json
├── scripts/
│   ├── build-portable.ps1
│   └── verify-portable.ps1
├── src/
│   ├── Ke.Windows.Core/
│   │   ├── Ke.Windows.Core.csproj
│   │   ├── ProductInfo.cs
│   │   ├── SendContracts.cs
│   │   ├── FocusSnapshot.cs
│   │   ├── DraftPolicy.cs
│   │   ├── GestureDecision.cs
│   │   └── PanelPlacement.cs
│   ├── Ke.Windows.Automation/
│   │   ├── Ke.Windows.Automation.csproj
│   │   ├── AutomationDispatcher.cs
│   │   ├── FocusSnapshotProvider.cs
│   │   ├── UiAutomationTreeReader.cs
│   │   ├── IntegrityLevelReader.cs
│   │   ├── NativeMethods.cs
│   │   ├── TargetAdapterRegistry.cs
│   │   ├── ProfileTargetAdapter.cs
│   │   ├── AdapterProfiles.cs
│   │   ├── WindowsInputWriter.cs
│   │   └── FocusedChatSender.cs
│   └── Ke.Windows.App/
│       ├── Ke.Windows.App.csproj
│       ├── App.xaml
│       ├── App.xaml.cs
│       ├── MainWindow.xaml
│       ├── MainWindow.xaml.cs
│       ├── SendCoordinator.cs
│       ├── ButtonFeedbackController.cs
│       ├── KeButtonAutomationPeer.cs
│       ├── PanelPositionStore.cs
│       ├── SingleInstanceGuard.cs
│       └── Assets/App.ico
└── tests/
    ├── Ke.Windows.Core.Tests/
    │   ├── Ke.Windows.Core.Tests.csproj
    │   ├── DraftPolicyTests.cs
    │   └── GestureDecisionTests.cs
    ├── Ke.Windows.Automation.Tests/
    │   ├── Ke.Windows.Automation.Tests.csproj
    │   ├── AutomationDispatcherTests.cs
    │   ├── FocusSnapshotProviderTests.cs
    │   ├── TargetAdapterRegistryTests.cs
    │   ├── FocusedChatSenderTests.cs
    │   ├── LiveFixtureCaptureTests.cs
    │   └── Fixtures/*.json
    └── Ke.Windows.IntegrationHarness/
        ├── Ke.Windows.IntegrationHarness.csproj
        ├── App.xaml
        ├── App.xaml.cs
        ├── MainWindow.xaml
        └── MainWindow.xaml.cs
```

仓库根目录同时包含 `.github/workflows/windows-ci.yml`；Task 9 再增加 Release workflow。

`Ke.Windows.Core` 不引用 WPF、UI Automation 或 Win32。`Ke.Windows.Automation` 持有全部系统对象与输入副作用。`Ke.Windows.App` 只组合服务、展示状态和保存窗口位置。fixture 是去标识化测试数据，不是运行时用户数据。

---

### Task 1: 建立 Windows solution 与测试基线

**Files:**
- Create: `windows/Ke.Windows.slnx`
- Create: `windows/Directory.Build.props`
- Create: `windows/Directory.Packages.props`
- Create: `windows/.gitignore`
- Create: `windows/src/Ke.Windows.Core/Ke.Windows.Core.csproj`
- Create: `windows/src/Ke.Windows.Core/ProductInfo.cs`
- Create: `windows/src/Ke.Windows.Automation/Ke.Windows.Automation.csproj`
- Create: `windows/src/Ke.Windows.App/Ke.Windows.App.csproj`
- Create: `windows/tests/Ke.Windows.Core.Tests/Ke.Windows.Core.Tests.csproj`
- Create: `windows/tests/Ke.Windows.Core.Tests/ProductInfoTests.cs`
- Create: `windows/tests/Ke.Windows.Automation.Tests/Ke.Windows.Automation.Tests.csproj`
- Create: `windows/tests/Ke.Windows.IntegrationHarness/Ke.Windows.IntegrationHarness.csproj`
- Create: `.github/workflows/windows-ci.yml`

**Interfaces:**
- Consumes: .NET 10 SDK on Windows 11 x64.
- Produces: buildable `Ke.Windows.slnx`; `ProductInfo.ApprovalText` and `ProductInfo.ProductName` constants.

- [ ] **Step 1: 生成 solution、项目与引用关系**

从仓库根目录运行：

```powershell
dotnet new sln --name Ke.Windows --format slnx --output windows
dotnet new classlib --name Ke.Windows.Core --output windows/src/Ke.Windows.Core --framework net10.0
dotnet new classlib --name Ke.Windows.Automation --output windows/src/Ke.Windows.Automation --framework net10.0-windows
dotnet new wpf --name Ke.Windows.App --output windows/src/Ke.Windows.App --framework net10.0-windows
dotnet new xunit --name Ke.Windows.Core.Tests --output windows/tests/Ke.Windows.Core.Tests --framework net10.0
dotnet new xunit --name Ke.Windows.Automation.Tests --output windows/tests/Ke.Windows.Automation.Tests --framework net10.0-windows
dotnet new wpf --name Ke.Windows.IntegrationHarness --output windows/tests/Ke.Windows.IntegrationHarness --framework net10.0-windows
dotnet sln windows/Ke.Windows.slnx add windows/src/Ke.Windows.Core/Ke.Windows.Core.csproj windows/src/Ke.Windows.Automation/Ke.Windows.Automation.csproj windows/src/Ke.Windows.App/Ke.Windows.App.csproj windows/tests/Ke.Windows.Core.Tests/Ke.Windows.Core.Tests.csproj windows/tests/Ke.Windows.Automation.Tests/Ke.Windows.Automation.Tests.csproj windows/tests/Ke.Windows.IntegrationHarness/Ke.Windows.IntegrationHarness.csproj
dotnet add windows/src/Ke.Windows.Automation/Ke.Windows.Automation.csproj reference windows/src/Ke.Windows.Core/Ke.Windows.Core.csproj
dotnet add windows/src/Ke.Windows.App/Ke.Windows.App.csproj reference windows/src/Ke.Windows.Core/Ke.Windows.Core.csproj windows/src/Ke.Windows.Automation/Ke.Windows.Automation.csproj
dotnet add windows/tests/Ke.Windows.Core.Tests/Ke.Windows.Core.Tests.csproj reference windows/src/Ke.Windows.Core/Ke.Windows.Core.csproj
dotnet add windows/tests/Ke.Windows.Automation.Tests/Ke.Windows.Automation.Tests.csproj reference windows/src/Ke.Windows.Core/Ke.Windows.Core.csproj windows/src/Ke.Windows.Automation/Ke.Windows.Automation.csproj
```

Expected: 六个项目加入 `windows/Ke.Windows.slnx`，所有命令 exit code 0。

- [ ] **Step 2: 固定编译与测试配置**

`windows/Directory.Build.props`：

```xml
<Project>
  <PropertyGroup>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <LangVersion>latest</LangVersion>
    <TreatWarningsAsErrors>true</TreatWarningsAsErrors>
    <Deterministic>true</Deterministic>
    <PlatformTarget>x64</PlatformTarget>
  </PropertyGroup>
</Project>
```

`windows/Directory.Packages.props`：

```xml
<Project>
  <PropertyGroup>
    <ManagePackageVersionsCentrally>true</ManagePackageVersionsCentrally>
  </PropertyGroup>
  <ItemGroup>
    <PackageVersion Include="Microsoft.NET.Test.Sdk" Version="18.8.1" />
    <PackageVersion Include="xunit" Version="2.9.3" />
    <PackageVersion Include="xunit.runner.visualstudio" Version="3.1.5" />
  </ItemGroup>
</Project>
```

`windows/.gitignore`：

```gitignore
**/bin/
**/obj/
TestResults/
dist/
```

两个测试项目只保留以下 package references；删除模板产生的固定版本：

```xml
<ItemGroup>
  <PackageReference Include="Microsoft.NET.Test.Sdk" />
  <PackageReference Include="xunit" />
  <PackageReference Include="xunit.runner.visualstudio">
    <PrivateAssets>all</PrivateAssets>
    <IncludeAssets>runtime; build; native; contentfiles; analyzers; buildtransitive</IncludeAssets>
  </PackageReference>
</ItemGroup>
```

Automation 项目增加 `<UseWPF>true</UseWPF>`，App 与 IntegrationHarness 保持 `<UseWPF>true</UseWPF>`；三个 Windows 项目使用 `net10.0-windows10.0.22000.0`。App 增加：

```xml
<PropertyGroup>
  <OutputType>WinExe</OutputType>
  <RuntimeIdentifier>win-x64</RuntimeIdentifier>
  <PublishSingleFile>true</PublishSingleFile>
  <SelfContained>true</SelfContained>
  <PublishTrimmed>false</PublishTrimmed>
  <IncludeNativeLibrariesForSelfExtract>true</IncludeNativeLibrariesForSelfExtract>
  <EnableCompressionInSingleFile>true</EnableCompressionInSingleFile>
  <AssemblyName>Ke.Windows</AssemblyName>
</PropertyGroup>
```

`ApplicationIcon` 在 Task 9 生成 `App.ico` 后加入，避免工程骨架首次编译引用尚不存在的文件。

`.github/workflows/windows-ci.yml` 使用 `windows-latest`、`actions/checkout@v6`、`actions/setup-dotnet@v6`，安装 `10.0.302`，执行 `dotnet test windows/Ke.Windows.slnx -c Release`；触发条件为 feature branch/PR 中 `windows/**` 或该 workflow 自身变化，只授予 `contents: read`。

- [ ] **Step 3: 写入失败 smoke test**

`windows/tests/Ke.Windows.Core.Tests/ProductInfoTests.cs`：

```csharp
using Ke.Windows.Core;

namespace Ke.Windows.Core.Tests;

public sealed class ProductInfoTests
{
    [Fact]
    public void Product_identity_is_fixed()
    {
        Assert.Equal("可", ProductInfo.ProductName);
        Assert.Equal("可", ProductInfo.ApprovalText);
    }
}
```

- [ ] **Step 4: 运行测试并确认失败**

Run: `dotnet test windows/tests/Ke.Windows.Core.Tests/Ke.Windows.Core.Tests.csproj -c Release`

Expected: FAIL，编译器报告 `ProductInfo` 不存在。

- [ ] **Step 5: 写入最小产品常量并清理模板文件**

`windows/src/Ke.Windows.Core/ProductInfo.cs`：

```csharp
namespace Ke.Windows.Core;

public static class ProductInfo
{
    public const string ProductName = "可";
    public const string ApprovalText = "可";
}
```

删除所有项目的模板 `Class1.cs` 和模板测试 `UnitTest1.cs`。

- [ ] **Step 6: 验证 solution 基线**

本地临时 `.NET 10` SDK 运行 Core GREEN 后推送 feature branch；GitHub Actions Windows runner 执行：`dotnet test windows/Ke.Windows.slnx -c Release`。

Expected: CI PASS；`ProductInfoTests` 2 个断言通过，0 warnings，0 errors。

- [ ] **Step 7: 提交**

```bash
git add .github/workflows/windows-ci.yml windows/Ke.Windows.slnx windows/Directory.Build.props windows/Directory.Packages.props windows/.gitignore windows/src windows/tests
git commit -m "build(windows): Add .NET solution scaffold"
```

---

### Task 2: 实现纯 Core 安全模型、草稿规则与手势判断

**Files:**
- Create: `windows/src/Ke.Windows.Core/SendContracts.cs`
- Create: `windows/src/Ke.Windows.Core/FocusSnapshot.cs`
- Create: `windows/src/Ke.Windows.Core/DraftPolicy.cs`
- Create: `windows/src/Ke.Windows.Core/GestureDecision.cs`
- Create: `windows/tests/Ke.Windows.Core.Tests/DraftPolicyTests.cs`
- Create: `windows/tests/Ke.Windows.Core.Tests/GestureDecisionTests.cs`
- Create: `windows/tests/Ke.Windows.Core.Tests/TargetIdentityTests.cs`

**Interfaces:**
- Consumes: `ProductInfo.ApprovalText`.
- Produces: `SendErrorCode`, `SendResult`, `SupportedApplication`, `ElementSummary`, `FocusSnapshot`, `TargetIdentity`, `DraftPolicy.Classify`, `GestureTracker`.

- [ ] **Step 1: 写入草稿、身份与手势失败测试**

核心断言固定为：

```csharp
[Theory]
[InlineData(" ")]
[InlineData("\t")]
[InlineData("\n")]
[InlineData("\u200B")]
[InlineData("draft")]
public void User_content_is_never_empty(string text) =>
    Assert.Equal(DraftState.Present, DraftPolicy.Classify(text, []).State);

[Fact]
public void Only_explicit_fixture_artifact_normalizes_to_empty() =>
    Assert.Equal(DraftState.Empty, DraftPolicy.Classify("\r\n", ["\r\n"]).State);

[Fact]
public void Null_or_over_limit_text_is_unreadable()
{
    Assert.Equal(DraftState.Unreadable, DraftPolicy.Classify(null, []).State);
    Assert.Equal(DraftState.Unreadable, DraftPolicy.Classify(new string('x', 4097), []).State);
}

[Fact]
public void Target_identity_includes_window_process_runtime_id_and_app()
{
    var a = new TargetIdentity((nint)1, 2, "42.7", SupportedApplication.Codex);
    Assert.NotEqual(a, a with { RuntimeId = "42.8" });
    Assert.NotEqual(a, a with { Application = SupportedApplication.VisualStudioCode });
}

[Fact]
public void Drag_latches_after_six_dip()
{
    var tracker = new GestureTracker(new DipPoint(10, 10), 6);
    Assert.Equal(GestureDecision.Pending, tracker.MoveTo(new DipPoint(15.9, 10)));
    Assert.Equal(GestureDecision.Drag, tracker.MoveTo(new DipPoint(16.1, 10)));
    Assert.Equal(GestureDecision.Drag, tracker.MoveTo(new DipPoint(10, 10)));
    Assert.Equal(GestureDecision.Drag, tracker.Release());
}

[Fact]
public void Stationary_release_is_click()
{
    var tracker = new GestureTracker(new DipPoint(0, 0), 6);
    Assert.Equal(GestureDecision.Click, tracker.Release());
}
```

- [ ] **Step 2: 运行测试并确认缺少 Core 类型**

Run: `dotnet test windows/tests/Ke.Windows.Core.Tests/Ke.Windows.Core.Tests.csproj -c Release`

Expected: FAIL，编译器报告 `DraftPolicy`、`TargetIdentity`、`GestureTracker` 不存在。

- [ ] **Step 3: 实现发送契约与不可变快照**

`SendContracts.cs` 定义：

```csharp
namespace Ke.Windows.Core;

public enum SendErrorCode
{
    UnsupportedApplication, NotChatComposer, DraftPresent, TargetChanged,
    AutomationUnavailable, AutomationTimeout, ModifierKeyDown, ElevatedTarget,
    WriteUnconfirmed, ReturnDeliveryFailed
}

public sealed record SendResult(bool IsSuccess, SendErrorCode? Error)
{
    public static SendResult Success() => new(true, null);
    public static SendResult Failure(SendErrorCode error) => new(false, error);
}

public enum SupportedApplication { Codex, VisualStudioCode }
```

`FocusSnapshot.cs` 定义所有跨线程纯值：

```csharp
namespace Ke.Windows.Core;

public sealed record ElementSummary(
    string RuntimeId,
    string ControlType,
    string ClassName,
    string AutomationId,
    string Name,
    bool IsEnabled,
    bool IsKeyboardFocusable,
    bool IsPassword,
    bool IsReadOnly,
    string? Text);

public sealed record FocusSnapshot(
    nint Hwnd,
    uint ProcessId,
    string ProcessImageName,
    int SourceIntegrityRid,
    int TargetIntegrityRid,
    ElementSummary Focused,
    IReadOnlyList<ElementSummary> Ancestors,
    IReadOnlyList<ElementSummary> Nearby);

public sealed record TargetIdentity(
    nint Hwnd,
    uint ProcessId,
    string RuntimeId,
    SupportedApplication Application);
```

- [ ] **Step 4: 实现精确草稿规则**

`DraftPolicy.cs`：

```csharp
namespace Ke.Windows.Core;

public enum DraftState { Empty, Present, Unreadable }
public sealed record DraftDecision(DraftState State, string? NormalizedText);

public static class DraftPolicy
{
    public const int MaximumTextLength = 4096;

    public static DraftDecision Classify(string? text, IReadOnlySet<string> allowedEmptyArtifacts)
    {
        if (text is null || text.Length > MaximumTextLength)
            return new(DraftState.Unreadable, null);
        if (text.Length == 0 || allowedEmptyArtifacts.Contains(text))
            return new(DraftState.Empty, string.Empty);
        return new(DraftState.Present, text);
    }
}
```

不得调用 `Trim`、`TrimStart`、`TrimEnd` 或 Unicode whitespace normalization。

- [ ] **Step 5: 实现 6 DIP 锁存手势**

`GestureDecision.cs`：

```csharp
namespace Ke.Windows.Core;

public readonly record struct DipPoint(double X, double Y);
public enum GestureDecision { Pending, Click, Drag }

public sealed class GestureTracker(DipPoint origin, double dragThreshold)
{
    private bool _dragging;

    public GestureDecision MoveTo(DipPoint point)
    {
        var dx = point.X - origin.X;
        var dy = point.Y - origin.Y;
        _dragging |= Math.Sqrt((dx * dx) + (dy * dy)) > dragThreshold;
        return _dragging ? GestureDecision.Drag : GestureDecision.Pending;
    }

    public GestureDecision Release() => _dragging ? GestureDecision.Drag : GestureDecision.Click;
}
```

- [ ] **Step 6: 运行 Core 测试**

Run: `dotnet test windows/tests/Ke.Windows.Core.Tests/Ke.Windows.Core.Tests.csproj -c Release`

Expected: PASS；空字符串和唯一显式 artifact 接受，五类草稿拒绝，手势锁存通过。

- [ ] **Step 7: 提交**

```bash
git add windows/src/Ke.Windows.Core windows/tests/Ke.Windows.Core.Tests
git commit -m "feat(windows): Add core send safety models"
```

---

### Task 3: 建立专用 MTA 自动化线程和失败关闭的焦点快照

**Files:**
- Create: `windows/src/Ke.Windows.Automation/AutomationDispatcher.cs`
- Create: `windows/src/Ke.Windows.Automation/NativeMethods.cs`
- Create: `windows/src/Ke.Windows.Automation/IntegrityLevelReader.cs`
- Create: `windows/src/Ke.Windows.Automation/UiAutomationTreeReader.cs`
- Create: `windows/src/Ke.Windows.Automation/FocusSnapshotProvider.cs`
- Create: `windows/tests/Ke.Windows.Automation.Tests/AutomationDispatcherTests.cs`
- Create: `windows/tests/Ke.Windows.Automation.Tests/FocusSnapshotProviderTests.cs`

**Interfaces:**
- Consumes: `ElementSummary`, `FocusSnapshot`, `SendErrorCode`.
- Produces: `IAutomationDispatcher.InvokeAsync<T>(Func<CancellationToken,T>, CancellationToken)`、`IFocusSnapshotProvider.Capture(CancellationToken)`、`CaptureResult`。

- [ ] **Step 1: 写入线程、边界与完整性级别失败测试**

```csharp
[Fact]
public async Task Dispatcher_runs_serially_on_one_MTA_thread()
{
    using var dispatcher = new AutomationDispatcher();
    var first = await dispatcher.InvokeAsync(
        _ => (Environment.CurrentManagedThreadId, Thread.CurrentThread.GetApartmentState()),
        CancellationToken.None);
    var second = await dispatcher.InvokeAsync(
        _ => (Environment.CurrentManagedThreadId, Thread.CurrentThread.GetApartmentState()),
        CancellationToken.None);
    Assert.Equal(first.Item1, second.Item1);
    Assert.Equal(ApartmentState.MTA, first.Item2);
}

[Fact]
public void Elevated_target_is_rejected_before_UIA_read()
{
    var uia = new FakeUiAutomationReader { ThrowIfCalled = true };
    var provider = new FocusSnapshotProvider(
        new FakeForegroundReader((nint)12, 99, "Code.exe"),
        new FakeIntegrityReader(sourceRid: 0x2000, targetRid: 0x3000),
        uia);
    var result = provider.Capture(CancellationToken.None);
    Assert.Equal(SendErrorCode.ElevatedTarget, result.Error);
    Assert.Equal(0, uia.CallCount);
}

[Theory]
[InlineData(31, 1)]
[InlineData(1, 513)]
public void Traversal_over_limit_fails_closed(int depth, int count)
{
    var result = BoundedTreeFixture.Read(depth, count, textLength: 0);
    Assert.Equal(SendErrorCode.AutomationUnavailable, result.Error);
}

[Fact]
public void Missing_runtime_id_fails_closed()
{
    var result = BoundedTreeFixture.Read(depth: 2, count: 2, textLength: 0, runtimeId: "");
    Assert.Equal(SendErrorCode.AutomationUnavailable, result.Error);
}
```

- [ ] **Step 2: 运行 Automation 测试并确认失败**

Run: `dotnet test windows/tests/Ke.Windows.Automation.Tests/Ke.Windows.Automation.Tests.csproj -c Release`

Expected: FAIL，缺少 dispatcher、provider 和 fixture reader 类型。

- [ ] **Step 3: 实现单线程 dispatcher**

`AutomationDispatcher` 使用一个 `BlockingCollection<IWorkItem>` 和后台 `Thread`。构造函数在 `Start()` 前调用 `SetApartmentState(ApartmentState.MTA)`；`InvokeAsync` 将工作放入队列并以 `TaskCompletionSource<T>(RunContinuationsAsynchronously)` 返回结果。工作开始前检查 cancellation token；`Dispose` 调用 `CompleteAdding()`、`Join(TimeSpan.FromSeconds(5))`，超时抛出 `InvalidOperationException`。队列拒绝后续工作，不创建替代线程。

公开接口固定为：

```csharp
public interface IAutomationDispatcher : IDisposable
{
    Task<T> InvokeAsync<T>(Func<CancellationToken, T> work, CancellationToken cancellationToken);
}

public sealed class AutomationDispatcher : IAutomationDispatcher
{
    public Task<T> InvokeAsync<T>(Func<CancellationToken, T> work, CancellationToken cancellationToken);
    public void Dispose();
}
```

- [ ] **Step 4: 实现 Win32 前台进程与 integrity level 读取**

`NativeMethods.cs` 只声明以下 API 与常量：

```csharp
[DllImport("user32.dll")] internal static extern nint GetForegroundWindow();
[DllImport("user32.dll")] internal static extern uint GetWindowThreadProcessId(nint hwnd, out uint processId);
[DllImport("kernel32.dll", SetLastError = true)] internal static extern nint OpenProcess(uint access, bool inheritHandle, uint processId);
[DllImport("kernel32.dll", SetLastError = true)] internal static extern bool QueryFullProcessImageName(nint process, uint flags, StringBuilder path, ref uint size);
[DllImport("advapi32.dll", SetLastError = true)] internal static extern bool OpenProcessToken(nint process, uint access, out nint token);
[DllImport("advapi32.dll", SetLastError = true)] internal static extern bool GetTokenInformation(nint token, int tokenInformationClass, nint information, uint length, out uint returnLength);
[DllImport("advapi32.dll")] internal static extern nint GetSidSubAuthority(nint sid, uint index);
[DllImport("advapi32.dll")] internal static extern nint GetSidSubAuthorityCount(nint sid);
[DllImport("kernel32.dll")] internal static extern bool CloseHandle(nint handle);
```

`IntegrityLevelReader` 使用 `TokenIntegrityLevel = 25`，读取 SID 最后一个 sub-authority RID；任何 API 失败返回 `CaptureResult.Failure(AutomationUnavailable)`。先取得源/目标 RID，只有 `targetRid <= sourceRid` 才允许调用 `AutomationElement.FocusedElement`。

- [ ] **Step 5: 实现有界 UIA 树读取与快照**

`UiAutomationTreeReader`：

- 调用 `AutomationElement.FocusedElement` 一次。
- 读取 focused element 的 `GetRuntimeId()`，以 `.` 连接成 `RuntimeId`；空数组拒绝。
- 用 `TreeWalker.ControlViewWalker.GetParent` 向上读取，最多 30 层；同时读取焦点路径每层的有界 Control View 子节点作为 `Nearby`，focused、ancestors、nearby 总计最多 512 个元素。达到深度/总数上限且仍有未访问节点时拒绝。
- 对 focused element 优先读取 `ValuePattern.Value`，否则读取 `TextPattern.DocumentRange.GetText(4097)`；长度 4097 时拒绝。
- 所有属性使用 `GetCurrentPropertyValue(property, true)`；`AutomationElement.NotSupported`、`ElementNotAvailableException`、`COMException`、`InvalidOperationException` 转为 `AutomationUnavailable`。
- 每次系统调用前后检查 cancellation token；取消时返回 `AutomationTimeout`。

公开结果类型固定为：

```csharp
public sealed record CaptureResult(FocusSnapshot? Snapshot, SendErrorCode? Error)
{
    public static CaptureResult Success(FocusSnapshot snapshot) => new(snapshot, null);
    public static CaptureResult Failure(SendErrorCode error) => new(null, error);
}

public interface IFocusSnapshotProvider
{
    CaptureResult Capture(CancellationToken cancellationToken);
}
```

`FocusSnapshotProvider.Capture` 顺序固定为 HWND、PID、映像名、完整性级别、UIA focused element；映像名只保留 `Path.GetFileName`，不保存完整路径或窗口标题。

- [ ] **Step 6: 运行边界测试**

Run: `dotnet test windows/tests/Ke.Windows.Automation.Tests/Ke.Windows.Automation.Tests.csproj -c Release --filter "AutomationDispatcherTests|FocusSnapshotProviderTests"`

Expected: PASS；同一 MTA thread id、深度/数量/文本/runtime id 边界、安全拒绝高完整性目标全部通过。

- [ ] **Step 7: 提交**

```bash
git add windows/src/Ke.Windows.Automation windows/tests/Ke.Windows.Automation.Tests
git commit -m "feat(windows): Capture bounded focused UIA snapshots"
```

---

### Task 4: 采集去标识化实机 fixture 并锁定 Codex/VS Code 适配器

**Files:**
- Create: `windows/tests/Ke.Windows.Automation.Tests/LiveFixtureCaptureTests.cs`
- Create: `windows/tests/Ke.Windows.Automation.Tests/FixtureSanitizer.cs`
- Create: `windows/tests/Ke.Windows.Automation.Tests/Fixtures/*.json`
- Create: `windows/fixtures/codex-chat-empty.json`
- Create: `windows/fixtures/codex-negative.json`
- Create: `windows/fixtures/vscode-chat-empty.json`
- Create: `windows/fixtures/vscode-negative.json`
- Create: `windows/src/Ke.Windows.Automation/AdapterProfiles.cs`
- Create: `windows/src/Ke.Windows.Automation/ProfileTargetAdapter.cs`
- Create: `windows/src/Ke.Windows.Automation/TargetAdapterRegistry.cs`
- Create: `windows/tests/Ke.Windows.Automation.Tests/TargetAdapterRegistryTests.cs`

**Interfaces:**
- Consumes: `IFocusSnapshotProvider`, `FocusSnapshot`, `DraftPolicy`.
- Produces: four sanitized live fixture files; `ITargetAdapter.Classify(FocusSnapshot, ComposerExpectation)`; `TargetAdapterRegistry.Classify(FocusSnapshot)`; `TargetClassification`.

- [ ] **Step 1: 实现只读延时 fixture 捕获测试**

测试只在 `KE_CAPTURE_FIXTURE` 指向输出文件时运行；否则 `[Fact(Skip = "Set KE_CAPTURE_FIXTURE for interactive capture")]`。运行时读取 `KE_EXPECT_PROCESS` 和 `KE_CAPTURE_SCENARIO`，等待 5 秒让操作者切换焦点，调用真实 provider，一旦进程名不匹配立即失败。

`FixtureSanitizer` 只输出以下结构：

```csharp
public sealed record SanitizedFixture(
    string Application,
    string ProcessImageName,
    string Scenario,
    SanitizedElement Focused,
    IReadOnlyList<SanitizedElement> Ancestors,
    IReadOnlyList<SanitizedElement> Nearby);

public sealed record SanitizedElement(
    string ControlType,
    string ClassName,
    string AutomationId,
    IReadOnlyList<string> GenericRoleTokens,
    bool IsEnabled,
    bool IsKeyboardFocusable,
    bool IsPassword,
    bool IsReadOnly,
    string TextShape,
    string? EmptyArtifactUtf16Hex);
```

`TextShape` 只能是 `empty`、`contenteditable-break`、`non-empty`；`GenericRoleTokens` 只保留小写 allow-list `chat`、`conversation`、`composer`、`message`、`copilot`、`editor`、`terminal`、`search`、`settings`、`command palette`、`quick open`、`approval`、`聊天`、`对话`、`消息`、`编辑器`、`终端`、`搜索`、`设置`、`命令面板`、`快速打开`、`审批`。不输出 runtime id、name 原文、标题、路径或文本。

`EmptyArtifactUtf16Hex` 只允许 `""`、`"000A"`、`"000D000A"`；遇到其他内容必须为 null 且 `TextShape=non-empty`，避免把用户内容编码进 fixture。适配器只把经该 allow-list 验证和解码的值加入 `AllowedEmptyArtifacts`。

- [ ] **Step 2: 在 Windows 11 实机采集四个 fixture**

每次捕获开始后 5 秒内切换到终端提示指定的控件。负向文件使用 JSON array 追加多个场景：

```powershell
function Capture-KeFixture {
    param([string]$Output, [string]$Process, [string]$Scenario, [bool]$Append)
    Read-Host "Focus $Process scenario '$Scenario', then press Enter"
    $env:KE_CAPTURE_FIXTURE = $Output
    $env:KE_EXPECT_PROCESS = $Process
    $env:KE_CAPTURE_SCENARIO = $Scenario
    $env:KE_CAPTURE_APPEND = if ($Append) { '1' } else { '0' }
    dotnet test windows/tests/Ke.Windows.Automation.Tests/Ke.Windows.Automation.Tests.csproj -c Release --filter LiveFixtureCaptureTests
    if ($LASTEXITCODE -ne 0) { throw "Fixture capture failed: $Process/$Scenario" }
}

Capture-KeFixture 'windows/fixtures/codex-chat-empty.json' 'Codex.exe' 'chat-empty' $false
$append = $false
foreach ($scenario in @('terminal', 'search', 'settings', 'approval')) {
    Capture-KeFixture 'windows/fixtures/codex-negative.json' 'Codex.exe' $scenario $append
    $append = $true
}

Capture-KeFixture 'windows/fixtures/vscode-chat-empty.json' 'Code.exe' 'chat-empty' $false
$append = $false
foreach ($scenario in @('editor', 'terminal', 'search', 'settings', 'command-palette', 'quick-open')) {
    Capture-KeFixture 'windows/fixtures/vscode-negative.json' 'Code.exe' $scenario $append
    $append = $true
}
```

Expected: 四个 JSON 文件不含窗口标题、路径、账号、runtime id 或消息文本；正向 fixture 含至少一个 chat-role token，负向 fixture 含对应 deny token。将副本放到测试项目 `Fixtures/` 并在 csproj 以 `CopyToOutputDirectory=PreserveNewest` 加入。

捕获测试对 `chat-empty` 写单个 JSON object；对其他 scenario 写 JSON array，`KE_CAPTURE_APPEND=0` 创建首项，`1` 原子追加。`FixtureLoader` 为测试快照注入确定性的 `RuntimeId = "fixture.<application>.<scenario>"`，不把该测试 id 写回 fixture。

- [ ] **Step 3: 先根据 fixture 写适配器失败测试**

```csharp
[Theory]
[InlineData("Fixtures/codex-chat-empty.json", SupportedApplication.Codex)]
[InlineData("Fixtures/vscode-chat-empty.json", SupportedApplication.VisualStudioCode)]
public void Captured_chat_composer_is_accepted(string path, SupportedApplication app)
{
    var snapshot = FixtureLoader.Load(path);
    var result = TargetAdapterRegistry.CreateDefault().Classify(snapshot);
    Assert.Equal(app, result.Match!.Application);
    Assert.Equal(string.Empty, result.Match.NormalizedText);
}

[Theory]
[InlineData("Fixtures/codex-negative.json")]
[InlineData("Fixtures/vscode-negative.json")]
public void Captured_negative_controls_are_rejected(string path)
{
    foreach (var snapshot in FixtureLoader.LoadMany(path))
        Assert.Equal(SendErrorCode.NotChatComposer,
            TargetAdapterRegistry.CreateDefault().Classify(snapshot).Error);
}

[Fact]
public void Known_process_never_uses_another_adapter()
{
    var codex = FixtureLoader.Load("Fixtures/codex-chat-empty.json") with
    {
        ProcessImageName = "Code.exe"
    };
    Assert.Equal(SendErrorCode.NotChatComposer,
        TargetAdapterRegistry.CreateDefault().Classify(codex).Error);
}
```

- [ ] **Step 4: 运行测试并确认适配器不存在**

Run: `dotnet test windows/tests/Ke.Windows.Automation.Tests/Ke.Windows.Automation.Tests.csproj -c Release --filter TargetAdapterRegistryTests`

Expected: FAIL，缺少 registry、profile adapter、fixture loader 类型。

- [ ] **Step 5: 实现 fixture 驱动但失败优先的适配器**

公开契约：

```csharp
public sealed record TargetMatch(
    SupportedApplication Application,
    string NormalizedText,
    TargetIdentity Identity);

public sealed record TargetClassification(TargetMatch? Match, SendErrorCode? Error);

public interface ITargetAdapter
{
    string ProcessImageName { get; }
    TargetClassification Classify(FocusSnapshot snapshot, ComposerExpectation expectation);
}

public enum ComposerExpectation { Empty, Approval }
```

`AdapterProfiles` 固定两组规则：

```csharp
internal static readonly AdapterProfile Codex = new(
    "Codex.exe", SupportedApplication.Codex,
    FocusedSignatures: SignaturesFrom("codex-chat-empty.json"),
    PositiveTokens: ["chat", "conversation", "composer", "message", "聊天", "对话", "消息"],
    NegativeTokens: ["editor", "terminal", "search", "settings", "approval", "编辑器", "终端", "搜索", "设置", "审批"],
    AllowedEmptyArtifacts: ArtifactsFrom("codex-chat-empty.json"));

internal static readonly AdapterProfile VisualStudioCode = new(
    "Code.exe", SupportedApplication.VisualStudioCode,
    FocusedSignatures: SignaturesFrom("vscode-chat-empty.json"),
    PositiveTokens: ["chat", "copilot", "composer", "message", "聊天", "对话", "消息"],
    NegativeTokens: ["editor", "terminal", "search", "settings", "command palette", "quick open", "编辑器", "终端", "搜索", "设置", "命令面板", "快速打开"],
    AllowedEmptyArtifacts: ArtifactsFrom("vscode-chat-empty.json"));
```

`FocusedSignatures` 是正向实机 fixture 中 `(ControlType, ClassName, AutomationId)` 的精确三元组。Automation 项目把两个 `*-chat-empty.json` 以 `EmbeddedResource` 编译进 DLL，启动时只从 assembly resource 读取已审查 profile，不访问用户目录。

`Ke.Windows.Automation.csproj` 增加：

```xml
<ItemGroup>
  <EmbeddedResource Include="..\..\fixtures\codex-chat-empty.json" Link="Profiles\codex-chat-empty.json" />
  <EmbeddedResource Include="..\..\fixtures\vscode-chat-empty.json" Link="Profiles\vscode-chat-empty.json" />
</ItemGroup>
```

`ProfileTargetAdapter.Classify` 顺序固定：精确进程名；focused `(ControlType, ClassName, AutomationId)` 命中本应用 `FocusedSignatures`；enabled、keyboard-focusable、非 password、非 read-only；`Ancestors + Nearby` 任一 deny token 立即拒绝；至少一个 allow token。`ComposerExpectation.Empty` 调用 `DraftPolicy.Classify`：`Unreadable` 返回 `AutomationUnavailable`，`Present` 返回 `DraftPresent`。`ComposerExpectation.Approval` 只接受 raw text 严格等于 `ProductInfo.ApprovalText`。成功返回带四字段 `TargetIdentity` 的 match。

`TargetAdapterRegistry.Classify(snapshot)` 是 `ComposerExpectation.Empty` 的快捷入口；`Validate(snapshot, expectation)` 支持第三次 approval 复核。registry 对 `Codex.exe` 和 `Code.exe` 只调用对应 adapter；其他进程返回 `UnsupportedApplication`，不提供通用回退。

- [ ] **Step 6: 运行 fixture 与负向测试**

Run: `dotnet test windows/tests/Ke.Windows.Automation.Tests/Ke.Windows.Automation.Tests.csproj -c Release --filter TargetAdapterRegistryTests`

Expected: PASS；两个正向 fixture 接受，所有负向场景拒绝，错配进程不回退。

- [ ] **Step 7: 提交**

```bash
git add windows/fixtures windows/src/Ke.Windows.Automation windows/tests/Ke.Windows.Automation.Tests
git commit -m "feat(windows): Add fixture-backed chat adapters"
```

---

### Task 5: 实现写入复核与一次性 Enter 状态机

**Files:**
- Create: `windows/src/Ke.Windows.Automation/WindowsInputWriter.cs`
- Create: `windows/src/Ke.Windows.Automation/FocusedChatSender.cs`
- Create: `windows/tests/Ke.Windows.Automation.Tests/FocusedChatSenderTests.cs`
- Create: `windows/tests/Ke.Windows.Automation.Tests/WindowsInputWriterTests.cs`

**Interfaces:**
- Consumes: `IFocusSnapshotProvider`、`TargetAdapterRegistry`、`ProductInfo.ApprovalText`、`TargetIdentity`。
- Produces: `IWindowsInputWriter`、`IFocusedChatSender.TrySend(CancellationToken)`。

- [ ] **Step 1: 写入状态机失败测试**

使用 fake provider/writer 精确记录副作用：

```csharp
[Fact]
public void Empty_stable_target_writes_once_and_enters_once()
{
    var sender = SenderFixture.StableEmptyThenApproval();
    Assert.True(sender.Subject.TrySend(CancellationToken.None).IsSuccess);
    Assert.Equal(["write:可", "enter"], sender.Writer.Events);
}

[Theory]
[InlineData("hwnd")]
[InlineData("pid")]
[InlineData("runtime")]
[InlineData("app")]
[InlineData("draft")]
public void Changed_target_never_writes_or_enters(string mutation)
{
    var sender = SenderFixture.WithSecondCaptureMutation(mutation);
    Assert.Equal(SendErrorCode.TargetChanged,
        sender.Subject.TrySend(CancellationToken.None).Error);
    Assert.Empty(sender.Writer.Events);
}

[Fact]
public void Unconfirmed_write_never_enters()
{
    var sender = SenderFixture.WriteDoesNotAppear();
    Assert.Equal(SendErrorCode.WriteUnconfirmed,
        sender.Subject.TrySend(CancellationToken.None).Error);
    Assert.Equal(["write:可"], sender.Writer.Events);
}

[Fact]
public void Cancellation_before_each_side_effect_prevents_enter()
{
    var sender = SenderFixture.CancelAfterWrite();
    Assert.Equal(SendErrorCode.AutomationTimeout,
        sender.Subject.TrySend(sender.Token).Error);
    Assert.Equal(["write:可"], sender.Writer.Events);
}

[Fact]
public void Enter_failure_is_not_retried()
{
    var sender = SenderFixture.EnterFails();
    Assert.Equal(SendErrorCode.ReturnDeliveryFailed,
        sender.Subject.TrySend(CancellationToken.None).Error);
    Assert.Equal(1, sender.Writer.EnterAttempts);
}
```

- [ ] **Step 2: 运行测试并确认 sender 不存在**

Run: `dotnet test windows/tests/Ke.Windows.Automation.Tests/Ke.Windows.Automation.Tests.csproj -c Release --filter "FocusedChatSenderTests|WindowsInputWriterTests"`

Expected: FAIL，缺少 sender 与 input writer。

- [ ] **Step 3: 实现 writer 的 ValuePattern/SendInput 路径**

契约：

```csharp
public enum TextWriteMethod { ValuePattern, UnicodeSendInput }
public sealed record TextWriteResult(bool IsSuccess, TextWriteMethod? Method);

public interface IWindowsInputWriter
{
    bool AreModifierKeysReleased();
    TextWriteResult WriteApproval(TargetIdentity expected, CancellationToken cancellationToken);
    bool SendEnter(TargetIdentity expected, CancellationToken cancellationToken);
}
```

真实 writer 在每次副作用前检查 cancellation token、前台 HWND/PID 与 `expected` 相同。`WriteApproval` 再取一次当前 focused `AutomationElement` 并要求 runtime id 与 `expected.RuntimeId` 相同；支持且可写 `ValuePattern` 时调用 `SetValue("可")`，否则发送两个 `INPUT`，分别为 Unicode `可` key-down 与 `KEYEVENTF_UNICODE | KEYEVENTF_KEYUP`。`SendEnter` 再检查前台 HWND/PID 与修饰键，然后发送 `VK_RETURN` key-down/key-up 两个 `INPUT`，要求 `SendInput` 返回 2。修饰键使用 `GetAsyncKeyState` 检查 `VK_CONTROL`、`VK_MENU`、`VK_SHIFT`、`VK_LWIN`、`VK_RWIN` 的高位；任一按下返回 false。不读取或写入剪贴板。

- [ ] **Step 4: 实现 sender 严格顺序**

`IFocusedChatSender`：

```csharp
public interface IFocusedChatSender
{
    SendResult TrySend(CancellationToken cancellationToken);
}
```

`FocusedChatSender.TrySend` 伪代码必须逐行落实，不合并复核：

```csharp
var first = CaptureAndClassify();
if (first failed) return failure;
CheckCancellation();
var second = CaptureAndClassify();
if (second failed or identity/app/text differ) return TargetChanged;
if (!writer.AreModifierKeysReleased()) return ModifierKeyDown;
CheckCancellation();
if (!writer.WriteApproval(second.Identity, cancellationToken).IsSuccess) return WriteUnconfirmed;
CheckCancellation();
var third = CaptureAndClassifyExpectedApproval();
if (third identity differs || third raw text != "可") return WriteUnconfirmed;
if (!writer.AreModifierKeysReleased()) return ModifierKeyDown;
CheckCancellation();
return writer.SendEnter(third.Identity, cancellationToken) ? Success : ReturnDeliveryFailed;
```

第三次捕获调用 registry `Validate(snapshot, ComposerExpectation.Approval)`；它先用相同 adapter 验证控件角色、deny 证据和 identity，再要求 raw text 严格等于 `ProductInfo.ApprovalText`。所有 cancellation check 返回 `AutomationTimeout`。任何异常映射 `AutomationUnavailable`；不得重试写入或 Enter。

- [ ] **Step 5: 运行发送安全测试**

Run: `dotnet test windows/tests/Ke.Windows.Automation.Tests/Ke.Windows.Automation.Tests.csproj -c Release --filter "FocusedChatSenderTests|WindowsInputWriterTests"`

Expected: PASS；成功路径一写一 Enter，所有竞态/修饰键/确认失败路径 Enter 次数为 0，Enter 失败次数为 1。

- [ ] **Step 6: 提交**

```bash
git add windows/src/Ke.Windows.Automation windows/tests/Ke.Windows.Automation.Tests
git commit -m "feat(windows): Send approval through guarded input pipeline"
```

---

### Task 6: 实现不抢焦点的悬浮窗口、拖动与位置恢复

**Files:**
- Create: `windows/src/Ke.Windows.Core/PanelPlacement.cs`
- Create: `windows/src/Ke.Windows.App/App.xaml`
- Create: `windows/src/Ke.Windows.App/App.xaml.cs`
- Create: `windows/src/Ke.Windows.App/MainWindow.xaml`
- Create: `windows/src/Ke.Windows.App/MainWindow.xaml.cs`
- Create: `windows/src/Ke.Windows.App/PanelPositionStore.cs`
- Create: `windows/src/Ke.Windows.App/SingleInstanceGuard.cs`
- Create: `windows/tests/Ke.Windows.Core.Tests/PanelPositionMathTests.cs`

**Interfaces:**
- Consumes: `GestureTracker`、`DipPoint`。
- Produces: non-activating WPF shell；`PanelPositionStore.Load/Save`；每登录会话单实例。

- [ ] **Step 1: 写入位置数学失败测试**

将纯值位置换算放入 Core 的 `PanelPlacement`：

```csharp
[Fact]
public void Restored_position_is_clamped_inside_work_area()
{
    var result = PanelPlacement.Restore(
        new SavedPanelPosition("DISPLAY1", 96, 1.4, -0.5),
        new WorkArea(100, 100, 1200, 800, 144),
        panelWidth: 64, panelHeight: 64);
    Assert.InRange(result.X, 100, 1236);
    Assert.InRange(result.Y, 100, 836);
}

[Fact]
public void Save_uses_relative_work_area_coordinates()
{
    var saved = PanelPlacement.Save("DISPLAY1", 144,
        new DipPoint(700, 500), new WorkArea(100, 100, 1200, 800, 144));
    Assert.Equal(0.5, saved.RelativeX, 3);
    Assert.Equal(0.5, saved.RelativeY, 3);
}
```

- [ ] **Step 2: 运行测试并确认位置类型不存在**

Run: `dotnet test windows/tests/Ke.Windows.Core.Tests/Ke.Windows.Core.Tests.csproj -c Release --filter PanelPositionMathTests`

Expected: FAIL，缺少 `PanelPlacement`、`SavedPanelPosition`、`WorkArea`。

- [ ] **Step 3: 实现多显示器位置纯值换算**

`PanelPlacement.Save` 记录 device name、DPI、窗口左上角相对 work-area 的比例；`Restore` 使用当前 work-area 和 DPI 计算 DIP 坐标，并将完整 64 × 64 窗口夹紧到可见范围。找不到原 device name 时使用当前 cursor 所在 monitor；JSON 路径固定 `%LOCALAPPDATA%\Ke\settings.json`，写入使用临时文件后 `File.Move(temp, target, true)` 原子替换。解析错误时返回默认右下角内缩 24 DIP，不删除损坏文件。

- [ ] **Step 4: 实现 Apple 风格克制悬浮按钮**

`MainWindow.xaml` 根 Window 固定：

```xml
<Window x:Class="Ke.Windows.App.MainWindow"
        Width="64" Height="64" WindowStyle="None" ResizeMode="NoResize"
        AllowsTransparency="True" Background="Transparent" Topmost="True"
        ShowActivated="False" ShowInTaskbar="False" Focusable="False">
  <Grid>
    <Border x:Name="Disc" CornerRadius="32" Background="#1E1E1F"
            BorderBrush="#55D6BE" BorderThickness="2">
      <TextBlock x:Name="Glyph" Text="可" Foreground="#F6F7F8"
                 FontFamily="Microsoft YaHei UI" FontSize="27" FontWeight="SemiBold"
                 HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
  </Grid>
</Window>
```

`SourceInitialized` 后读取并写回 extended style `WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW`；`HwndSource.AddHook` 对 `WM_MOUSEACTIVATE` 返回 `MA_NOACTIVATE`。左键按下创建 `GestureTracker` 并保存 cursor-to-window offset；移动超过 6 DIP 后按 offset 拖动；松开只有 `GestureDecision.Click` 才触发 `SendRequested`。右键 ContextMenu 只有“关于”和“退出”。

- [ ] **Step 5: 实现单实例生命周期**

`SingleInstanceGuard` 使用：

```csharp
new Mutex(initiallyOwned: true, "Local\\Ke.Windows.SingleInstance", out bool createdNew)
```

`createdNew == false` 时 `App.OnStartup` 立即 `Shutdown(0)`；创建成功后保留 mutex 到 `OnExit`，再 `ReleaseMutex()` 和 `Dispose()`。不激活已有实例，不创建第二个窗口。

- [ ] **Step 6: 运行 Core 测试并手动验证窗口**

Run: `dotnet test windows/tests/Ke.Windows.Core.Tests/Ke.Windows.Core.Tests.csproj -c Release`

Expected: PASS。

Run: `dotnet run --project windows/src/Ke.Windows.App/Ke.Windows.App.csproj -c Debug`

Expected: 64 DIP 圆形按钮始终置顶；点击/拖动前后的记事本 caret 仍可输入；拖动不触发发送事件；第二次启动不出现第二个按钮；右键可退出。

- [ ] **Step 7: 提交**

```bash
git add windows/src/Ke.Windows.Core windows/src/Ke.Windows.App windows/tests/Ke.Windows.Core.Tests
git commit -m "feat(windows): Add non-activating floating button"
```

---

### Task 7: 连接 2.5 秒协调器、视觉反馈与无障碍通知

**Files:**
- Create: `windows/src/Ke.Windows.App/SendCoordinator.cs`
- Create: `windows/src/Ke.Windows.App/ButtonFeedbackController.cs`
- Create: `windows/src/Ke.Windows.App/KeButtonAutomationPeer.cs`
- Create: `windows/tests/Ke.Windows.Automation.Tests/SendCoordinatorTests.cs`
- Modify: `windows/tests/Ke.Windows.Automation.Tests/Ke.Windows.Automation.Tests.csproj`
- Modify: `windows/src/Ke.Windows.App/App.xaml.cs`
- Modify: `windows/src/Ke.Windows.App/MainWindow.xaml.cs`

**Interfaces:**
- Consumes: `IAutomationDispatcher`、`IFocusedChatSender`、`SendResult`。
- Produces: `SendCoordinator.TryStartAsync(Func<SendResult,Task>)`；待命/按下/成功/失败反馈；AutomationPeer name/status/notification。

- [ ] **Step 1: 写入 timeout 与单 in-flight 失败测试**

先给 Automation tests 项目增加 `Ke.Windows.App.csproj` 的 `ProjectReference`，使测试能直接构造 coordinator。

```csharp
[Fact]
public async Task Timeout_reports_once_but_holds_in_flight_until_worker_returns()
{
    var worker = new ControlledSender();
    var clock = new ManualDeadline();
    var reports = new List<SendResult>();
    var coordinator = new SendCoordinator(worker.Dispatcher, worker, clock);

    var running = coordinator.TryStartAsync(r => { reports.Add(r); return Task.CompletedTask; });
    clock.Expire();
    await clock.Reported;
    Assert.Equal(SendErrorCode.AutomationTimeout, Assert.Single(reports).Error);
    Assert.False(await coordinator.TryStartAsync(_ => Task.CompletedTask));

    worker.Return(SendResult.Success());
    await running;
    Assert.Single(reports);
    Assert.True(await coordinator.TryStartAsync(_ => Task.CompletedTask));
}
```

- [ ] **Step 2: 运行测试并确认 coordinator 不存在**

Run: `dotnet test windows/tests/Ke.Windows.Automation.Tests/Ke.Windows.Automation.Tests.csproj -c Release --filter SendCoordinatorTests`

Expected: FAIL，缺少 coordinator/deadline seam。

- [ ] **Step 3: 实现 coordinator**

`TryStartAsync` 用 `Interlocked.CompareExchange(ref _inFlight, 1, 0)` 拒绝并发尝试。创建 linked `CancellationTokenSource`，将 `sender.TrySend` 交给 dispatcher；与 `Task.Delay(TimeSpan.FromSeconds(2.5))` 竞速。若 delay 先完成：取消 token、立即只报告一次 `AutomationTimeout`、继续 await worker；worker 后续结果丢弃。只有 worker 真正返回才在 `finally` 把 `_inFlight` 置 0。若 worker 先完成：报告其结果并释放。所有 callback 切回 WPF Dispatcher。

- [ ] **Step 4: 实现状态颜色、时长和文案映射**

`ButtonFeedbackController` 固定映射：

```csharp
private static readonly IReadOnlyDictionary<SendErrorCode, string> Messages =
    new Dictionary<SendErrorCode, string>
    {
        [SendErrorCode.UnsupportedApplication] = "当前只支持 Codex 和 VS Code",
        [SendErrorCode.NotChatComposer] = "请先点击 Codex 或 VS Code 的聊天输入框",
        [SendErrorCode.DraftPresent] = "输入框已有内容，未发送",
        [SendErrorCode.TargetChanged] = "焦点已变化，未发送",
        [SendErrorCode.AutomationUnavailable] = "无法安全读取当前输入框",
        [SendErrorCode.AutomationTimeout] = "读取输入框超时，没有按回车",
        [SendErrorCode.ModifierKeyDown] = "请松开 Ctrl、Alt、Shift 或 Windows 键后重试",
        [SendErrorCode.ElevatedTarget] = "目标可能以管理员身份运行，未发送",
        [SendErrorCode.WriteUnconfirmed] = "写入未确认，没有按回车",
        [SendErrorCode.ReturnDeliveryFailed] = "无法发送回车，不会重试"
    };
```

按下缩放 96%；成功状态薄荷底/煤灰字/米白描边保持 650 ms；失败煤灰底/`#FF5A5F` 红环保持 900 ms，Tooltip 最多 2.5 秒。`SystemParameters.ClientAreaAnimation == false` 时不用 `DoubleAnimation` 或颜色过渡，只即时换色。

- [ ] **Step 5: 实现无障碍 peer**

`KeButtonAutomationPeer : FrameworkElementAutomationPeer`：`GetNameCore()` 返回“可”；`GetHelpTextCore()` 返回当前状态文案；成功或失败时调用 `RaiseNotificationEvent(AutomationNotificationKind.ActionCompleted, AutomationNotificationProcessing.ImportantMostRecent, message, "Ke.SendResult")`。状态变化后调用 `RaisePropertyChangedEvent(AutomationElementIdentifiers.HelpTextProperty, old, current)`。

- [ ] **Step 6: 组合真实服务并验证反馈**

`App.OnStartup` 依次创建 single-instance guard、`AutomationDispatcher`、`FocusSnapshotProvider`、default registry、`WindowsInputWriter`、`FocusedChatSender`、`SendCoordinator`、`MainWindow`。`App.OnExit` 先关闭窗口，再 dispose dispatcher 和 mutex。

Run: `dotnet test windows/Ke.Windows.slnx -c Release`

Expected: PASS。

手动把焦点放在记事本，点击按钮。Expected: 红环 900 ms，Tooltip“当前只支持 Codex 和 VS Code”，记事本焦点不变。

- [ ] **Step 7: 提交**

```bash
git add windows/src/Ke.Windows.App windows/tests/Ke.Windows.Automation.Tests
git commit -m "feat(windows): Connect send coordination and feedback"
```

---

### Task 8: 建立真实 WPF IntegrationHarness 和交互自动化边界测试

**Files:**
- Create: `windows/tests/Ke.Windows.IntegrationHarness/App.xaml`
- Create: `windows/tests/Ke.Windows.IntegrationHarness/App.xaml.cs`
- Create: `windows/tests/Ke.Windows.IntegrationHarness/MainWindow.xaml`
- Create: `windows/tests/Ke.Windows.IntegrationHarness/MainWindow.xaml.cs`
- Create: `windows/tests/Ke.Windows.Automation.Tests/IntegrationHarnessTests.cs`

**Interfaces:**
- Consumes: 真实 `FocusSnapshotProvider`、adapter、sender；登录桌面会话。
- Produces: 确定性的 Edit/Document/search/editor/terminal/password/read-only/disabled/focus-change 测试窗口。

- [ ] **Step 1: 构建语义明确的测试窗口**

Harness Window 提供九个控件，AutomationId 固定：

```xml
<StackPanel>
  <TextBox AutomationProperties.AutomationId="ChatEmpty" AutomationProperties.Name="Chat composer" />
  <RichTextBox AutomationProperties.AutomationId="DocumentEmpty" AutomationProperties.Name="Conversation composer" />
  <TextBox AutomationProperties.AutomationId="Search" AutomationProperties.Name="Search" />
  <TextBox AutomationProperties.AutomationId="Editor" AutomationProperties.Name="Text editor" />
  <TextBox AutomationProperties.AutomationId="Terminal" AutomationProperties.Name="Terminal" />
  <PasswordBox AutomationProperties.AutomationId="Password" />
  <TextBox AutomationProperties.AutomationId="ReadOnly" IsReadOnly="True" />
  <TextBox AutomationProperties.AutomationId="Disabled" IsEnabled="False" />
  <TextBox AutomationProperties.AutomationId="FocusChanges" AutomationProperties.Name="Chat composer" />
  <TextBlock x:Name="EnterCount" AutomationProperties.AutomationId="EnterCount" Text="0" />
</StackPanel>
```

Window preview key handler只在 ChatEmpty/DocumentEmpty 收到 Enter 时增加 `EnterCount`；`FocusChanges` 第一次文本变化后把焦点移到 Search，用于复核竞态。

- [ ] **Step 2: 写入登录桌面交互测试**

测试发现 `KE_RUN_INTERACTIVE_TESTS != "1"` 时显式 Skip；启用后启动 harness 进程，以 UIA 找到 AutomationId，依次聚焦并调用 sender。断言：

```csharp
Assert.True(Send("ChatEmpty").IsSuccess);
Assert.Equal("可", ReadValue("ChatEmpty"));
Assert.Equal("1", ReadName("EnterCount"));

foreach (var id in new[] { "Search", "Editor", "Terminal", "Password", "ReadOnly", "Disabled" })
{
    var before = ReadValueIfAvailable(id);
    Assert.False(Send(id).IsSuccess);
    Assert.Equal(before, ReadValueIfAvailable(id));
}

Assert.Equal(SendErrorCode.WriteUnconfirmed, Send("FocusChanges").Error);
Assert.Equal("1", ReadName("EnterCount"));
```

Harness 使用测试专用 `Ke.Windows.IntegrationHarness.exe` profile，不加入生产 registry；生产代码仍只支持 Codex/Code。测试结束 `CloseMainWindow()`，5 秒未退出时 `Kill(entireProcessTree: true)` 并使测试失败。

- [ ] **Step 3: 运行非交互与交互测试**

Run: `dotnet test windows/Ke.Windows.slnx -c Release`

Expected: PASS；交互集合显示 Skip，其他测试通过。

Run:

```powershell
$env:KE_RUN_INTERACTIVE_TESTS = "1"
dotnet test windows/tests/Ke.Windows.Automation.Tests/Ke.Windows.Automation.Tests.csproj -c Release --filter IntegrationHarnessTests
```

Expected: PASS；一个成功 Enter，六类负向控件零修改，焦点变化后零新增 Enter，无残留 harness 进程。

- [ ] **Step 4: 提交**

```bash
git add windows/tests/Ke.Windows.IntegrationHarness windows/tests/Ke.Windows.Automation.Tests
git commit -m "test(windows): Add interactive automation harness"
```

---

### Task 9: 生成品牌图标、便携构建与发布验证

**Files:**
- Create: `windows/src/Ke.Windows.App/Assets/App.ico`
- Create: `windows/scripts/build-portable.ps1`
- Create: `windows/scripts/verify-portable.ps1`
- Create: `windows/README.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: Windows 11 x64、.NET 10 SDK、全部非交互测试、仓库 LICENSE。
- Produces: `windows/dist/可-windows-x64.zip`、`windows/dist/可-windows-x64/可.exe`、SHA-256 清单。

- [ ] **Step 1: 写入失败的发布验证脚本**

`verify-portable.ps1` 参数和硬断言：

```powershell
param([Parameter(Mandatory=$true)][string]$DistDirectory)
$ErrorActionPreference = 'Stop'
$allowed = @('可.exe', 'README.md', 'LICENSE', 'SHA256SUMS.txt')
$actual = Get-ChildItem -LiteralPath $DistDirectory -File | Select-Object -ExpandProperty Name
if (Compare-Object $allowed $actual) { throw "Portable contents mismatch" }
$exe = Join-Path $DistDirectory '可.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw "可.exe missing" }
$bytes = [IO.File]::ReadAllBytes($exe)
if ($bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) { throw "Not a PE executable" }
$process = Start-Process -FilePath $exe -PassThru
Start-Sleep -Milliseconds 1200
$second = Start-Process -FilePath $exe -PassThru
Start-Sleep -Milliseconds 600
if (-not $second.HasExited) { throw "Second instance stayed alive" }
$process.CloseMainWindow() | Out-Null
Start-Sleep -Milliseconds 800
if (-not $process.HasExited) { $process.Kill(); throw "App did not exit cleanly" }
```

补充 PE parser 断言 Machine `0x8664`、Subsystem `2` (GUI)，Win32 version resource 的 ProductName 为“可”，group icon resource 非空；用 `Get-FileHash -Algorithm SHA256` 对照 `SHA256SUMS.txt`。任何失败 exit code 非 0。

- [ ] **Step 2: 先运行验证并确认发布物不存在**

Run: `pwsh windows/scripts/verify-portable.ps1 -DistDirectory windows/dist/可-windows-x64`

Expected: FAIL with `可.exe missing` 或目录不存在。

- [ ] **Step 3: 生成多尺寸 ICO**

创建一次性 PowerShell/.NET 绘制程序，输出 16、24、32、48、64、128、256 px PNG 帧：煤灰圆 `#1E1E1F`、2 px 等比薄荷环 `#55D6BE`、居中米白“可” `#F6F7F8`；再按 ICO directory entry 格式打包 PNG bytes 到 `Assets/App.ico`。每帧 width/height byte 对 256 使用 0，bit count 32，offset 累加准确。运行后提交生成的 ICO；构建不依赖 ImageMagick 或系统字体下载。

生成文件后在 `Ke.Windows.App.csproj` 加入：

```xml
<PropertyGroup>
  <ApplicationIcon>Assets\App.ico</ApplicationIcon>
  <Product>可</Product>
  <Description>向当前空聊天输入框安全发送“可”</Description>
  <Version>1.0.0</Version>
  <FileVersion>1.0.0.0</FileVersion>
  <AssemblyVersion>1.0.0.0</AssemblyVersion>
</PropertyGroup>
```

- [ ] **Step 4: 实现 build-portable.ps1**

脚本顺序固定：

```powershell
$ErrorActionPreference = 'Stop'
if (-not [Environment]::Is64BitOperatingSystem) { throw 'Windows x64 required' }
$os = [Environment]::OSVersion.Version
if ($os.Build -lt 22000) { throw 'Windows 11 required' }
$sdk = dotnet --version
if (-not $sdk.StartsWith('10.')) { throw '.NET 10 SDK required' }
dotnet test windows/Ke.Windows.slnx -c Release
dotnet publish windows/src/Ke.Windows.App/Ke.Windows.App.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:PublishTrimmed=false
```

然后清空并重建 `windows/dist/可-windows-x64/`，只复制重命名后的 `可.exe`、`windows/README.md`、根 `LICENSE`；生成只含 `可.exe` hash 的 `SHA256SUMS.txt`；以 `Compress-Archive` 创建 `可-windows-x64.zip`；最后调用 `verify-portable.ps1`。脚本删除的目标必须先解析并确认位于仓库 `windows/dist` 内，禁止对空路径、仓库根目录或用户目录递归删除。

- [ ] **Step 5: 编写 Windows 使用说明并更新根 README**

`windows/README.md` 必须写明：Windows 11 x64；解压运行 `可.exe`；只支持 Codex/VS Code 空聊天框；拖动、右键关于/退出；已有草稿和不确定目标闪红拒绝；管理员权限目标不支持；无全局快捷键/托盘/周额度；未签名版本可能出现 SmartScreen“未知发布者”；验证 SHA-256 的 PowerShell 命令；不提供绕过 SmartScreen 指令。

根 README 增加 macOS/Windows 两个安装入口，不改变现有 macOS 命令和权限说明。

- [ ] **Step 6: 构建并验证便携包**

Run: `pwsh windows/scripts/build-portable.ps1`

Expected: PASS；`可-windows-x64.zip` 存在；验证脚本确认 4 个允许文件、x64 GUI、图标/版本资源、单实例、干净退出、hash 匹配。

- [ ] **Step 7: 提交**

```bash
git add windows/src/Ke.Windows.App/Assets/App.ico windows/scripts windows/README.md README.md
git commit -m "build(windows): Package portable x64 release"
```

---

### Task 10: 完成 Codex/VS Code 实机验收与全仓回归

**Files:**
- Create: `windows/ACCEPTANCE.md`
- Modify: `windows/fixtures/*.json` only if current release changes sanitized stable evidence
- Modify: `windows/tests/Ke.Windows.Automation.Tests/Fixtures/*.json` only with the same reviewed fixture change

**Interfaces:**
- Consumes: 当前 Windows 11 x64 Codex、Visual Studio Code、便携 ZIP。
- Produces: 逐项带版本号和结果的验收记录；最终可发布 artifact。

- [ ] **Step 1: 在未预装 .NET 的 Windows 11 x64 测试机运行便携包**

解压 `可-windows-x64.zip`，核对 `Get-FileHash .\可.exe -Algorithm SHA256` 与清单一致，直接运行。记录 Windows build、Codex version、VS Code version、ZIP SHA-256；不得记录账号、路径、聊天标题或消息内容。

- [ ] **Step 2: 执行 Codex 验收矩阵**

逐项记录 PASS：空聊天框单击只出现一个“可”并只发送一次；已有草稿、普通空格、换行、搜索、设置、终端、原生审批全部闪红且内容不变；拖动不发送；快速连点不重复；焦点在点击前后仍属于 Codex 输入框；管理员权限 Codex 返回 `elevatedTarget`。

- [ ] **Step 3: 执行 Visual Studio Code 验收矩阵**

逐项记录 PASS：Chat/Copilot 空输入框单击只发送一次；已有草稿、代码编辑器、集成终端、搜索、设置、Command Palette、Quick Open 全部闪红且内容不变；拖动、连点、焦点保持、管理员权限目标同样通过。

- [ ] **Step 4: 执行 100 次稳定性循环**

Codex 50 次、VS Code 50 次，每次从空聊天框开始。验收计数：100 个“可”、100 次提交、0 次重复 Enter、0 次错误窗口写入、0 次悬浮窗抢焦点、退出后 0 个 `Ke.Windows.exe`/`可.exe` 残留进程。任一失败先保留不含用户数据的诊断代码，修复后重跑完整 100 次。

- [ ] **Step 5: 运行 Windows 全套验证**

```powershell
dotnet test windows/Ke.Windows.slnx -c Release
$env:KE_RUN_INTERACTIVE_TESTS = "1"
dotnet test windows/tests/Ke.Windows.Automation.Tests/Ke.Windows.Automation.Tests.csproj -c Release --filter IntegrationHarnessTests
pwsh windows/scripts/build-portable.ps1
pwsh windows/scripts/verify-portable.ps1 -DistDirectory windows/dist/可-windows-x64
```

Expected: 全部 PASS，0 warnings，0 残留进程。

- [ ] **Step 6: 运行现有 macOS 回归**

在 macOS 仓库根目录运行：

```bash
swift test
bash Tests/AppIconTests.sh
bash Tests/BuildReleaseTests.sh
bash Tests/PackagingTests.sh
bash Tests/SigningTests.sh
bash Tests/InstallLocalTests.sh
bash Tests/DouyinPosterTests.sh
```

Expected: 全部 PASS；Windows 目录未改变 Swift package、macOS 签名或现有海报 artifact。

- [ ] **Step 7: 写入验收记录并提交**

`windows/ACCEPTANCE.md` 只包含测试日期、系统/应用版本、每个矩阵项 PASS、100 次统计、ZIP SHA-256 和运行命令；不包含截图中的用户数据。

```bash
git add windows/ACCEPTANCE.md windows/fixtures windows/tests/Ke.Windows.Automation.Tests/Fixtures
git commit -m "test(windows): Record Windows 11 acceptance"
```

---

## 最终完成检查

- [ ] `git status --short` 只有明确准备提交的文件，最终为干净工作树。
- [ ] `rg -n "Trim\\(|Clipboard|SetForegroundWindow|AttachThreadInput" windows/src` 无输出。
- [ ] `rg -n "(Console|Debug|Trace|ILogger).*?(window title|message content|account|Text|Name)" windows/src` 无输出。
- [ ] 所有错误路径没有自动重试；Enter 测试精确断言 0 或 1 次。
- [ ] UIA 对象没有出现在 Core public API，也没有跨 dispatcher 回传。
- [ ] Windows 便携包、交互 harness、Codex/VS Code 实机矩阵、100 次循环和 macOS 回归全部通过。
