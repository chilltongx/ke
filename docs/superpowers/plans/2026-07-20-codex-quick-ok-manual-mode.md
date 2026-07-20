# Codex“可”手动模式 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让用户从 Dock 手动启动“Codex 可”，单击悬浮按钮后只向最近使用的 Codex 窗口空输入框写入一次“可”并自动发送。

**Architecture:** 用一个无会话状态的 `ManualApprovalController` 管理面板和单次发送锁；`SystemCodexAutomation` 只负责激活 Codex 并定位 focused window 中唯一的对话输入框；`ApprovalSender` 在前台 Bundle ID 和空草稿校验通过后写入并按一次发送按钮。`AppDelegate` 启动时无条件显示面板、移除旧登录项，并继续独立维护周额度客户端。

**Tech Stack:** Swift 6、Swift Package Manager、AppKit、ApplicationServices Accessibility、ServiceManagement、Foundation、XCTest、zsh、本地稳定代码签名。

## Global Constraints

- 最低系统版本保持 macOS 14.0。
- 目标 Codex Bundle ID 必须严格等于 `com.openai.codex`。
- 只操作 Accessibility focused window；不得使用会话 ID、任务 URL、标题或工作目录导航。
- 输入框去除空白后非空时拒绝发送，不覆盖也不追加。
- 每次点击最多写入一次“可”并执行一次发送动作；失败后不得自动重试。
- 不使用剪贴板、全局键盘模拟、屏幕录制、完全磁盘访问或管理员权限。
- 应用不注册登录项；仅注销本应用旧版留下的主应用登录项。
- 周额度缺失时光环保持灰色，但不得影响按钮可见性和发送能力。
- 保留 64 pt 悬浮按钮、5 pt 拖动阈值、位置恢复和 Reduce Motion 支持。
- 继续使用 `Codex Quick OK Local Signing`，Bundle ID 保持 `com.codexquickok.CodexQuickOK`。

---

## File Structure

```text
Sources/CodexQuickOKCore/SendSafety.swift
    当前 Codex Bundle ID 与空草稿的纯安全校验

Sources/CodexQuickOKApp/Automation/AccessibilityClient.swift
    激活 Codex，等待 focused window，并选择唯一对话输入框与发送按钮
Sources/CodexQuickOKApp/Automation/CurrentCodexAutomation.swift
    当前窗口自动化适配器；不包含任务导航
Sources/CodexQuickOKApp/Automation/CurrentWindowApprovalSender.swift
    防重入、校验、写入“可”、执行一次发送

Sources/CodexQuickOKApp/ManualApprovalController.swift
    面板显示、点击锁、成功/失败反馈、停止生命周期
Sources/CodexQuickOKApp/LoginItemManager.swift
    仅封装旧主应用登录项注销
Sources/CodexQuickOKApp/AppDelegate.swift
    手动启动装配、Dock reopen、额度生命周期
Sources/CodexQuickOKApp/UI/FloatingPanelController.swift
    常驻面板、清晰的隐藏菜单文案和无障碍反馈

Tests/CodexQuickOKCoreTests/SendSafetyTests.swift
    当前窗口安全门测试
Tests/CodexQuickOKAppTests/AccessibilityClientTests.swift
    focused window 控件定位测试
Tests/CodexQuickOKAppTests/CurrentWindowApprovalSenderTests.swift
    单次发送与失败不重试测试
Tests/CodexQuickOKAppTests/ManualApprovalControllerTests.swift
    手动显示、重复点击、反馈和 reopen 测试
Tests/CodexQuickOKAppTests/AppDelegateTests.swift
    手动生命周期、登录项迁移、额度和安全终止测试
Tests/CodexQuickOKAppTests/FakeCodexAutomation.swift
    新接口测试替身

Package.swift
scripts/build-release.sh
scripts/install-local.sh
scripts/uninstall-local.sh
Tests/PackagingTests.sh
Resources/Info.plist
README.md
docs/manual-verification.md
    无 Hook 的 build 4 打包、安装和验证路径
```

删除不再进入应用运行路径的文件：

```text
Sources/CodexQuickOKApp/AppController.swift
Sources/CodexQuickOKApp/Automation/ApprovalSender.swift
Sources/CodexQuickOKApp/Automation/CodexSessionNavigator.swift
Sources/CodexQuickOKApp/CodexProcessMonitor.swift
Sources/CodexQuickOKApp/SessionDirectoryMonitor.swift
Sources/CodexQuickOKHook/main.swift
plugin/codex-quick-ok/.codex-plugin/plugin.json
plugin/codex-quick-ok/hooks.json
marketplace/.agents/plugins/marketplace.json
Tests/CodexQuickOKAppTests/AppControllerTests.swift
Tests/CodexQuickOKAppTests/ApprovalSenderTests.swift
Tests/CodexQuickOKAppTests/FakeCodexAutomation.swift
```

保留 `CodexQuickOKCore` 中旧状态模型及其单元测试，避免本次交互改造扩大为无关的数据模型迁移；它们不再被应用 target 或安装流程调用。

---

### Task 1: 把安全门改为“当前 Codex + 空草稿”

**Files:**
- Modify: `Sources/CodexQuickOKCore/SendSafety.swift`
- Modify: `Tests/CodexQuickOKCoreTests/SendSafetyTests.swift`

**Interfaces:**
- Consumes: Codex Bundle ID 和当前 composer 字符串。
- Produces: `SendSafety.validate(bundleId:composerValue:) throws`。旧 session overload 只保留到 Task 3，使每个提交都能独立编译。

- [ ] **Step 1: 写失败测试**

把 `SendSafetyTests` 改为当前窗口契约：

```swift
import XCTest
@testable import CodexQuickOKCore

final class SendSafetyTests: XCTestCase {
    func testRejectsWrongApplication() {
        XCTAssertThrowsError(
            try SendSafety.validate(
                bundleId: "com.apple.TextEdit",
                composerValue: ""
            )
        ) { error in
            XCTAssertEqual(error as? SendSafetyError, .wrongApplication)
        }
    }

    func testRejectsExistingDraft() {
        XCTAssertThrowsError(
            try SendSafety.validate(
                bundleId: "com.openai.codex",
                composerValue: "draft"
            )
        ) { error in
            XCTAssertEqual(error as? SendSafetyError, .existingDraft)
        }
    }

    func testAcceptsEmptyOrWhitespaceOnlyComposer() {
        XCTAssertNoThrow(
            try SendSafety.validate(
                bundleId: "com.openai.codex",
                composerValue: ""
            )
        )
        XCTAssertNoThrow(
            try SendSafety.validate(
                bundleId: "com.openai.codex",
                composerValue: " \n\t"
            )
        )
    }

    func testProvidesUserFacingFailureMessages() {
        XCTAssertEqual(
            SendSafetyError.wrongApplication.errorDescription,
            "无法确认当前窗口属于 Codex"
        )
        XCTAssertEqual(
            SendSafetyError.existingDraft.errorDescription,
            "检测到未发送草稿"
        )
    }
}
```

- [ ] **Step 2: 运行测试并确认因旧接口失败**

Run:

```bash
swift test --filter SendSafetyTests
```

Expected: FAIL，编译器报告 `missing argument for parameter 'sessionMatched'`，并报告旧错误未实现 `errorDescription`。

- [ ] **Step 3: 写最小实现**

```swift
import Foundation

public enum SendSafetyError: Error, Equatable, LocalizedError {
    case wrongApplication
    case sessionMismatch
    case existingDraft

    public var errorDescription: String? {
        switch self {
        case .wrongApplication:
            "无法确认当前窗口属于 Codex"
        case .sessionMismatch:
            "无法确认目标 Codex 任务"
        case .existingDraft:
            "检测到未发送草稿"
        }
    }
}

public enum SendSafety {
    public static func validate(
        bundleId: String?,
        composerValue: String
    ) throws {
        guard bundleId == "com.openai.codex" else {
            throw SendSafetyError.wrongApplication
        }
        guard composerValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw SendSafetyError.existingDraft
        }
    }

    @available(*, deprecated, message: "Use current-window validation")
    public static func validate(
        bundleId: String?,
        sessionMatched: Bool,
        composerValue: String
    ) throws {
        guard sessionMatched else { throw SendSafetyError.sessionMismatch }
        try validate(bundleId: bundleId, composerValue: composerValue)
    }
}
```

- [ ] **Step 4: 运行安全门测试**

Run:

```bash
swift test --filter SendSafetyTests
```

Expected: PASS，4 tests，0 failures；旧调用点通过临时 overload 继续编译。

- [ ] **Step 5: 提交**

```bash
git add Sources/CodexQuickOKCore/SendSafety.swift \
  Tests/CodexQuickOKCoreTests/SendSafetyTests.swift
git commit -m "ref(safety): Validate current Codex composer"
```

---

### Task 2: 增加 focused window 对话定位

**Files:**
- Modify: `Sources/CodexQuickOKApp/Automation/AccessibilityClient.swift`
- Create: `Tests/CodexQuickOKAppTests/AccessibilityClientTests.swift`
- Modify: `Tests/CodexQuickOKAppTests/FakeCodexAutomation.swift`

**Interfaces:**
- Consumes: Accessibility focused window tree。
- Produces: `AccessibilityControlling.waitForFocusedConversation(timeout:)` 和缓存的唯一 composer/send button，供 Task 3 使用。

- [ ] **Step 1: 写 focused window 选择失败测试**

在新文件中用一个 sidebar 搜索框和一个 main composer 证明只选主对话区：

```swift
import AppKit
import XCTest
@testable import CodexQuickOKApp

@MainActor
final class AccessibilityClientTests: XCTestCase {
    func testSelectsComposerInsideOnlyDeepestMainRegion() throws {
        let elements = [
            summary(parent: nil, role: "AXWindow"),
            summary(parent: 0, role: "AXTextField", valueSettable: true),
            summary(parent: 0, role: "AXGroup", subrole: "AXLandmarkMain"),
            summary(parent: 2, role: "AXTextArea", value: "", valueSettable: true),
            summary(parent: 2, role: "AXButton", title: "Send"),
        ]

        XCTAssertEqual(
            try AccessibilityClient.selectFocusedConversationControls(in: elements),
            .init(composerIndex: 3, sendButtonIndex: 4)
        )
    }

    func testRejectsTwoMainRegionsWithComposers() {
        let elements = [
            summary(parent: nil, role: "AXWindow"),
            summary(parent: 0, role: "AXGroup", subrole: "AXLandmarkMain"),
            summary(parent: 1, role: "AXTextArea", value: "", valueSettable: true),
            summary(parent: 1, role: "AXButton", title: "Send"),
            summary(parent: 0, role: "AXGroup", subrole: "AXLandmarkMain"),
            summary(parent: 4, role: "AXTextArea", value: "", valueSettable: true),
            summary(parent: 4, role: "AXButton", title: "Send"),
        ]

        XCTAssertThrowsError(
            try AccessibilityClient.selectFocusedConversationControls(in: elements)
        ) { error in
            XCTAssertEqual(error as? AccessibilityClient.AXError, .ambiguousTask)
        }
    }

    func testRejectsNativeApprovalCardInCurrentConversation() {
        let elements = [
            summary(parent: nil, role: "AXWindow"),
            summary(parent: 0, role: "AXGroup", subrole: "AXLandmarkMain"),
            summary(parent: 1, role: "AXTextArea", value: "", valueSettable: true),
            summary(parent: 1, role: "AXButton", title: "Approve once"),
            summary(parent: 1, role: "AXButton", title: "Send"),
        ]

        XCTAssertThrowsError(
            try AccessibilityClient.selectFocusedConversationControls(in: elements)
        ) { error in
            XCTAssertEqual(error as? AccessibilityClient.AXError, .nativeApprovalCard)
        }
    }

    private func summary(
        parent: Int?,
        role: String,
        subrole: String? = nil,
        title: String? = nil,
        value: String? = nil,
        valueSettable: Bool = false
    ) -> AccessibilityClient.ElementSummary {
        .init(
            parentIndex: parent,
            role: role,
            subrole: subrole,
            title: title,
            description: nil,
            value: value,
            enabled: true,
            valueSettable: valueSettable
        )
    }
}
```

- [ ] **Step 2: 运行测试并确认 focused window 接口不存在**

Run:

```bash
swift test --filter AccessibilityClientTests
```

Expected: FAIL，缺少 `selectFocusedConversationControls`。

- [ ] **Step 3: 收窄 Accessibility 协议和错误类型**

在兼容旧导航方法的前提下新增 focused conversation 方法；旧方法在 Task 3 与导航器一起删除：

```swift
@MainActor
protocol AccessibilityControlling: AnyObject {
    func activateCodex() throws
    func openThreadURL(sessionId: String) throws
    func waitForTask(title: String, cwd: String, timeout: TimeInterval) async throws
    func currentTaskMatches(title: String, cwd: String) throws -> Bool
    func waitForFocusedConversation(timeout: TimeInterval) async throws
    func frontmostBundleIdentifier() -> String?
    func composerValue() throws -> String
    func setComposerValue(_ value: String) throws
    func pressSend() throws
}
```

把 `AXError` 改为可直接显示的错误：

```swift
enum AXError: Error, Equatable, LocalizedError {
    case permissionMissing
    case codexNotRunning
    case taskNotFound
    case ambiguousTask
    case composerMissing
    case composerValueUnreadable
    case nativeApprovalCard
    case sendActionMissing

    var errorDescription: String? {
        switch self {
        case .permissionMissing:
            "请在系统设置的辅助功能中启用 Codex 可"
        case .codexNotRunning:
            "Codex 尚未运行"
        case .taskNotFound:
            "找不到当前 Codex 窗口"
        case .ambiguousTask:
            "无法唯一确认当前 Codex 输入框"
        case .composerMissing:
            "找不到当前 Codex 输入框"
        case .composerValueUnreadable:
            "无法读取当前 Codex 输入框"
        case .nativeApprovalCard:
            "不支持此类原生审批"
        case .sendActionMissing:
            "找不到 Codex 发送按钮"
        }
    }
}
```

- [ ] **Step 4: 实现 focused conversation 选择和有上限等待**

复用现有 hierarchy/subtree helpers，把标题与 cwd 匹配删除：

```swift
func waitForFocusedConversation(timeout: TimeInterval) async throws {
    composer = nil
    sendButton = nil
    let deadline = Date().addingTimeInterval(timeout)

    repeat {
        do {
            let tree = try elementTree()
            let selection = try Self.selectFocusedConversationControls(
                in: tree.summaries
            )
            composer = tree.elements[selection.composerIndex]
            sendButton = tree.elements[selection.sendButtonIndex]
            return
        } catch let error as AXError {
            switch error {
            case .taskNotFound, .composerMissing, .sendActionMissing:
                break
            case .permissionMissing, .codexNotRunning, .ambiguousTask,
                 .composerValueUnreadable, .nativeApprovalCard:
                throw error
            }
        }

        if Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
    } while Date() < deadline

    throw AXError.taskNotFound
}

static func selectFocusedConversationControls(
    in elements: [ElementSummary]
) throws -> ControlSelection {
    guard !elements.isEmpty, hasValidHierarchy(elements) else {
        throw AXError.ambiguousTask
    }

    let mainRoots = elements.indices.filter {
        elements[$0].subrole == kAXLandmarkMainSubrole as String
    }
    var owners: [(root: Int, selection: ControlSelection)] = []

    for root in mainRoots {
        let indices = subtreeIndices(root: root, in: elements)
        do {
            let local = try selectControls(in: indices.map { elements[$0] })
            owners.append((
                root: root,
                selection: .init(
                    composerIndex: indices[local.composerIndex],
                    sendButtonIndex: indices[local.sendButtonIndex]
                )
            ))
        } catch let error as AXError {
            switch error {
            case .composerMissing, .sendActionMissing:
                continue
            case .permissionMissing, .codexNotRunning, .taskNotFound,
                 .ambiguousTask, .composerValueUnreadable, .nativeApprovalCard:
                throw error
            }
        }
    }

    let deepest = owners.filter { candidate in
        !owners.contains { other in
            other.root != candidate.root
                && isDescendant(other.root, of: candidate.root, in: elements)
        }
    }
    guard deepest.count == 1, let owner = deepest.first else {
        throw deepest.isEmpty ? AXError.composerMissing : AXError.ambiguousTask
    }
    return owner.selection
}
```

`elementTree()` 读取 focused window 失败时抛出 `.focusedWindowMissing`。`activateCodex()` 使用系统激活保持最近活动窗口，不打开 URL：

```swift
guard app.activate(options: [.activateIgnoringOtherApps]) else {
    throw AXError.taskNotFound
}
```

- [ ] **Step 5: 保持旧导航调用可编译**

本任务不删除 `openThreadURL`、`waitForTask`、`currentTaskMatches` 或
`CodexSessionNavigator.swift`。新旧定位方法短暂共存一个提交，确保 focused window 选择器可以
独立评审且全量测试保持绿色；Task 3 会原子删除旧接口并接入发送器。

- [ ] **Step 6: 更新测试替身并运行**

向现有 `FakeAccessibilityController` 增加以下记录和方法；原有旧导航方法本任务保持不变：

```swift
var focusError: Error?
private(set) var focusedConversationTimeouts: [TimeInterval] = []

func waitForFocusedConversation(timeout: TimeInterval) async throws {
    focusedConversationTimeouts.append(timeout)
    if let focusError { throw focusError }
}
```

Run:

```bash
swift test --filter AccessibilityClientTests
swift test
```

Expected: PASS；focused window、歧义和原生审批测试通过；全量旧测试仍为 0 failures。

- [ ] **Step 7: 提交**

```bash
git add Sources/CodexQuickOKApp/Automation/AccessibilityClient.swift \
  Tests/CodexQuickOKAppTests/AccessibilityClientTests.swift \
  Tests/CodexQuickOKAppTests/FakeCodexAutomation.swift
git commit -m "feat(accessibility): Locate focused Codex conversation"
```

---

### Task 3: 新增当前窗口单次发送路径

**Files:**
- Create: `Sources/CodexQuickOKApp/Automation/CurrentCodexAutomation.swift`
- Create: `Sources/CodexQuickOKApp/Automation/CurrentWindowApprovalSender.swift`
- Create: `Tests/CodexQuickOKAppTests/CurrentWindowApprovalSenderTests.swift`

**Interfaces:**
- Consumes: Task 1 的新安全门和 Task 2 的 `waitForFocusedConversation(timeout:)`。
- Produces: `CurrentCodexAutomating.activateCurrentWindow()` 和 `CurrentApprovalSending.sendOK()`。
- Compatibility: 旧 sender/navigation 保持不变到 Task 5，使本提交全量测试仍为绿色。

- [ ] **Step 1: 写新路径失败测试**

新测试文件包含当前窗口适配器和发送器测试：

```swift
import XCTest
@testable import CodexQuickOKApp

@MainActor
final class CurrentWindowApprovalSenderTests: XCTestCase {
    func testAutomationActivatesAndWaitsForFocusedConversation() async throws {
        let accessibility = FakeAccessibilityController()
        let automation = CurrentCodexAutomation(accessibility: accessibility)

        try await automation.activateCurrentWindow()

        XCTAssertEqual(accessibility.activationCount, 1)
        XCTAssertEqual(accessibility.focusedConversationTimeouts, [1.5])
        XCTAssertEqual(accessibility.openedSessionIds, [])
    }

    func testSendsOneChineseApprovalToCurrentWindow() async throws {
        let automation = FakeCurrentCodexAutomation(
            bundleId: "com.openai.codex",
            value: ""
        )
        try await CurrentWindowApprovalSender(automation: automation).sendOK()
        XCTAssertEqual(automation.activationCount, 1)
        XCTAssertEqual(automation.writtenValues, ["可"])
        XCTAssertEqual(automation.sendCount, 1)
    }

    func testRejectsDraftAndWrongFrontmostApplication() async {
        await assertRejectedWithoutWriting(
            FakeCurrentCodexAutomation(
                bundleId: "com.openai.codex",
                value: "draft"
            )
        )
        await assertRejectedWithoutWriting(
            FakeCurrentCodexAutomation(
                bundleId: "com.apple.TextEdit",
                value: ""
            )
        )
    }

    func testSendFailureLeavesApprovalAndDoesNotRetry() async {
        let automation = FakeCurrentCodexAutomation(
            bundleId: "com.openai.codex",
            value: ""
        )
        automation.sendError = FakeCurrentCodexAutomation.FakeError.sendUnavailable
        do {
            try await CurrentWindowApprovalSender(automation: automation).sendOK()
            XCTFail("Expected send failure")
        } catch {}
        XCTAssertEqual(automation.writtenValues, ["可"])
        XCTAssertEqual(automation.sendAttempts, 1)
    }

    private func assertRejectedWithoutWriting(
        _ automation: FakeCurrentCodexAutomation
    ) async {
        do {
            try await CurrentWindowApprovalSender(automation: automation).sendOK()
            XCTFail("Expected rejection")
        } catch {}
        XCTAssertEqual(automation.writtenValues, [])
        XCTAssertEqual(automation.sendAttempts, 0)
    }
}
```

- [ ] **Step 2: 运行测试并确认新类型不存在**

```bash
swift test --filter CurrentWindowApprovalSenderTests
```

Expected: FAIL，缺少 `CurrentCodexAutomation`、`CurrentWindowApprovalSender` 和
`FakeCurrentCodexAutomation`。

- [ ] **Step 3: 创建当前窗口自动化适配器**

```swift
import Foundation

@MainActor
protocol CurrentCodexAutomating: AnyObject {
    func activateCurrentWindow() async throws
    func frontmostBundleIdentifier() -> String?
    func composerValue() throws -> String
    func setComposerValue(_ value: String) throws
    func performSend() throws
}

@MainActor
final class CurrentCodexAutomation: CurrentCodexAutomating {
    private let accessibility: any AccessibilityControlling

    init(accessibility: any AccessibilityControlling) {
        self.accessibility = accessibility
    }

    func activateCurrentWindow() async throws {
        try accessibility.activateCodex()
        try await accessibility.waitForFocusedConversation(timeout: 1.5)
    }

    func frontmostBundleIdentifier() -> String? {
        accessibility.frontmostBundleIdentifier()
    }
    func composerValue() throws -> String { try accessibility.composerValue() }
    func setComposerValue(_ value: String) throws {
        try accessibility.setComposerValue(value)
    }
    func performSend() throws { try accessibility.pressSend() }
}
```

- [ ] **Step 4: 创建无 session ID 的发送器**

```swift
import CodexQuickOKCore
import Foundation

@MainActor
protocol CurrentApprovalSending: AnyObject {
    func sendOK() async throws
}

enum CurrentApprovalSendError: Error, Equatable, LocalizedError {
    case inProgress
    var errorDescription: String? { "上一次发送仍在进行，请稍后重试" }
}

@MainActor
final class CurrentWindowApprovalSender: CurrentApprovalSending {
    private let automation: any CurrentCodexAutomating
    private var sending = false

    init(automation: any CurrentCodexAutomating) {
        self.automation = automation
    }

    func sendOK() async throws {
        guard !sending else { throw CurrentApprovalSendError.inProgress }
        sending = true
        defer { sending = false }
        try await automation.activateCurrentWindow()
        let value = try automation.composerValue()
        try SendSafety.validate(
            bundleId: automation.frontmostBundleIdentifier(),
            composerValue: value
        )
        try automation.setComposerValue("可")
        try automation.performSend()
    }
}
```

- [ ] **Step 5: 添加当前路径测试替身和防重入测试**

在测试文件加入 `FakeCurrentCodexAutomation`，字段与方法和生产接口一一对应：

```swift
@MainActor
final class FakeCurrentCodexAutomation: CurrentCodexAutomating {
    enum FakeError: Error { case sendUnavailable }
    var bundleId: String?
    var value: String
    var activationGate: (() async throws -> Void)?
    var sendError: Error?
    private(set) var activationCount = 0
    private(set) var writtenValues: [String] = []
    private(set) var sendAttempts = 0
    private(set) var sendCount = 0

    init(bundleId: String?, value: String) {
        self.bundleId = bundleId
        self.value = value
    }

    func activateCurrentWindow() async throws {
        activationCount += 1
        try await activationGate?()
    }
    func frontmostBundleIdentifier() -> String? { bundleId }
    func composerValue() throws -> String { value }
    func setComposerValue(_ value: String) throws {
        writtenValues.append(value)
        self.value = value
    }
    func performSend() throws {
        sendAttempts += 1
        if let sendError { throw sendError }
        sendCount += 1
    }
}
```

加入完整防重入测试和 gate：

```swift
extension CurrentWindowApprovalSenderTests {
    func testDuplicateInFlightCallAllowsOnlyFirstSend() async throws {
        let automation = FakeCurrentCodexAutomation(
            bundleId: "com.openai.codex",
            value: ""
        )
        let gate = CurrentSenderGate()
        automation.activationGate = { await gate.wait() }
        let sender = CurrentWindowApprovalSender(automation: automation)
        let first = Task { try await sender.sendOK() }

        for _ in 0..<1_000 where automation.activationCount == 0 {
            await Task.yield()
        }
        do {
            try await sender.sendOK()
            XCTFail("Expected in-progress rejection")
        } catch {
            XCTAssertEqual(error as? CurrentApprovalSendError, .inProgress)
        }

        gate.release()
        try await first.value
        XCTAssertEqual(automation.writtenValues, ["可"])
        XCTAssertEqual(automation.sendCount, 1)
    }
}

@MainActor
private final class CurrentSenderGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
```

- [ ] **Step 6: 运行新路径与全量测试**

```bash
swift test --filter CurrentWindowApprovalSenderTests
swift test
```

Expected: 新测试 PASS；全量测试 0 failures；旧 sender/navigation 仍可编译和通过测试。

- [ ] **Step 7: 提交**

```bash
git add Sources/CodexQuickOKApp/Automation/CurrentCodexAutomation.swift \
  Sources/CodexQuickOKApp/Automation/CurrentWindowApprovalSender.swift \
  Tests/CodexQuickOKAppTests/CurrentWindowApprovalSenderTests.swift
git commit -m "feat(sender): Add current-window approval path"
```

---

### Task 4: 用手动控制器替换 Hook 会话控制器

**Files:**
- Create: `Sources/CodexQuickOKApp/ManualApprovalController.swift`
- Create: `Tests/CodexQuickOKAppTests/ManualApprovalControllerTests.swift`
- Modify: `Sources/CodexQuickOKApp/UI/FloatingPanelController.swift`
- Modify: `Tests/CodexQuickOKAppTests/FloatingPanelControllerTests.swift`
- Modify: `Tests/CodexQuickOKAppTests/AppControllerTests.swift`

**Interfaces:**
- Consumes: Task 3 的 `CurrentApprovalSending.sendOK()`。
- Produces: `ManualApprovalController.start()`、`show()`、`stop()`。
- Produces: `CompanionPanel.onRefreshQuota`，供 Task 5 通过协议装配额度刷新。

- [ ] **Step 1: 写手动控制器失败测试**

```swift
import CodexQuickOKCore
import XCTest
@testable import CodexQuickOKApp

@MainActor
final class ManualApprovalControllerTests: XCTestCase {
    func testStartAndShowAlwaysRevealPanel() {
        let panel = RecordingPanel()
        let controller = ManualApprovalController(panel: panel, sender: StubSender())

        controller.start()
        panel.hide()
        controller.show()

        XCTAssertEqual(panel.shownModes, [.running, .hidden, .running])
    }

    func testClickSendsOnceAndShowsSuccess() async {
        let panel = RecordingPanel()
        let sender = StubSender()
        let controller = ManualApprovalController(panel: panel, sender: sender)
        controller.start()

        panel.onActivate?()
        await waitUntil { panel.successCount == 1 }

        XCTAssertEqual(sender.callCount, 1)
        XCTAssertEqual(panel.sendingValues, [true, false])
        XCTAssertEqual(panel.lastMode, .running)
    }

    func testSecondClickIsIgnoredWhileSendRuns() async {
        let panel = RecordingPanel()
        let sender = StubSender(suspended: true)
        let controller = ManualApprovalController(panel: panel, sender: sender)
        controller.start()

        panel.onActivate?()
        panel.onActivate?()
        await waitUntil { sender.callCount == 1 }

        XCTAssertEqual(sender.callCount, 1)
        sender.finish()
    }

    func testFailureUsesLocalizedMessageAndDoesNotRetry() async {
        let panel = RecordingPanel()
        let sender = StubSender(error: SendSafetyError.existingDraft)
        let controller = ManualApprovalController(panel: panel, sender: sender)
        controller.start()

        panel.onActivate?()
        await waitUntil { !panel.failures.isEmpty }

        XCTAssertEqual(sender.callCount, 1)
        XCTAssertEqual(panel.failures, ["检测到未发送草稿"])
        XCTAssertEqual(panel.sendingValues, [true, false])
    }

    func testStopCancelsSendAndHidesPanel() async {
        let panel = RecordingPanel()
        let sender = StubSender(suspended: true)
        let controller = ManualApprovalController(panel: panel, sender: sender)
        controller.start()
        panel.onActivate?()
        await waitUntil { sender.callCount == 1 }

        controller.stop()

        XCTAssertEqual(panel.lastMode, .hidden)
        XCTAssertEqual(panel.sendingValues, [true, false])
    }
}
```

在同一测试文件加入完整替身和等待 helper：

```swift
@MainActor
final class RecordingPanel: CompanionPanel {
    var onActivate: (() -> Void)?
    var onTemporaryHide: (() -> Void)?
    var onRefreshQuota: (() -> Void)?
    private(set) var lastMode: CompanionMode = .hidden
    private(set) var shownModes: [CompanionMode] = []
    private(set) var sendingValues: [Bool] = []
    private(set) var failures: [String] = []
    private(set) var successCount = 0

    func show(mode: CompanionMode) {
        lastMode = mode
        shownModes.append(mode)
    }

    func hide() {
        lastMode = .hidden
        shownModes.append(.hidden)
    }

    func setQuota(_ quota: WeeklyQuota?) {}
    func setSending(_ sending: Bool) { sendingValues.append(sending) }
    func showSuccess() { successCount += 1 }
    func showFailure(_ message: String) { failures.append(message) }
}

@MainActor
final class StubSender: CurrentApprovalSending {
    private let suspended: Bool
    private let error: Error?
    private var continuation: CheckedContinuation<Void, Error>?
    private(set) var callCount = 0

    init(suspended: Bool = false, error: Error? = nil) {
        self.suspended = suspended
        self.error = error
    }

    func sendOK() async throws {
        callCount += 1
        if let error { throw error }
        guard suspended else { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.continuation?.resume(throwing: CancellationError())
                self?.continuation = nil
            }
        }
    }

    func finish() {
        continuation?.resume(returning: ())
        continuation = nil
    }
}

@MainActor
private func waitUntil(
    _ condition: @escaping @MainActor () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    for _ in 0..<1_000 {
        if condition() { return }
        await Task.yield()
    }
    XCTFail("Condition was not met", file: file, line: line)
}
```

- [ ] **Step 2: 运行测试并确认新类型不存在**

Run:

```bash
swift test --filter ManualApprovalControllerTests
```

Expected: FAIL，找不到 `ManualApprovalController`。

- [ ] **Step 3: 实现无状态控制器**

```swift
import CodexQuickOKCore
import Foundation

@MainActor
final class ManualApprovalController {
    private let panel: any CompanionPanel
    private let sender: any CurrentApprovalSending
    private var sendTask: Task<Void, Never>?
    private var attemptID: UInt64 = 0

    init(panel: any CompanionPanel, sender: any CurrentApprovalSending) {
        self.panel = panel
        self.sender = sender
        panel.onActivate = { [weak self] in self?.beginSend() }
    }

    func start() {
        show()
    }

    func show() {
        panel.show(mode: .running)
    }

    func stop() {
        attemptID &+= 1
        sendTask?.cancel()
        sendTask = nil
        panel.setSending(false)
        panel.hide()
    }

    private func beginSend() {
        guard sendTask == nil else { return }
        attemptID &+= 1
        let currentAttempt = attemptID
        panel.setSending(true)
        sendTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                guard attemptID == currentAttempt else { return }
                sendTask = nil
                panel.setSending(false)
            }
            do {
                try await sender.sendOK()
                panel.showSuccess()
            } catch is CancellationError {
                return
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? "发送失败，请检查 Codex"
                panel.showFailure(message)
            }
        }
    }
}
```

- [ ] **Step 4: 调整面板协议和文案**

向 `CompanionPanel` 增加：

```swift
var onRefreshQuota: (() -> Void)? { get set }
```

向旧 `AppControllerTests.swift` 的 `FakePanel` 临时加入同名可选闭包，使并行迁移期间旧测试继续
编译；Task 5 删除整份旧测试文件。

菜单改为：

```swift
menu.addItem(
    withTitle: "隐藏按钮（点 Dock 恢复）",
    action: #selector(hideTemporarily),
    keyEquivalent: ""
)
```

成功无障碍播报改为：

```swift
accessibilityAnnouncer.announce("已发送可", for: button)
```

在 `FloatingPanelControllerTests` 增加：

```swift
func testHideMenuExplainsDockRecovery() {
    let controller = FloatingPanelController(
        positionStore: PanelPositionStore(
            defaults: UserDefaults(suiteName: #function)!
        )
    )
    XCTAssertTrue(
        controller.button.menu?.items.contains {
            $0.title == "隐藏按钮（点 Dock 恢复）"
        } == true
    )
    controller.hide()
}
```

并把原测试期望的 `批准成功` 改为 `已发送可`。

- [ ] **Step 5: 运行手动控制器、面板和全量测试**

本任务保留旧 `AppController` 及其测试，因为生产 `AppDelegate` 尚未在本提交切换；Task 5 会
原子切换装配并删除旧路径。

Run:

```bash
swift test --filter ManualApprovalControllerTests
swift test --filter FloatingPanelControllerTests
swift test
```

Expected: 两组新测试 PASS；全量测试 0 failures。

- [ ] **Step 6: 提交**

```bash
git add Sources/CodexQuickOKApp/ManualApprovalController.swift \
  Sources/CodexQuickOKApp/UI/FloatingPanelController.swift \
  Tests/CodexQuickOKAppTests/AppControllerTests.swift \
  Tests/CodexQuickOKAppTests/ManualApprovalControllerTests.swift \
  Tests/CodexQuickOKAppTests/FloatingPanelControllerTests.swift
git commit -m "feat(app): Add persistent manual approval controller"
```

---

### Task 5: 改造 AppDelegate 为手动启动并迁移旧登录项

**Files:**
- Create: `Sources/CodexQuickOKApp/LoginItemManager.swift`
- Modify: `Sources/CodexQuickOKApp/AppDelegate.swift`
- Modify: `Sources/CodexQuickOKApp/Automation/AccessibilityClient.swift`
- Modify: `Sources/CodexQuickOKApp/Quota/CodexAppServerClient.swift`
- Modify: `Sources/CodexQuickOKCore/SendSafety.swift`
- Delete: `Sources/CodexQuickOKApp/AppController.swift`
- Delete: `Sources/CodexQuickOKApp/Automation/ApprovalSender.swift`
- Delete: `Sources/CodexQuickOKApp/Automation/CodexSessionNavigator.swift`
- Delete: `Sources/CodexQuickOKApp/CodexProcessMonitor.swift`
- Delete: `Sources/CodexQuickOKApp/SessionDirectoryMonitor.swift`
- Modify: `Tests/CodexQuickOKAppTests/ManualApprovalControllerTests.swift`
- Create: `Tests/CodexQuickOKAppTests/AppDelegateTests.swift`
- Delete: `Tests/CodexQuickOKAppTests/AppControllerTests.swift`
- Delete: `Tests/CodexQuickOKAppTests/ApprovalSenderTests.swift`
- Delete: `Tests/CodexQuickOKAppTests/FakeCodexAutomation.swift`

**Interfaces:**
- Consumes: Task 4 的 `ManualApprovalController` 和 `CompanionPanel`。
- Produces: `AppDelegate.configureManualRuntime(panel:sender:)`、Dock reopen 恢复和 `removeLegacyLoginItemIfNeeded()`。

- [ ] **Step 1: 写 AppDelegate 手动生命周期失败测试**

在 `ManualApprovalControllerTests.swift` 增加：

```swift
@MainActor
final class AppDelegateManualModeTests: XCTestCase {
    func testManualRuntimeShowsImmediatelyAndReopenRestoresIt() {
        let panel = RecordingPanel()
        let delegate = makeDelegate()
        delegate.configureManualRuntime(panel: panel, sender: StubSender())

        XCTAssertEqual(panel.lastMode, .running)
        panel.hide()
        XCTAssertTrue(
            delegate.applicationShouldHandleReopen(
                NSApplication.shared,
                hasVisibleWindows: false
            )
        )
        XCTAssertEqual(panel.lastMode, .running)
    }

    func testRemovesEnabledLegacyLoginItem() async {
        let loginItem = FakeLoginItemManager(status: .enabled)
        let delegate = makeDelegate(loginItemManager: loginItem)

        delegate.removeLegacyLoginItemIfNeeded()
        await waitUntil { loginItem.unregisterCount == 1 }

        XCTAssertEqual(loginItem.unregisterCount, 1)
    }

    func testDoesNothingWhenLegacyLoginItemIsAbsent() async {
        let loginItem = FakeLoginItemManager(status: .notRegistered)
        let delegate = makeDelegate(loginItemManager: loginItem)

        delegate.removeLegacyLoginItemIfNeeded()
        await Task.yield()

        XCTAssertEqual(loginItem.unregisterCount, 0)
    }

    private func makeDelegate(
        loginItemManager: any LegacyLoginItemManaging =
            FakeLoginItemManager(status: .notRegistered)
    ) -> AppDelegate {
        AppDelegate(
            appServer: ControlledAppServer(),
            codexBinaryProvider: { URL(fileURLWithPath: "/tmp/codex") },
            terminationReply: { _ in },
            loginItemManager: loginItemManager
        )
    }
}

@MainActor
private final class FakeLoginItemManager: LegacyLoginItemManaging {
    let status: SMAppService.Status
    private(set) var unregisterCount = 0

    init(status: SMAppService.Status) {
        self.status = status
    }

    func unregister() async throws {
        unregisterCount += 1
    }
}
```

文件顶部加入 `import AppKit`、`import CodexQuickOKCore`、`import Foundation`、
`import ServiceManagement`、`import XCTest`。保留已迁移的
`AppDelegateConfigurationTests` 中额度 5 分钟刷新、重连退避、Codex binary 路径和安全
终止测试；只删除其 fake app server 的 `readThreadMetadata` 方法。

- [ ] **Step 2: 运行测试并确认手动装配接口不存在**

Run:

```bash
swift test --filter AppDelegateManualModeTests
```

Expected: FAIL，缺少 `configureManualRuntime`、reopen 和 `LegacyLoginItemManaging`。

- [ ] **Step 3: 添加只负责注销的登录项封装**

```swift
import ServiceManagement

@MainActor
protocol LegacyLoginItemManaging: AnyObject {
    var status: SMAppService.Status { get }
    func unregister() async throws
}

@MainActor
final class MainAppLoginItemManager: LegacyLoginItemManaging {
    var status: SMAppService.Status { SMAppService.mainApp.status }

    func unregister() async throws {
        try await SMAppService.mainApp.unregister()
    }
}
```

- [ ] **Step 4: 改造 AppDelegate 装配**

属性改为：

```swift
static let codexBundleIdentifier = "com.openai.codex"

private let loginItemManager: any LegacyLoginItemManaging
private var panel: (any CompanionPanel)?
private var controller: ManualApprovalController?
```

指定初始化器改为：

```swift
init(
    appServer: any CodexAppServerServing,
    codexBinaryProvider: @escaping () throws -> URL,
    terminationReply: @escaping @MainActor (Bool) -> Void,
    loginItemManager: any LegacyLoginItemManaging = MainAppLoginItemManager()
) {
    self.appServer = appServer
    self.codexBinaryProvider = codexBinaryProvider
    self.terminationReply = terminationReply
    self.loginItemManager = loginItemManager
    super.init()
}
```

`override convenience init()` 继续传前三个参数并使用默认 login item manager。正常启动主体改为：

```swift
showOnboardingIfNeeded()
requestAccessibilityIfNeeded()
removeLegacyLoginItemIfNeeded()

let panel = FloatingPanelController()
let automation = CurrentCodexAutomation(accessibility: AccessibilityClient())
let sender = CurrentWindowApprovalSender(automation: automation)
configureManualRuntime(panel: panel, sender: sender)

quotaTimer = Timer.scheduledTimer(
    withTimeInterval: Self.quotaRefreshInterval,
    repeats: true
) { [weak self] _ in
    Task { @MainActor in self?.refreshQuota() }
}
beginAppServerStart()
```

测试入口和 reopen：

```swift
func configureManualRuntime(
    panel: any CompanionPanel,
    sender: any CurrentApprovalSending
) {
    let controller = ManualApprovalController(panel: panel, sender: sender)
    self.panel = panel
    self.controller = controller
    panel.onRefreshQuota = { [weak self] in self?.refreshQuota() }
    controller.start()
}

func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
) -> Bool {
    controller?.show()
    return true
}
```

旧登录项迁移：

```swift
func removeLegacyLoginItemIfNeeded() {
    switch loginItemManager.status {
    case .enabled, .requiresApproval:
        Task { [loginItemManager] in try? await loginItemManager.unregister() }
    case .notRegistered, .notFound:
        break
    @unknown default:
        break
    }
}
```

删除 `SessionStateStore`、`SessionDirectoryMonitor`、`CodexProcessMonitor` 的创建、回调和停止逻辑。终止时只停止 controller、额度 timer、重连 task 和 app server。

在同一原子切换中完成旧路径清理：

```text
删除 AppController、旧 ApprovalSender、CodexSessionNavigator 及对应测试替身。
从 AccessibilityControlling/AccessibilityClient 删除任务 URL、title/cwd 定位方法。
把 CodexAppServerServing 从 ThreadMetadataReading 改为 Sendable。
从 SendSafety 删除临时 sessionMismatch case 和三参数 deprecated overload。
```

把原 `AppControllerTests.swift` 中 `AppDelegateConfigurationTests`、
`ControlledAppServer`、`spinMainActor` 和异步 `waitUntil` 原样移入新
`AppDelegateTests.swift`，再加入 Step 1 的手动模式测试。其余旧 controller 与 monitor 测试
不迁移。`ControlledAppServer` 删除 `readThreadMetadata` 要求后仍保留 start、rate limits、
notification handler 和 stop 实现。

- [ ] **Step 5: 更新首次引导文案**

保持 `didShowOnboarding.v1`，避免现有用户升级时被旧引导弹窗阻塞；新安装显示：

```swift
alert.informativeText = "请授予辅助功能权限。之后从 Dock 手动启动；点击悬浮的“可”按钮，会向最近使用的 Codex 窗口空输入框发送一次“可”。"
```

- [ ] **Step 6: 删除未使用监视器并运行生命周期测试**

Run:

```bash
swift test --filter AppDelegateManualModeTests
swift test --filter AppDelegateConfigurationTests
swift test
rg -n "SessionDirectoryMonitor|CodexProcessMonitor|registerLoginItemIfNeeded" \
  Sources/CodexQuickOKApp Tests/CodexQuickOKAppTests
rg -n "activateAndOpen|currentSessionMatches|ApprovalSendReceipt|sessionMismatch" \
  Sources Tests
```

Expected: 两组测试 PASS；全量 `swift test` 0 failures；两个 `rg` 均无输出。

- [ ] **Step 7: 提交**

```bash
git add -A Sources/CodexQuickOKApp Sources/CodexQuickOKCore/SendSafety.swift \
  Tests/CodexQuickOKAppTests
git commit -m "feat(lifecycle): Launch approval button manually"
```

---

### Task 6: 移除 Hook 安装路径并发布 build 4

**Files:**
- Modify: `Package.swift`
- Delete: `Sources/CodexQuickOKHook/main.swift`
- Delete: `plugin/codex-quick-ok/.codex-plugin/plugin.json`
- Delete: `plugin/codex-quick-ok/hooks.json`
- Delete: `marketplace/.agents/plugins/marketplace.json`
- Modify: `Sources/CodexQuickOKApp/Quota/CodexAppServerClient.swift`
- Modify: `scripts/build-release.sh`
- Modify: `scripts/install-local.sh`
- Modify: `scripts/uninstall-local.sh`
- Modify: `Tests/PackagingTests.sh`
- Modify: `Resources/Info.plist`
- Modify: `README.md`
- Modify: `docs/manual-verification.md`

**Interfaces:**
- Consumes: Task 5 的独立 App target。
- Produces: 只包含 `Codex 可.app` 的 build 4、无 Hook 安装步骤，以及兼容旧安装的卸载清理。

- [ ] **Step 1: 先把打包测试改成手动模式契约**

从 `PackagingTests.sh` 删除 marketplace 文件必需检查和 plugin 安装精确行，增加：

```zsh
expect_absent_text Package.swift 'CodexQuickOKHook'
expect_absent_text scripts/build-release.sh 'CodexQuickOKHook|dist/marketplace|PLUGIN='
expect_absent_text scripts/install-local.sh 'codex plugin|/hooks|登录项'
expect_absent_text README.md '/hooks|等待批准任务|登录项默认开启'
```

把 build 断言改为：

```zsh
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/Resources/Info.plist" 2>/dev/null)" == 4 ]] \
  || fail 'bundle version must be 4'
```

保留 uninstall 中以下迁移清理断言，因为旧用户机器可能仍装有 plugin：

```zsh
expect_exact_line scripts/uninstall-local.sh \
  'codex plugin remove codex-quick-ok --marketplace codex-quick-ok-local --json || true'
expect_exact_line scripts/uninstall-local.sh \
  'codex plugin marketplace remove codex-quick-ok-local --json || true'
```

- [ ] **Step 2: 运行打包测试并确认旧 Hook 路径失败**

Run:

```bash
zsh Tests/PackagingTests.sh
```

Expected: FAIL，报告 `Package.swift`、build/install script、README 仍包含 Hook 路径，build 仍为 3。

- [ ] **Step 3: 收窄 Swift package 和 App Server**

`Package.swift` products/targets 删除 `CodexQuickOKHook`：

```swift
products: [
    .library(name: "CodexQuickOKCore", targets: ["CodexQuickOKCore"]),
    .executable(name: "CodexQuickOKApp", targets: ["CodexQuickOKApp"]),
],
targets: [
    .target(name: "CodexQuickOKCore"),
    .executableTarget(name: "CodexQuickOKApp", dependencies: ["CodexQuickOKCore"]),
    .testTarget(name: "CodexQuickOKCoreTests", dependencies: ["CodexQuickOKCore"]),
    .testTarget(
        name: "CodexQuickOKAppTests",
        dependencies: ["CodexQuickOKApp", "CodexQuickOKCore"]
    ),
]
```

从 `CodexAppServerClient` 删除 `ThreadMetadata`、`readThreadMetadata`；协议变为：

```swift
protocol CodexAppServerServing: Sendable {
    func start(codexBinary: URL) async throws
    func readRateLimits() async throws -> RateLimitsReadResult
    func setRateLimitUpdateHandler(
        _ handler: @escaping @Sendable () -> Void
    ) async throws
    func stop() async
}
```

- [ ] **Step 4: 让 release 和 installer 只处理 App**

`build-release.sh` 的 bundle 创建段改为：

```zsh
rm -rf "$ROOT/dist"
APP="$ROOT/dist/Codex 可.app"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/CodexQuickOKApp" \
  "$APP/Contents/MacOS/CodexQuickOKApp"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/PrivacyInfo.xcprivacy" \
  "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
cp "$ICON_BUILD_DIR/AppIcon.icns" \
  "$APP/Contents/Resources/AppIcon.icns"
```

`install-local.sh` 在 `touch` 后只保留 Dock 刷新和启动：

```zsh
killall Dock || true
open "$DEST_APP"
print '请在系统设置中仅授予“Codex 可”辅助功能权限。'
print '以后点击 Dock 图标即可手动启动；右键退出后不会自动重启。'
```

删除 Hook target、plugin 和 marketplace 源文件。`uninstall-local.sh` 保留旧 plugin 清理和 `--unregister-login-item`，用于兼容已经安装过旧版的机器。

- [ ] **Step 5: 更新 build、README 和验证清单**

`Info.plist`：

```xml
<key>CFBundleVersion</key>
<string>4</string>
```

README 使用以下行为说明：

```markdown
## 使用

- 点击 Dock 中的“Codex 可”，悬浮按钮立即出现并保持可见。
- 单击按钮会激活最近使用的 Codex 窗口；输入框为空时写入“可”并自动发送。
- 输入框已有草稿、目标窗口不明确或存在原生审批卡片时安全失败。
- 右键可查看周额度、刷新、隐藏或退出；隐藏后再次点击 Dock 图标恢复。
- 应用不会开机自启，也不依赖 Codex Hook。
- 灰色光环表示周额度暂不可用，不代表额度为零。
```

把 `docs/manual-verification.md` 替换为下面的可执行清单；初始状态只把自动测试覆盖项标为
`PASS (automatic)`，真实 UI 项保持 `PENDING (manual)`：

```markdown
# Manual Verification — Build 4

## Automatic evidence

| Check | Expected |
| --- | --- |
| `swift test` | 0 failures |
| `zsh Tests/PackagingTests.sh` | Packaging static checks passed. |
| `zsh Tests/AppIconTests.sh` | App icon renderer checks passed. |
| `zsh Tests/SigningTests.sh` | Stable signing checks passed. |
| `codesign --verify --deep --strict 'dist/Codex 可.app'` | exit 0 |
| Bundle version | `4` |

## Manual acceptance

| ID | Check | Initial status |
| --- | --- | --- |
| 1 | 点击 Dock 冷启动后按钮立即出现 | PENDING (manual) |
| 2 | 没有运行中 Codex 任务时按钮仍保持可见 | PENDING (manual) |
| 3 | 隐藏按钮后再次点击 Dock 可恢复 | PENDING (manual) |
| 4 | Codex 已在前台时发送到 focused window | PENDING (manual) |
| 5 | 其他应用在前台时激活最近使用的 Codex 窗口并发送 | PENDING (manual) |
| 6 | 多个 Codex 窗口时不跳转任务 | PENDING (manual) |
| 7 | 非空草稿保持原样且不发送 | PASS (automatic) |
| 8 | 原生审批卡片存在时不发送聊天文字 | PASS (automatic) |
| 9 | 重复点击最多执行一次发送 | PASS (automatic) |
| 10 | Codex 未运行时显示失败且不启动 Codex | PASS (automatic) |
| 11 | 周额度不可用时光环为灰色且按钮可点击 | PASS (automatic) |
| 12 | 拖动超过 5 pt 不发送 | PASS (automatic) |
| 13 | 退出后重新登录系统不会自动启动 | PENDING (manual) |
| 14 | 旧版登录项在 build 4 首次启动后被注销 | PASS (automatic) |
| 15 | 同一签名身份升级后 Accessibility 授权保持有效 | PENDING (manual) |
| 16 | 卸载只删除本应用、旧 plugin 和自有支持目录 | PASS (automatic) |

真实发送只在用户选定的 Codex 当前任务输入框为空时执行一次。自动化验证不得代替用户点击
悬浮按钮，以免在正在运行的任务中注入额外消息。
```

- [ ] **Step 6: 运行打包与文档检查**

Run:

```bash
swift test
zsh Tests/PackagingTests.sh
zsh Tests/AppIconTests.sh
zsh Tests/SigningTests.sh
git diff --check
```

Expected: 全部 PASS；`swift test` 0 failures；`git diff --check` 无输出。

- [ ] **Step 7: 提交**

```bash
git add -A Package.swift Sources/CodexQuickOKHook plugin marketplace \
  Sources/CodexQuickOKApp/Quota/CodexAppServerClient.swift \
  Resources scripts Tests/PackagingTests.sh README.md docs/manual-verification.md
git commit -m "build: Package manual Codex approval app"
```

---

### Task 7: 全量验证、构建、安装并启动

**Files:**
- Verify: all source, tests, scripts, `dist/Codex 可.app`
- Install: `~/Applications/Codex 可.app`

**Interfaces:**
- Consumes: Task 1–6 的完整 build 4。
- Produces: 已签名、已安装、可从现有 Dock 项手动启动的 App。

- [ ] **Step 1: 运行全量自动验证**

```bash
swift test
zsh Tests/PackagingTests.sh
zsh Tests/AppIconTests.sh
zsh Tests/SigningTests.sh
git diff --check
```

Expected: 所有命令 exit 0；Swift 测试 0 failures；diff check 无输出。

- [ ] **Step 2: 构建稳定签名 release**

```bash
zsh scripts/build-release.sh
codesign --verify --deep --strict --verbose=2 'dist/Codex 可.app'
codesign -d -r- 'dist/Codex 可.app' 2>&1
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
  'dist/Codex 可.app/Contents/Info.plist'
```

Expected: 构建成功；签名 valid on disk；designated requirement 同时包含固定 bundle ID 和本地签名证书指纹；build 输出 `4`。

- [ ] **Step 3: 替换已安装 App 并启动**

```bash
zsh scripts/install-local.sh
pgrep -fl 'CodexQuickOKApp'
```

Expected: `~/Applications/Codex 可.app` 被替换，LaunchServices 刷新，Dock 项继续指向同一路径，进程正在运行，悬浮按钮立即出现。

- [ ] **Step 4: 做不发送文字的 UI 冒烟检查**

检查以下事实：

```text
1. 启动后按钮无需 Codex Hook 或活跃任务即可出现。
2. 右键菜单显示“隐藏按钮（点 Dock 恢复）”。
3. 隐藏后点击 Dock 图标，按钮重新出现。
4. 周额度不可用时光环为灰色。
5. 拖动超过 5 pt 不触发发送。
```

Expected: 五项全部符合；此步骤不点击按钮中央，因此不会向当前任务注入测试消息。

- [ ] **Step 5: 交给用户做一次真实发送验收**

用户在希望继续的 Codex 当前任务中清空输入框后单击“可”。验收结果必须同时满足：

```text
Codex 成为前台应用。
最近使用的 Codex 窗口保持当前任务，不发生任务跳转。
输入框收到且只收到一次“可”，随后自动发送。
悬浮按钮显示一次绿色反馈并继续可见。
```

若输入框预先放入任意草稿，则点击后草稿保持原样、没有发送，按钮显示“检测到未发送草稿”。

- [ ] **Step 6: 最终状态检查**

```bash
git status --short
git log --oneline -8
```

Expected: 工作树干净；能看到每个任务对应的小提交；已安装 App 是 build 4。

---

## Self-Review Result

- Spec coverage: 手动启动、常驻、Dock 恢复、最近活动窗口、空草稿、原生审批、单次发送、失败不重试、旧登录项迁移、周额度、打包和安装均有对应任务。
- Placeholder scan: 所有修改步骤都给出具体接口、代码、命令和预期结果。
- Type consistency: `CurrentCodexAutomating.activateCurrentWindow()` → `CurrentApprovalSending.sendOK()` → `ManualApprovalController` → `AppDelegate.configureManualRuntime(panel:sender:)` 接口一致；最终运行路径没有 session ID 或 receipt 参数。
- Scope control: 保留旧 Core 状态模型但从应用与安装路径断开；不把本次功能变成无关的数据模型清理。
