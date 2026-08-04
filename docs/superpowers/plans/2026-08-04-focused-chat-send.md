# “可”跟随当前焦点的跨应用发送实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让悬浮“可”只向用户点击前已聚焦的空聊天输入框写入一次“可”，再向同一 PID 投递一次 Enter，首批稳定支持 Codex、Visual Studio Code 侧边栏聊天和微信。

**Architecture:** 保留现有非激活悬浮面板和 `CurrentApprovalSending` 接口，新增纯值聊天上下文、专用/通用混合分类器和带 AX 元素身份的焦点快照。`AccessibilityClient` 负责当前焦点采集、有限上下文读取、目标重验、PID 定向输入和 Enter；`FocusedChatApprovalSender` 只编排安全门，不再激活 Codex 或查找发送按钮。

**Tech Stack:** Swift 6、Swift Package Manager、macOS 14+、AppKit、ApplicationServices/Accessibility、CoreGraphics、XCTest、zsh 发布脚本。

## Global Constraints

- 只操作点击前已聚焦的空白聊天输入框；已有草稿不覆盖、不追加、不提交。
- Codex、`com.microsoft.VSCode`、`com.tencent.xinWeChat` 使用专用规则；已知应用拒绝后不得回退通用规则。
- 代码编辑器、终端、搜索框、密码框和普通表单必须拒绝。
- 文本和 Enter 都定向投递到焦点快照中的同一 PID；写入前和 Enter 前必须重验 PID、窗口和元素身份。
- 发送统一使用 Enter；不点击发送按钮，不推断或替换应用自定义快捷键。
- 任何不确定状态安全失败并闪红；失败后不猜测第二个输入框，不自动重试。
- 不读取其他输入框的值，不记录消息、草稿、聊天对象或窗口标题。
- 保留悬浮面板、拖动、点击锁、成功/失败反馈、周额度和安装流程；不新增设置 UI 或依赖。

## 文件结构

```text
Sources/CodexQuickOKApp/Automation/
├── FocusedChatTarget.swift          # 焦点上下文、快照、输入协议和共享错误
├── ChatTargetClassifier.swift       # 三个专用适配器与保守通用分类器
├── FocusedChatApprovalSender.swift  # 空值校验、写入确认、重验和 Enter 状态机
└── AccessibilityClient.swift        # AX 焦点采集、身份比较、PID 定向事件

Tests/CodexQuickOKAppTests/
├── ChatTargetClassifierTests.swift
├── FocusedChatApprovalSenderTests.swift
├── AccessibilityClientTests.swift
└── LiveSendPipelineProbeTests.swift
```

切换完成后删除：

```text
Sources/CodexQuickOKApp/Automation/CurrentCodexAutomation.swift
Sources/CodexQuickOKApp/Automation/CurrentWindowApprovalSender.swift
Sources/CodexQuickOKCore/SendSafety.swift
Tests/CodexQuickOKAppTests/CurrentWindowApprovalSenderTests.swift
Tests/CodexQuickOKCoreTests/SendSafetyTests.swift
```

---

### Task 1: 建立聊天目标模型和混合分类器

**Files:**
- Create: `Sources/CodexQuickOKApp/Automation/FocusedChatTarget.swift`
- Create: `Sources/CodexQuickOKApp/Automation/ChatTargetClassifier.swift`
- Create: `Tests/CodexQuickOKAppTests/ChatTargetClassifierTests.swift`

**Interfaces:**
- Consumes: AX 角色、子角色、标题、描述、enabled 和 value-settable 摘要；本任务不依赖真实 AX 元素。
- Produces: `ChatElementSummary`、`FocusedChatContext`、`ChatTargetMatch`、`ChatTargetClassifying.classify(bundleIdentifier:context:)`。

- [ ] **Step 1: 写入分类器失败测试**

创建测试文件，使用纯值摘要覆盖专用适配、通用回退和硬拒绝。测试正文使用以下结构，不通过真实应用或字符串夹具文件间接断言：

```swift
import XCTest
@testable import CodexQuickOKApp

final class ChatTargetClassifierTests: XCTestCase {
    private let classifier = ChatTargetClassifier()

    func testCodexMainComposerIsAcceptedAndPlaceholderIsNormalized() throws {
        let context = makeContext(
            focused: field(description: "Message Codex"),
            ancestors: [node(role: "AXLandmarkMain", title: "Conversation")]
        )
        let match = try classifier.classify(
            bundleIdentifier: "com.openai.codex",
            context: context
        )
        XCTAssertEqual(match.kind, .codex)
        XCTAssertEqual(match.normalizedComposerValue("\nMessage Codex"), "")
        XCTAssertEqual(match.normalizedComposerValue("draft"), "draft")
    }

    func testCodexNonConversationInputAndNativeApprovalAreRejected() {
        let ordinary = makeContext(focused: field(title: "Notes"))
        XCTAssertThrowsError(
            try classifier.classify(
                bundleIdentifier: "com.openai.codex",
                context: ordinary
            )
        )
        let approval = makeContext(
            focused: field(description: "Message Codex"),
            ancestors: [node(subrole: "AXLandmarkMain")],
            nearby: [node(role: "AXButton", title: "Approve")]
        )
        XCTAssertThrowsError(
            try classifier.classify(
                bundleIdentifier: "com.openai.codex",
                context: approval
            )
        )
    }

    func testVSCodeChatIsAcceptedButEditorTerminalSearchAndSCMAreRejected() throws {
        XCTAssertEqual(
            try classifyVSCode(ancestors: [node(title: "Chat")]).kind,
            .visualStudioCode
        )
        for label in ["Text Editor", "Terminal", "Search", "Source Control"] {
            XCTAssertThrowsError(try classifyVSCode(ancestors: [node(title: label)]))
        }
    }

    func testWeChatMessageEditorIsAcceptedButSearchIsRejected() throws {
        let message = makeContext(
            focused: field(role: "AXTextArea"),
            nearby: [node(role: "AXButton", title: "发送")]
        )
        XCTAssertEqual(
            try classifier.classify(
                bundleIdentifier: "com.tencent.xinWeChat",
                context: message
            ).kind,
            .weChat
        )
        let search = makeContext(focused: field(role: "AXTextField", title: "搜索"))
        XCTAssertThrowsError(
            try classifier.classify(
                bundleIdentifier: "com.tencent.xinWeChat",
                context: search
            )
        )
    }

    func testKnownAdapterRejectionNeverFallsBackToGenericSendEvidence() {
        let editorWithSend = makeContext(
            focused: field(title: "Text Editor"),
            nearby: [node(role: "AXButton", title: "Send")]
        )
        XCTAssertThrowsError(
            try classifier.classify(
                bundleIdentifier: "com.microsoft.VSCode",
                context: editorWithSend
            )
        )
    }

    func testGenericMessageComposerNeedsPositiveChatEvidence() throws {
        let chat = makeContext(
            focused: field(description: "Write a message"),
            ancestors: [node(title: "Conversation")],
            nearby: [node(role: "AXButton", title: "Send")]
        )
        XCTAssertEqual(
            try classifier.classify(bundleIdentifier: "example.chat", context: chat).kind,
            .generic
        )
        let contactForm = makeContext(
            focused: field(description: "Message"),
            nearby: [node(role: "AXButton", title: "Send")]
        )
        XCTAssertThrowsError(
            try classifier.classify(
                bundleIdentifier: "example.form",
                context: contactForm
            )
        )
    }

    func testDisabledReadonlySecureAndExplicitlyDeniedControlsAreRejected() {
        let contexts = [
            makeContext(focused: field(enabled: false)),
            makeContext(focused: field(valueSettable: false)),
            makeContext(focused: field(subrole: "AXSecureTextField")),
            makeContext(focused: field(title: "Terminal chat message")),
        ]
        for context in contexts {
            XCTAssertThrowsError(
                try classifier.classify(bundleIdentifier: "example.chat", context: context)
            )
        }
    }

    private func classifyVSCode(
        ancestors: [ChatElementSummary]
    ) throws -> ChatTargetMatch {
        try classifier.classify(
            bundleIdentifier: "com.microsoft.VSCode",
            context: makeContext(focused: field(), ancestors: ancestors)
        )
    }

    private func makeContext(
        focused: ChatElementSummary,
        ancestors: [ChatElementSummary] = [],
        nearby: [ChatElementSummary] = []
    ) -> FocusedChatContext {
        FocusedChatContext(focused: focused, ancestors: ancestors, nearby: nearby)
    }

    private func field(
        role: String = "AXTextArea",
        subrole: String? = nil,
        title: String? = nil,
        description: String? = nil,
        enabled: Bool = true,
        valueSettable: Bool = true
    ) -> ChatElementSummary {
        node(
            role: role,
            subrole: subrole,
            title: title,
            description: description,
            enabled: enabled,
            valueSettable: valueSettable
        )
    }

    private func node(
        role: String = "AXGroup",
        subrole: String? = nil,
        title: String? = nil,
        description: String? = nil,
        enabled: Bool = true,
        valueSettable: Bool = false
    ) -> ChatElementSummary {
        ChatElementSummary(
            role: role,
            subrole: subrole,
            title: title,
            description: description,
            enabled: enabled,
            valueSettable: valueSettable
        )
    }
}
```

- [ ] **Step 2: 运行测试并确认按预期失败**

Run:

```bash
swift test --filter ChatTargetClassifierTests
```

Expected: FAIL，编译器报告 `ChatTargetClassifier`、`ChatElementSummary` 和相关类型不存在。

- [ ] **Step 3: 实现纯值模型和适配器协议**

在 `FocusedChatTarget.swift` 写入完整共享模型：

```swift
import Foundation

struct ChatElementSummary: Equatable {
    let role: String?
    let subrole: String?
    let title: String?
    let description: String?
    let enabled: Bool
    let valueSettable: Bool

    var normalizedLabels: [String] {
        [title, description, subrole]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0.lowercased() }
    }
}

struct FocusedChatContext: Equatable {
    let focused: ChatElementSummary
    let ancestors: [ChatElementSummary]
    let nearby: [ChatElementSummary]

    var evidence: [ChatElementSummary] { [focused] + ancestors + nearby }
}

enum ChatTargetKind: Equatable {
    case codex
    case visualStudioCode
    case weChat
    case generic
}

struct ChatTargetMatch: Equatable {
    let kind: ChatTargetKind
    let placeholderDescription: String?

    init(kind: ChatTargetKind, placeholderDescription: String? = nil) {
        self.kind = kind
        self.placeholderDescription = placeholderDescription
    }

    func normalizedComposerValue(_ rawValue: String) -> String {
        guard kind == .codex,
              let placeholderDescription,
              !placeholderDescription.isEmpty,
              rawValue == "\n\(placeholderDescription)"
        else { return rawValue }
        return ""
    }
}

enum ChatTargetClassificationError: Error, Equatable, LocalizedError {
    case unsupportedInputContext

    var errorDescription: String? {
        "当前光标不在支持的聊天输入框中"
    }
}

protocol ChatTargetClassifying: AnyObject {
    func classify(
        bundleIdentifier: String,
        context: FocusedChatContext
    ) throws -> ChatTargetMatch
}

protocol ChatTargetAdapting {
    var bundleIdentifiers: Set<String> { get }
    func classify(context: FocusedChatContext) throws -> ChatTargetMatch
}
```

在 `ChatTargetClassifier.swift` 实现固定分派顺序。共享 `ChatEvidence` 必须先执行硬拒绝；
`ChatTargetClassifier` 命中已知 Bundle ID 后直接返回专用适配结果，不能进入 generic：

```swift
import Foundation

final class ChatTargetClassifier: ChatTargetClassifying {
    private let adapters: [any ChatTargetAdapting]
    private let generic = GenericChatTargetAdapter()

    convenience init() {
        self.init(adapters: [
            CodexChatTargetAdapter(),
            VisualStudioCodeChatTargetAdapter(),
            WeChatTargetAdapter(),
        ])
    }

    init(adapters: [any ChatTargetAdapting]) {
        self.adapters = adapters
    }

    func classify(
        bundleIdentifier: String,
        context: FocusedChatContext
    ) throws -> ChatTargetMatch {
        try ChatEvidence.requireEditableChatCandidate(context)
        if let adapter = adapters.first(where: {
            $0.bundleIdentifiers.contains(bundleIdentifier)
        }) {
            return try adapter.classify(context: context)
        }
        return try generic.classify(context: context)
    }
}

private enum ChatEvidence {
    static let editableRoles = Set(["AXTextArea", "AXTextField"])
    static let denyTokens = [
        "search", "find", "terminal", "text editor", "code editor",
        "source control", "scm", "command palette", "password", "address",
        "account", "username", "email", "搜索", "查找", "终端", "代码",
        "编辑器", "密码", "地址", "账号", "用户名", "邮箱",
    ]
    static let chatTokens = [
        "chat", "message", "reply", "send", "conversation", "copilot",
        "聊天", "消息", "回复", "发送", "对话",
    ]
    static let strongChatTokens = [
        "chat", "reply", "conversation", "thread",
        "聊天", "回复", "对话", "会话",
    ]

    static func requireEditableChatCandidate(_ context: FocusedChatContext) throws {
        let focused = context.focused
        guard focused.enabled,
              focused.valueSettable,
              editableRoles.contains(focused.role ?? ""),
              !(focused.subrole?.lowercased().contains("secure") ?? false),
              !containsAny(denyTokens, in: context.evidence)
        else { throw ChatTargetClassificationError.unsupportedInputContext }
    }

    static func containsChatEvidence(_ context: FocusedChatContext) -> Bool {
        containsAny(chatTokens, in: context.evidence)
    }

    static func containsAny(
        _ tokens: [String],
        in elements: [ChatElementSummary]
    ) -> Bool {
        elements.flatMap(\.normalizedLabels).contains { label in
            tokens.contains { label.contains($0) }
        }
    }
}

private struct CodexChatTargetAdapter: ChatTargetAdapting {
    let bundleIdentifiers: Set<String> = ["com.openai.codex"]

    func classify(context: FocusedChatContext) throws -> ChatTargetMatch {
        let inMain = context.ancestors.contains {
            $0.role == "AXLandmarkMain" || $0.subrole == "AXLandmarkMain"
        }
        let hasNativeApproval = ChatEvidence.containsAny(
            ["approve", "allow", "批准", "允许"],
            in: context.nearby
        )
        guard (inMain || ChatEvidence.containsChatEvidence(context)),
              !hasNativeApproval
        else { throw ChatTargetClassificationError.unsupportedInputContext }
        return ChatTargetMatch(
            kind: .codex,
            placeholderDescription: context.focused.description
        )
    }
}

private struct VisualStudioCodeChatTargetAdapter: ChatTargetAdapting {
    let bundleIdentifiers: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
    ]

    func classify(context: FocusedChatContext) throws -> ChatTargetMatch {
        guard ChatEvidence.containsAny(
            ["chat", "copilot", "message", "聊天", "消息"],
            in: context.evidence
        ) else { throw ChatTargetClassificationError.unsupportedInputContext }
        return ChatTargetMatch(kind: .visualStudioCode)
    }
}

private struct WeChatTargetAdapter: ChatTargetAdapting {
    let bundleIdentifiers: Set<String> = ["com.tencent.xinWeChat"]

    func classify(context: FocusedChatContext) throws -> ChatTargetMatch {
        let isMessageEditor = context.focused.role == "AXTextArea"
        let hasMessageEvidence = ChatEvidence.containsAny(
            ["message", "send", "chat", "消息", "发送", "聊天"],
            in: context.evidence
        )
        guard isMessageEditor, hasMessageEvidence else {
            throw ChatTargetClassificationError.unsupportedInputContext
        }
        return ChatTargetMatch(kind: .weChat)
    }
}

private struct GenericChatTargetAdapter: ChatTargetAdapting {
    let bundleIdentifiers: Set<String> = []

    func classify(context: FocusedChatContext) throws -> ChatTargetMatch {
        guard ChatEvidence.containsAny(
            ChatEvidence.strongChatTokens,
            in: context.evidence
        ) else {
            throw ChatTargetClassificationError.unsupportedInputContext
        }
        return ChatTargetMatch(kind: .generic)
    }
}
```

- [ ] **Step 4: 运行分类器测试**

Run:

```bash
swift test --filter ChatTargetClassifierTests
```

Expected: PASS，7 个测试通过。

- [ ] **Step 5: 提交分类器**

```bash
git add Sources/CodexQuickOKApp/Automation/FocusedChatTarget.swift \
  Sources/CodexQuickOKApp/Automation/ChatTargetClassifier.swift \
  Tests/CodexQuickOKAppTests/ChatTargetClassifierTests.swift
git commit -m "feat(app): Add focused chat target classification"
```

---

### Task 2: 为 AccessibilityClient 增加焦点快照和 PID 定向输入

**Files:**
- Modify: `Sources/CodexQuickOKApp/Automation/FocusedChatTarget.swift`
- Modify: `Sources/CodexQuickOKApp/Automation/AccessibilityClient.swift`
- Modify: `Tests/CodexQuickOKAppTests/AccessibilityClientTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `FocusedChatContext` 和 `ChatElementSummary`。
- Produces: `FocusedTargetSnapshot`；`FocusedInputControlling.captureTarget()`、`revalidate(_:)`、`composerValue(in:)`、`setComposerValue(_:in:)`、`waitUntilComposerValue(_:in:timeout:)`、`pressReturn(in:)`。

- [ ] **Step 1: 写入焦点采集和发送原语的失败测试**

在 `AccessibilityClientTests` 新增下列测试。扩展现有 `FakeAccessibilitySystem`，使 composer 是
`focusedElementNode`，并为 window → main → composer 建立父链：

```swift
func testCapturesFrontmostFocusedElementWithoutActivatingAnotherApp() throws {
    let system = FakeAccessibilitySystem.validConversation(pid: 81)
    system.frontmostBundleIdentifier = "com.microsoft.VSCode"
    system.setFocusedPathToComposer()
    let client = AccessibilityClient(system: system, pollInterval: 0.01)

    let target = try client.captureTarget()

    XCTAssertEqual(target.processIdentifier, 81)
    XCTAssertEqual(target.bundleIdentifier, "com.microsoft.VSCode")
    XCTAssertTrue(system.elementsAreEqual(target.element, system.composer))
    XCTAssertEqual(system.activationRequests, [])
    XCTAssertEqual(target.context.focused.role, "AXTextArea")
    XCTAssertEqual(target.context.ancestors.map(\.role), ["AXGroup", "AXWindow"])
    XCTAssertTrue(target.context.nearby.contains { $0.title == "Send" })
}

func testCaptureFailsWhenFocusedElementIsNotInsideFocusedWindow() {
    let system = FakeAccessibilitySystem.validConversation(pid: 82)
    system.focusedElementNode = Node()
    let client = AccessibilityClient(system: system)

    XCTAssertThrowsError(try client.captureTarget()) { error in
        XCTAssertEqual(error as? AccessibilityClient.AXError, .focusedElementUnavailable)
    }
}

func testCaptureRejectsElementOwnedByAnotherPID() {
    let system = FakeAccessibilitySystem.validConversation(pid: 821)
    system.setFocusedPathToComposer()
    system.composer.processIdentifier = 999
    let client = AccessibilityClient(system: system)

    XCTAssertThrowsError(try client.captureTarget()) { error in
        XCTAssertEqual(error as? AccessibilityClient.AXError, .focusedElementUnavailable)
    }
}

func testRevalidationRejectsPIDWindowAndElementChanges() throws {
    let system = FakeAccessibilitySystem.validConversation(pid: 83)
    system.setFocusedPathToComposer()
    let client = AccessibilityClient(system: system)
    let target = try client.captureTarget()

    system.frontmostPID = 84
    XCTAssertThrowsError(try client.revalidate(target))
    system.frontmostPID = 83
    system.focusedWindowNode = system.alternateWindow
    XCTAssertThrowsError(try client.revalidate(target))
    system.focusedWindowNode = system.root
    system.focusedElementNode = system.sendButton
    XCTAssertThrowsError(try client.revalidate(target))
}

func testWritesConfirmsAndPostsOneReturnToCapturedPID() async throws {
    let system = FakeAccessibilitySystem.validConversation(pid: 85)
    system.setFocusedPathToComposer()
    let client = AccessibilityClient(system: system, pollInterval: 0.01)
    let target = try client.captureTarget()

    try client.setComposerValue("可", in: target)
    try await client.waitUntilComposerValue("可", in: target, timeout: 0.02)
    try client.pressReturn(in: target)

    XCTAssertEqual(system.storedComposerValue, "可")
    XCTAssertEqual(system.returnPIDs, [85])
}

func testValueMismatchTimesOutWithoutPostingReturn() async throws {
    let system = FakeAccessibilitySystem.validConversation(pid: 86)
    system.setFocusedPathToComposer()
    system.ignoreComposerWrites = true
    let client = AccessibilityClient(system: system, pollInterval: 0.01)
    let target = try client.captureTarget()

    try client.setComposerValue("可", in: target)
    do {
        try await client.waitUntilComposerValue("可", in: target, timeout: 0.01)
        XCTFail("Expected inserted value mismatch")
    } catch {
        XCTAssertEqual(error as? AccessibilityClient.AXError, .insertedValueMismatch)
    }
    XCTAssertEqual(system.returnPIDs, [])
}

func testSuccessfulNilValueIsEmptyButUnreadableOrNonStringValueFails() throws {
    XCTAssertEqual(
        try AccessibilityClient.validatedComposerValue(
            attributeReadSucceeded: true,
            value: nil
        ),
        ""
    )
    XCTAssertThrowsError(
        try AccessibilityClient.validatedComposerValue(
            attributeReadSucceeded: false,
            value: nil
        )
    )
    XCTAssertThrowsError(
        try AccessibilityClient.validatedComposerValue(
            attributeReadSucceeded: true,
            value: NSNumber(value: 0)
        )
    )
}
```

用上面的 `testSuccessfulNilValueIsEmptyButUnreadableOrNonStringValueFails` 替换现有
`testUnreadableOrNonStringComposerValueFailsClosed`；不得保留“成功读取到 nil 也失败”的旧断言。

给 fake provider 增加精确可观察字段和方法：

```swift
var focusedElementNode: Node?
var returnPIDs: [pid_t] = []
var ignoreComposerWrites = false

func focusedElement(processIdentifier: pid_t) throws -> AnyObject {
    guard processIdentifier == frontmostPID, let focusedElementNode else {
        throw AccessibilityClient.AXError.focusedElementUnavailable
    }
    return focusedElementNode
}

func processIdentifier(of element: AnyObject) throws -> pid_t {
    guard let pid = (element as! Node).processIdentifier else {
        throw AccessibilityClient.AXError.focusedElementUnavailable
    }
    return pid
}

func parent(of element: AnyObject) throws -> AnyObject? {
    (element as! Node).parent
}

func postReturn(processIdentifier: pid_t) throws {
    returnPIDs.append(processIdentifier)
}

func setFocusedPathToComposer() {
    focusedWindowNode = root
    focusedElementNode = composer
    root.processIdentifier = frontmostPID
    main.processIdentifier = frontmostPID
    composer.processIdentifier = frontmostPID
    sendButton.processIdentifier = frontmostPID
    main.parent = root
    composer.parent = main
    sendButton.parent = main
}
```

沿用 fake 已有的 `activationRequests`；把 `setComposerValue` 改为仅在
`ignoreComposerWrites == false` 时更新值。给 `Node` 增加：

```swift
weak var parent: Node?
var processIdentifier: pid_t?
```

- [ ] **Step 2: 运行新测试并确认失败**

Run:

```bash
swift test --filter AccessibilityClientTests
```

Expected: FAIL，缺少 `FocusedTargetSnapshot`、新 provider 方法和焦点输入 API。

- [ ] **Step 3: 定义快照与焦点输入协议**

追加到 `FocusedChatTarget.swift`：

```swift
struct FocusedTargetSnapshot {
    let processIdentifier: pid_t
    let bundleIdentifier: String
    let window: AnyObject
    let element: AnyObject
    let context: FocusedChatContext
}

@MainActor
protocol FocusedInputControlling: AnyObject {
    func captureTarget() throws -> FocusedTargetSnapshot
    func revalidate(_ target: FocusedTargetSnapshot) throws
    func composerValue(in target: FocusedTargetSnapshot) throws -> String
    func setComposerValue(_ value: String, in target: FocusedTargetSnapshot) throws
    func waitUntilComposerValue(
        _ expected: String,
        in target: FocusedTargetSnapshot,
        timeout: TimeInterval
    ) async throws
    func pressReturn(in target: FocusedTargetSnapshot) throws
}
```

- [ ] **Step 4: 扩展系统 provider 和错误类型**

在 `AccessibilitySystemProviding` 增加：

```swift
func focusedElement(processIdentifier: pid_t) throws -> AnyObject
func processIdentifier(of element: AnyObject) throws -> pid_t
func parent(of element: AnyObject) throws -> AnyObject?
func postReturn(processIdentifier: pid_t) throws
```

在 `AccessibilityClient.AXError` 增加并提供中文 `errorDescription`：

```swift
case frontmostTargetUnavailable
case focusedElementUnavailable
case targetChanged
case insertedValueMismatch
case returnDeliveryFailed
```

对应文案固定为：

```swift
case .frontmostTargetUnavailable:
    "找不到当前前台应用"
case .focusedElementUnavailable:
    "找不到当前光标输入框"
case .targetChanged:
    "当前应用、窗口或光标已经变化"
case .insertedValueMismatch:
    "无法确认“可”已经写入"
case .returnDeliveryFailed:
    "无法发送 Enter"
```

生产 provider 的实现固定使用 `kAXFocusedUIElementAttribute`、`kAXParentAttribute` 和 Return
虚拟键码 36：

```swift
func focusedElement(processIdentifier: pid_t) throws -> AnyObject {
    let application = AXUIElementCreateApplication(processIdentifier)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        application,
        kAXFocusedUIElementAttribute as CFString,
        &value
    ) == .success,
        let value,
        CFGetTypeID(value) == AXUIElementGetTypeID()
    else { throw AccessibilityClient.AXError.focusedElementUnavailable }
    return value as AnyObject
}

func processIdentifier(of element: AnyObject) throws -> pid_t {
    var pid: pid_t = 0
    guard AXUIElementGetPid(axElement(element), &pid) == .success, pid > 0 else {
        throw AccessibilityClient.AXError.focusedElementUnavailable
    }
    return pid
}

func parent(of element: AnyObject) throws -> AnyObject? {
    switch readAttribute(axElement(element), kAXParentAttribute as CFString) {
    case .absent:
        return nil
    case .failure:
        throw AccessibilityClient.AXError.invalidAccessibilityTree
    case .value(let value):
        guard CFGetTypeID(value as CFTypeRef) == AXUIElementGetTypeID() else {
            throw AccessibilityClient.AXError.invalidAccessibilityTree
        }
        return value as AnyObject
    }
}

func postReturn(processIdentifier: pid_t) throws {
    guard let source = CGEventSource(stateID: .hidSystemState),
          let down = CGEvent(
            keyboardEventSource: source,
            virtualKey: 36,
            keyDown: true
          ),
          let up = CGEvent(
            keyboardEventSource: source,
            virtualKey: 36,
            keyDown: false
          )
    else { throw AccessibilityClient.AXError.returnDeliveryFailed }
    down.postToPid(processIdentifier)
    up.postToPid(processIdentifier)
}
```

- [ ] **Step 5: 实现快照、有限上下文和重验**

让 `AccessibilityClient` 同时符合旧 `AccessibilityControlling` 和新
`FocusedInputControlling`，直到 Task 4 完成切换。新增常量：

```swift
static let maximumAncestorDepth = 12
static let maximumNearbyElementCount = 128
```

新增以下完整入口。`makeContext` 只读焦点元素、最多 12 层祖先和各层直接相邻元素的摘要；
`summary` 不读取 AXValue，因此不会读取其他输入框内容：

```swift
func captureTarget() throws -> FocusedTargetSnapshot {
    guard system.isProcessTrusted else { throw AXError.permissionMissing }
    guard let pid = system.frontmostPID,
          pid > 0,
          let bundleIdentifier = system.frontmostBundleIdentifier,
          !bundleIdentifier.isEmpty
    else { throw AXError.frontmostTargetUnavailable }

    let window = try system.focusedWindow(processIdentifier: pid)
    let element = try system.focusedElement(processIdentifier: pid)
    guard try system.processIdentifier(of: window) == pid,
          try system.processIdentifier(of: element) == pid
    else { throw AXError.focusedElementUnavailable }
    let context = try makeContext(focused: element, window: window)
    return FocusedTargetSnapshot(
        processIdentifier: pid,
        bundleIdentifier: bundleIdentifier,
        window: window,
        element: element,
        context: context
    )
}

func revalidate(_ target: FocusedTargetSnapshot) throws {
    guard system.frontmostPID == target.processIdentifier,
          system.frontmostBundleIdentifier == target.bundleIdentifier
    else { throw AXError.targetChanged }
    let window = try system.focusedWindow(
        processIdentifier: target.processIdentifier
    )
    let element = try system.focusedElement(
        processIdentifier: target.processIdentifier
    )
    guard try system.processIdentifier(of: window) == target.processIdentifier,
          try system.processIdentifier(of: element) == target.processIdentifier,
          system.elementsAreEqual(window, target.window),
          system.elementsAreEqual(element, target.element)
    else { throw AXError.targetChanged }
}

private func makeContext(
    focused: AnyObject,
    window: AnyObject
) throws -> FocusedChatContext {
    let focusedSummary = try chatSummary(of: focused)
    var ancestors: [ChatElementSummary] = []
    var nearby: [ChatElementSummary] = []
    var child = focused
    var reachedWindow = system.elementsAreEqual(focused, window)

    for _ in 0..<Self.maximumAncestorDepth where !reachedWindow {
        guard let parent = try system.parent(of: child) else { break }
        ancestors.append(try chatSummary(of: parent))
        for sibling in try system.children(of: parent)
        where !system.elementsAreEqual(sibling, child) {
            guard nearby.count < Self.maximumNearbyElementCount else {
                throw AXError.accessibilityTreeTruncated
            }
            nearby.append(try chatSummary(of: sibling))
        }
        reachedWindow = system.elementsAreEqual(parent, window)
        child = parent
    }

    guard reachedWindow else { throw AXError.focusedElementUnavailable }
    return FocusedChatContext(
        focused: focusedSummary,
        ancestors: ancestors,
        nearby: nearby
    )
}

private func chatSummary(of element: AnyObject) throws -> ChatElementSummary {
    let summary = try system.summary(of: element, parentIndex: nil)
    return ChatElementSummary(
        role: summary.role,
        subrole: summary.subrole,
        title: summary.title,
        description: summary.description,
        enabled: summary.enabled,
        valueSettable: summary.valueSettable
    )
}
```

- [ ] **Step 6: 实现读取、写入确认和 Enter**

新增方法必须每次使用快照中的原元素，并在破坏性动作前重验：

```swift
func composerValue(in target: FocusedTargetSnapshot) throws -> String {
    try system.composerValue(of: target.element)
}

func setComposerValue(
    _ value: String,
    in target: FocusedTargetSnapshot
) throws {
    try revalidate(target)
    try system.setComposerValue(value, on: target.element)
}

func waitUntilComposerValue(
    _ expected: String,
    in target: FocusedTargetSnapshot,
    timeout: TimeInterval
) async throws {
    let sleeps = max(0, Int(ceil(max(0, timeout) / pollInterval)))
    for attempt in 0...sleeps {
        try revalidate(target)
        if try system.composerValue(of: target.element) == expected { return }
        guard attempt < sleeps else { break }
        try await system.sleep(for: pollInterval)
    }
    throw AXError.insertedValueMismatch
}

func pressReturn(in target: FocusedTargetSnapshot) throws {
    try revalidate(target)
    do {
        try system.postReturn(processIdentifier: target.processIdentifier)
    } catch let error as AXError {
        throw error
    } catch {
        throw AXError.returnDeliveryFailed
    }
}
```

同时把 `validatedComposerValue` 的完整契约改为“成功读取到 nil 视为空，读取失败或非字符串拒绝”：

```swift
static func validatedComposerValue(
    attributeReadSucceeded: Bool,
    value: Any?
) throws -> String {
    guard attributeReadSucceeded else { throw AXError.composerValueUnreadable }
    guard let value else { return "" }
    guard let string = value as? String else {
        throw AXError.composerValueUnreadable
    }
    return string
}
```

- [ ] **Step 7: 运行 AccessibilityClient 全部测试**

Run:

```bash
swift test --filter AccessibilityClientTests
```

Expected: PASS；旧 Codex 测试、7 个新焦点测试和更新后的值读取测试同时通过，证明迁移期每个提交可编译。

- [ ] **Step 8: 提交焦点 AX 客户端**

```bash
git add Sources/CodexQuickOKApp/Automation/FocusedChatTarget.swift \
  Sources/CodexQuickOKApp/Automation/AccessibilityClient.swift \
  Tests/CodexQuickOKAppTests/AccessibilityClientTests.swift
git commit -m "feat(app): Add PID-bound focused input control"
```

---

### Task 3: 实现安全发送状态机

**Files:**
- Create: `Sources/CodexQuickOKApp/Automation/FocusedChatApprovalSender.swift`
- Create: `Tests/CodexQuickOKAppTests/FocusedChatApprovalSenderTests.swift`

**Interfaces:**
- Consumes: `FocusedInputControlling`、`ChatTargetClassifying` 和 `ChatTargetMatch.normalizedComposerValue(_:)`。
- Produces: `FocusedChatApprovalSender: CurrentApprovalSending`；每次成功调用固定产生一次写入和一次 Enter。

- [ ] **Step 1: 写入状态机失败测试**

创建 `FocusedChatApprovalSenderTests.swift`。fake input 记录严格事件顺序，并允许在两个重验点、
写入确认和 Return 注入错误：

```swift
import XCTest
@testable import CodexQuickOKApp

@MainActor
final class FocusedChatApprovalSenderTests: XCTestCase {
    func testSendsOneApprovalToStableEmptyFocusedChat() async throws {
        let input = FakeFocusedInput(value: "")
        let sender = FocusedChatApprovalSender(
            input: input,
            classifier: StubClassifier(match: .init(kind: .visualStudioCode))
        )

        try await sender.sendOK()

        XCTAssertEqual(input.events, [
            "capture", "read", "revalidate", "write:可",
            "wait:可:0.5", "revalidate", "return",
        ])
        XCTAssertEqual(input.returnCount, 1)
    }

    func testCodexPlaceholderIsAcceptedButDraftAndWhitespaceAroundTextAreRejected() async {
        for emptyValue in [" ", "\n\t"] {
            let empty = FakeFocusedInput(value: emptyValue)
            do {
                try await FocusedChatApprovalSender(
                    input: empty,
                    classifier: StubClassifier(match: .init(kind: .generic))
                ).sendOK()
            } catch {
                XCTFail("Expected whitespace-only composer to be empty: \(error)")
            }
            XCTAssertEqual(empty.returnCount, 1)
        }
        await assertRejectedBeforeWrite(
            value: "draft",
            match: .init(kind: .generic)
        )
        await assertRejectedBeforeWrite(
            value: " 可 ",
            match: .init(kind: .weChat)
        )
        let placeholder = FakeFocusedInput(value: "\nMessage Codex")
        let sender = FocusedChatApprovalSender(
            input: placeholder,
            classifier: StubClassifier(
                match: .init(kind: .codex, placeholderDescription: "Message Codex")
            )
        )
        do {
            try await sender.sendOK()
        } catch {
            XCTFail("Expected Codex placeholder to be empty: \(error)")
        }
    }

    func testClassificationFailureNeverReadsWritesOrReturns() async {
        let input = FakeFocusedInput(value: "")
        let sender = FocusedChatApprovalSender(
            input: input,
            classifier: StubClassifier(error: .unsupportedInputContext)
        )
        do { try await sender.sendOK(); XCTFail("Expected rejection") } catch {}
        XCTAssertEqual(input.events, ["capture"])
        XCTAssertEqual(input.returnCount, 0)
    }

    func testTargetChangeBeforeWriteAndBeforeReturnNeverReturns() async {
        for failingRevalidation in [1, 2] {
            let input = FakeFocusedInput(value: "")
            input.failRevalidation = failingRevalidation
            let sender = FocusedChatApprovalSender(
                input: input,
                classifier: StubClassifier(match: .init(kind: .generic))
            )
            do { try await sender.sendOK(); XCTFail("Expected target change") } catch {}
            XCTAssertEqual(input.returnCount, 0)
        }
    }

    func testWriteMismatchAndReturnFailureDoNotRetry() async {
        let mismatch = FakeFocusedInput(value: "")
        mismatch.waitError = AccessibilityClient.AXError.insertedValueMismatch
        do {
            try await FocusedChatApprovalSender(
                input: mismatch,
                classifier: StubClassifier(match: .init(kind: .generic))
            ).sendOK()
            XCTFail("Expected mismatch")
        } catch {}
        XCTAssertEqual(mismatch.returnCount, 0)

        let returnFailure = FakeFocusedInput(value: "")
        returnFailure.returnError = AccessibilityClient.AXError.returnDeliveryFailed
        do {
            try await FocusedChatApprovalSender(
                input: returnFailure,
                classifier: StubClassifier(match: .init(kind: .generic))
            ).sendOK()
            XCTFail("Expected Return failure")
        } catch {}
        XCTAssertEqual(returnFailure.returnAttempts, 1)
    }

    private func assertRejectedBeforeWrite(
        value: String,
        match: ChatTargetMatch
    ) async {
        let input = FakeFocusedInput(value: value)
        do {
            try await FocusedChatApprovalSender(
                input: input,
                classifier: StubClassifier(match: match)
            ).sendOK()
            XCTFail("Expected draft rejection")
        } catch {
            XCTAssertEqual(error as? FocusedChatSendError, .existingDraft)
        }
        XCTAssertFalse(input.events.contains(where: { $0.hasPrefix("write:") }))
        XCTAssertEqual(input.returnCount, 0)
    }
}
```

同一文件中的 fake 必须完整实现 Task 2 接口。使用 `NSObject()` 作为 window/element，固定
`bundleIdentifier = "example.chat"`，并按方法调用写入 `events`。`StubClassifier` 的实现固定为：

```swift
final class StubClassifier: ChatTargetClassifying {
    private let result: Result<ChatTargetMatch, ChatTargetClassificationError>

    init(match: ChatTargetMatch) { result = .success(match) }
    init(error: ChatTargetClassificationError) { result = .failure(error) }

    func classify(
        bundleIdentifier: String,
        context: FocusedChatContext
    ) throws -> ChatTargetMatch {
        try result.get()
    }
}
```

fake input 使用以下完整实现；`waitGate` 用于并发测试把第一笔调用挂在异步写入确认阶段：

```swift
@MainActor
private final class FakeFocusedInput: FocusedInputControlling {
    let window = NSObject()
    let element = NSObject()
    var value: String
    var events: [String] = []
    var failRevalidation: Int?
    var waitError: Error?
    var returnError: Error?
    var waitGate: (() async throws -> Void)?
    private(set) var returnAttempts = 0
    private(set) var returnCount = 0
    private var revalidationCount = 0

    init(value: String) { self.value = value }

    func captureTarget() throws -> FocusedTargetSnapshot {
        events.append("capture")
        return FocusedTargetSnapshot(
            processIdentifier: 91,
            bundleIdentifier: "example.chat",
            window: window,
            element: element,
            context: FocusedChatContext(
                focused: ChatElementSummary(
                    role: "AXTextArea",
                    subrole: nil,
                    title: nil,
                    description: "Write a message",
                    enabled: true,
                    valueSettable: true
                ),
                ancestors: [],
                nearby: []
            )
        )
    }

    func revalidate(_ target: FocusedTargetSnapshot) throws {
        revalidationCount += 1
        events.append("revalidate")
        if failRevalidation == revalidationCount {
            throw AccessibilityClient.AXError.targetChanged
        }
    }

    func composerValue(in target: FocusedTargetSnapshot) throws -> String {
        events.append("read")
        return value
    }

    func setComposerValue(
        _ value: String,
        in target: FocusedTargetSnapshot
    ) throws {
        events.append("write:\(value)")
        self.value = value
    }

    func waitUntilComposerValue(
        _ expected: String,
        in target: FocusedTargetSnapshot,
        timeout: TimeInterval
    ) async throws {
        events.append("wait:\(expected):\(timeout)")
        try await waitGate?()
        if let waitError { throw waitError }
        guard value == expected else {
            throw AccessibilityClient.AXError.insertedValueMismatch
        }
    }

    func pressReturn(in target: FocusedTargetSnapshot) throws {
        events.append("return")
        returnAttempts += 1
        if let returnError { throw returnError }
        returnCount += 1
    }
}
```

另外迁移现有并发用例，完整测试如下：

```swift
func testDuplicateInFlightCallAllowsOnlyFirstSend() async throws {
    let input = FakeFocusedInput(value: "")
    let gate = SenderGate()
    input.waitGate = { await gate.wait() }
    let sender = FocusedChatApprovalSender(
        input: input,
        classifier: StubClassifier(match: .init(kind: .generic))
    )
    let first = Task { try await sender.sendOK() }
    await waitUntil { input.events.contains("wait:可:0.5") }

    do {
        try await sender.sendOK()
        XCTFail("Expected in-progress rejection")
    } catch {
        XCTAssertEqual(error as? FocusedChatSendError, .inProgress)
    }

    gate.release()
    try await first.value
    XCTAssertEqual(input.returnCount, 1)
}

@MainActor
private final class SenderGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
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

- [ ] **Step 2: 运行测试并确认失败**

Run:

```bash
swift test --filter FocusedChatApprovalSenderTests
```

Expected: FAIL，缺少 `FocusedChatApprovalSender` 和 `FocusedChatSendError`。

- [ ] **Step 3: 实现状态机**

创建 `FocusedChatApprovalSender.swift`。迁移期复用旧文件中的 `CurrentApprovalSending` 协议，
Task 4 再移动协议所有权：

```swift
import Foundation

enum FocusedChatSendError: Error, Equatable, LocalizedError {
    case inProgress
    case existingDraft

    var errorDescription: String? {
        switch self {
        case .inProgress:
            "上一次发送仍在进行，请稍后重试"
        case .existingDraft:
            "检测到未发送草稿"
        }
    }
}

@MainActor
final class FocusedChatApprovalSender: CurrentApprovalSending {
    private let input: any FocusedInputControlling
    private let classifier: any ChatTargetClassifying
    private var sending = false

    init(
        input: any FocusedInputControlling,
        classifier: any ChatTargetClassifying
    ) {
        self.input = input
        self.classifier = classifier
    }

    func sendOK() async throws {
        guard !sending else { throw FocusedChatSendError.inProgress }
        sending = true
        defer { sending = false }

        let target = try input.captureTarget()
        let match = try classifier.classify(
            bundleIdentifier: target.bundleIdentifier,
            context: target.context
        )
        let rawValue = try input.composerValue(in: target)
        let value = match.normalizedComposerValue(rawValue)
        guard value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FocusedChatSendError.existingDraft
        }

        try input.revalidate(target)
        try input.setComposerValue("可", in: target)
        try await input.waitUntilComposerValue("可", in: target, timeout: 0.5)
        try input.revalidate(target)
        try input.pressReturn(in: target)
    }
}
```

- [ ] **Step 4: 运行发送器测试**

Run:

```bash
swift test --filter FocusedChatApprovalSenderTests
```

Expected: PASS，包括正常、占位符、草稿、分类失败、两次焦点竞争、写入不一致、Return 失败和
重复并发调用。

- [ ] **Step 5: 提交状态机**

```bash
git add Sources/CodexQuickOKApp/Automation/FocusedChatApprovalSender.swift \
  Tests/CodexQuickOKAppTests/FocusedChatApprovalSenderTests.swift
git commit -m "feat(app): Add focused chat approval sender"
```

---

### Task 4: 切换运行时并删除 Codex 专用旧链路

**Files:**
- Modify: `Sources/CodexQuickOKApp/AppDelegate.swift`
- Modify: `Sources/CodexQuickOKApp/ManualApprovalController.swift`
- Modify: `Sources/CodexQuickOKApp/Automation/FocusedChatApprovalSender.swift`
- Modify: `Sources/CodexQuickOKApp/Automation/AccessibilityClient.swift`
- Modify: `Tests/CodexQuickOKAppTests/AccessibilityClientTests.swift`
- Modify: `Tests/CodexQuickOKAppTests/ManualApprovalControllerTests.swift`
- Delete: `Sources/CodexQuickOKApp/Automation/CurrentCodexAutomation.swift`
- Delete: `Sources/CodexQuickOKApp/Automation/CurrentWindowApprovalSender.swift`
- Delete: `Sources/CodexQuickOKCore/SendSafety.swift`
- Delete: `Tests/CodexQuickOKAppTests/CurrentWindowApprovalSenderTests.swift`
- Delete: `Tests/CodexQuickOKCoreTests/SendSafetyTests.swift`

**Interfaces:**
- Consumes: Task 1–3 的分类器、焦点输入客户端和发送器。
- Produces: 应用启动后的唯一发送路径 `ManualApprovalController → FocusedChatApprovalSender → AccessibilityClient`。

- [ ] **Step 1: 先迁移控制器错误测试**

在 `ManualApprovalControllerTests.testFailureUsesLocalizedMessageAndDoesNotRetry` 中把错误改为：

```swift
let sender = StubSender(error: FocusedChatSendError.existingDraft)
```

新增未知错误回退文案测试：

```swift
func testUnknownFailureMentionsCurrentChatInsteadOfCodex() async {
    struct UnknownError: Error {}
    let panel = RecordingPanel()
    let controller = ManualApprovalController(
        panel: panel,
        sender: StubSender(error: UnknownError())
    )

    controller.start()
    panel.onActivate?()
    await waitUntil { !panel.failures.isEmpty }

    XCTAssertEqual(panel.failures, ["发送失败，请检查当前聊天框"])
}

func testDiagnosticCodeDoesNotContainErrorPayload() {
    struct PayloadError: Error { let message: String }
    let code = ManualApprovalController.diagnosticCode(
        for: PayloadError(message: "private draft text")
    )

    XCTAssertTrue(code.contains("PayloadError"))
    XCTAssertFalse(code.contains("private draft text"))
}
```

- [ ] **Step 2: 运行迁移测试并确认旧文案失败**

Run:

```bash
swift test --filter ManualApprovalControllerTests
```

Expected: FAIL，未知错误仍返回“发送失败，请检查 Codex”。

- [ ] **Step 3: 切换 AppDelegate 和通用错误文案**

把 `AppDelegate.applicationDidFinishLaunching` 中三行运行时装配替换为：

```swift
let panel = FloatingPanelController()
let accessibility = AccessibilityClient()
let sender = FocusedChatApprovalSender(
    input: accessibility,
    classifier: ChatTargetClassifier()
)
configureManualRuntime(panel: panel, sender: sender)
```

把 `ManualApprovalController` 的未知错误回退文案替换为：

```swift
let message = (error as? LocalizedError)?.errorDescription
    ?? "发送失败，请检查当前聊天框"
```

同时把原来的 `NSLog(... String(describing: error))` 改为只记录无载荷诊断码：

```swift
static func diagnosticCode(for error: Error) -> String {
    switch error {
    case let error as AccessibilityClient.AXError:
        "accessibility.\(String(describing: error))"
    case let error as ChatTargetClassificationError:
        "classification.\(String(describing: error))"
    case let error as FocusedChatSendError:
        "send.\(String(describing: error))"
    default:
        String(reflecting: type(of: error))
    }
}
```

```swift
NSLog("可 send failed: %@", Self.diagnosticCode(for: error))
```

该 helper 不接受输入框值、窗口标题或聊天对象，未知错误也只记录类型名。

把 `CurrentApprovalSending` 协议移动到 `FocusedChatApprovalSender.swift` 的最上方，保持签名不变：

```swift
@MainActor
protocol CurrentApprovalSending: AnyObject {
    func sendOK() async throws
}
```

- [ ] **Step 4: 删除旧发送器、安全门和只为旧链路存在的测试**

删除文件结构中列出的 5 个旧文件。随后从 `AccessibilityClient.swift` 删除以下旧符号及其专用
缓存字段，但保留 Task 2 使用的 `validatedChildren`、`mergedChildren`、`validatedSummary`、
`validatedComposerValue`、`SystemAccessibilityProvider.children`、`summary`、`composerValue` 和
`setComposerValue`：

```text
AccessibilityControlling
AccessibilityClient.RunningApplication
AccessibilityClient.ControlSelection
AccessibilityClient.ComposerSelection
prepareFocusedConversation(timeout:)
revalidateFocusedConversation()
frontmostBundleIdentifier()
composerValue()
setComposerValue(_:)
waitUntilSendEnabled(timeout:)
pressSend()
selectControls(in:)
selectComposer(in:)
selectFocusedConversationControls(in:)
selectFocusedConversationComposer(in:)
waitUntilFrontmost(pid:timeout:)
locateFocusedConversation(pid:timeout:)
refreshFocusedConversationControls()
refreshFocusedConversationComposer()
elementTree(pid:)
isNativeApprovalControl(_:)
isSendButton(_:)
```

同步从 `AccessibilitySystemProviding` 和生产 provider 删除不再使用的：

```text
runningApplications(bundleIdentifier:)
activate(processIdentifier:)
press(_:)
```

把 `AccessibilityClientTests` 中仅测试旧 Codex 激活、全窗口 composer/send button 选择和发送按钮
等待的用例删除；保留底层 AX 属性校验、合并 children、值读取失败以及 Task 2 新增焦点测试。

- [ ] **Step 5: 证明旧硬编码已离开运行路径**

Run:

```bash
rg -n 'CurrentCodex|CurrentWindowApproval|prepareFocusedConversation|pressSend|waitUntilSendEnabled|SendSafety' Sources Tests
```

Expected: 无输出、exit 1。

- [ ] **Step 6: 运行全部 Swift 测试**

Run:

```bash
swift test
```

Expected: exit 0，0 failures；两个 opt-in live probe 可显示 skipped。

- [ ] **Step 7: 提交运行时切换**

```bash
git add -A Sources Tests
git commit -m "ref(app): Replace Codex-only send pipeline"
```

---

### Task 5: 增加安全实机探针并更新用户文档

**Files:**
- Modify: `Tests/CodexQuickOKAppTests/LiveSendPipelineProbeTests.swift`
- Modify: `README.md`
- Modify: `docs/manual-verification.md`

**Interfaces:**
- Consumes: 最终 `AccessibilityClient`、`ChatTargetClassifier` 和 `FocusedChatApprovalSender` 行为。
- Produces: 不发送真实消息的通用焦点探针；Codex、VS Code、微信和未知应用的人工验收清单。

- [ ] **Step 1: 把 live probe 改成当前焦点、默认不发送**

用以下两个 opt-in 测试替换 Codex 专用 probe。环境变量名固定为
`KE_FOCUSED_CHAT_LIVE_TESTS` 和 `KE_EXPECTED_BUNDLE_ID`：

```swift
@MainActor
func testLiveFocusedTargetClassification() async throws {
    guard ProcessInfo.processInfo.environment["KE_FOCUSED_CHAT_LIVE_TESTS"] == "1"
    else { throw XCTSkip("Set KE_FOCUSED_CHAT_LIVE_TESTS=1") }
    try await Task.sleep(for: .seconds(3))
    let expected = try XCTUnwrap(
        ProcessInfo.processInfo.environment["KE_EXPECTED_BUNDLE_ID"]
    )
    let client = AccessibilityClient()
    let target = try client.captureTarget()
    let match = try ChatTargetClassifier().classify(
        bundleIdentifier: target.bundleIdentifier,
        context: target.context
    )

    XCTAssertEqual(target.bundleIdentifier, expected)
    print("LIVE_FOCUSED_TARGET bundle=\(target.bundleIdentifier) kind=\(match.kind)")
}

@MainActor
func testLiveTextPipelineStopsBeforeReturn() async throws {
    guard ProcessInfo.processInfo.environment["KE_FOCUSED_CHAT_LIVE_TESTS"] == "1"
    else { throw XCTSkip("Set KE_FOCUSED_CHAT_LIVE_TESTS=1") }
    try await Task.sleep(for: .seconds(3))
    let expected = try XCTUnwrap(
        ProcessInfo.processInfo.environment["KE_EXPECTED_BUNDLE_ID"]
    )
    let client = AccessibilityClient()
    let target = try client.captureTarget()
    let match = try ChatTargetClassifier().classify(
        bundleIdentifier: target.bundleIdentifier,
        context: target.context
    )
    XCTAssertEqual(target.bundleIdentifier, expected)
    let initial = match.normalizedComposerValue(try client.composerValue(in: target))
    XCTAssertTrue(initial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    defer { try? client.setComposerValue("", in: target) }

    try client.setComposerValue("探针", in: target)
    try await client.waitUntilComposerValue("探针", in: target, timeout: 0.5)
    XCTAssertEqual(try client.composerValue(in: target), "探针")
}
```

这两个测试不得调用 `pressReturn(in:)`。实机“发送”只允许通过用户亲自点击悬浮按钮验证。

- [ ] **Step 2: 更新 README 的产品说明和限制**

把开头说明和使用步骤改为以下事实，不保留“自动激活最近 Codex 窗口”的旧描述：

```markdown
# 可

一个跟随当前光标、向空聊天输入框发送“可”的 macOS 悬浮按钮。

## 使用

1. 在 Codex、Visual Studio Code 侧边栏聊天、微信或其他受支持聊天应用中聚焦空输入框。
2. 点击悬浮“可”。
3. 应用确认当前焦点属于聊天框后输入“可”，再向同一应用发送 Enter。

已有草稿、代码编辑器、终端、搜索框、密码框和普通表单会闪红并拒绝操作。发送统一使用
Enter；如果目标应用把 Enter 配置为换行，本工具也只会换行。
```

保留现有安装、卸载、Accessibility 权限、额度和许可证命令；只替换行为说明。

- [ ] **Step 3: 重写 manual verification 场景**

在 `docs/manual-verification.md` 保留自动构建/签名表，替换发送相关行并加入：

```markdown
| 4 | Codex 空 composer 输入并发送一次“可” | PENDING (manual) |
| 5 | Codex 闲置后占位符仍视为空 | PENDING (manual) |
| 6 | VS Code 侧边栏聊天空 composer 输入并发送一次“可” | PENDING (manual) |
| 7 | VS Code 编辑器、终端和搜索框闪红且无输入 | PENDING (manual) |
| 8 | 微信测试会话空消息框输入并发送一次“可” | PENDING (manual) |
| 9 | 微信搜索框闪红且无输入 | PENDING (manual) |
| 10 | 三个应用已有草稿时内容不变且不发送 | PASS (automatic) |
| 11 | 点击期间切换焦点时不投递 Enter | PASS (automatic) |
| 12 | 未知应用只有明确聊天语义时允许 | PASS (automatic) |
| 13 | Enter 配置为换行时不改用其他快捷键 | PENDING (manual) |
```

在表后写明：微信只能使用测试联系人或“文件传输助手”，VS Code/Codex 只能使用专门测试会话；
不得向真实联系人、工作群或生产任务执行发送验收。

- [ ] **Step 4: 运行测试和文档静态检查**

Run:

```bash
swift test
rg -n '激活最近|只向 Codex|检查 Codex' README.md docs/manual-verification.md Sources
```

Expected: `swift test` exit 0；`rg` 无旧行为描述输出。

- [ ] **Step 5: 提交探针和文档**

```bash
git add Tests/CodexQuickOKAppTests/LiveSendPipelineProbeTests.swift \
  README.md docs/manual-verification.md
git commit -m "docs: Document focused cross-app sending"
```

---

### Task 6: 完整验证、构建安装和真实应用验收

**Files:**
- Verify only: `Package.swift`
- Verify only: `Resources/Info.plist`
- Verify only: `scripts/build-release.sh`
- Verify only: `scripts/install-local.sh`
- Verify only: `/Users/x/Applications/Codex 可.app`

**Interfaces:**
- Consumes: Task 1–5 的最终提交。
- Produces: 已签名、已安装、通过自动测试和用户控制实测的本地应用；本任务不产生源代码提交。

- [ ] **Step 1: 运行完整自动验证**

Run:

```bash
swift test
zsh Tests/PackagingTests.sh
zsh Tests/AppIconTests.sh
zsh Tests/SigningTests.sh
zsh Tests/BuildReleaseTests.sh
```

Expected: 全部 exit 0；Swift 0 failures；shell 测试分别输出各自 `passed` 文案。

- [ ] **Step 2: 构建并验证签名**

Run:

```bash
zsh scripts/build-release.sh
codesign --verify --deep --strict 'dist/Codex 可.app'
```

Expected: 构建完成，`codesign` exit 0。

- [ ] **Step 3: 安装到用户应用目录**

Run:

```bash
zsh scripts/install-local.sh
```

Expected: 旧 `Codex 可` 进程被安全终止，新应用原子替换到
`/Users/x/Applications/Codex 可.app` 并重新打开；安装失败时脚本恢复旧版本。

- [ ] **Step 4: 对三个应用运行无发送 probe**

分别启动命令，并在 3 秒倒计时内把光标放入对应空聊天输入框。每个应用只运行包含分类和写入
确认的无发送测试：

```bash
KE_FOCUSED_CHAT_LIVE_TESTS=1 \
KE_EXPECTED_BUNDLE_ID=com.openai.codex \
swift test --filter LiveSendPipelineProbeTests/testLiveTextPipelineStopsBeforeReturn

KE_FOCUSED_CHAT_LIVE_TESTS=1 \
KE_EXPECTED_BUNDLE_ID=com.microsoft.VSCode \
swift test --filter LiveSendPipelineProbeTests/testLiveTextPipelineStopsBeforeReturn

KE_FOCUSED_CHAT_LIVE_TESTS=1 \
KE_EXPECTED_BUNDLE_ID=com.tencent.xinWeChat \
swift test --filter LiveSendPipelineProbeTests/testLiveTextPipelineStopsBeforeReturn
```

Expected: 每组识别正确 Bundle ID 和 kind；输入“探针”后清空；没有 Return、没有消息发送。

- [ ] **Step 5: 由用户点击完成真实发送验收**

严格按 `docs/manual-verification.md`，只使用测试会话：

1. Codex 空 composer 点击“可”，确认只发送一次；闲置后再次确认。
2. VS Code 侧边栏聊天空 composer 点击“可”，确认只发送一次。
3. VS Code 编辑器、终端、搜索框分别聚焦后点击，确认闪红且零输入。
4. 微信“文件传输助手”空消息框点击“可”，确认只发送一次。
5. 微信搜索框聚焦后点击，确认闪红且零输入。
6. 三个应用各保留一段草稿后点击，确认草稿完全不变。
7. 点击瞬间切换窗口或焦点，确认不投递 Enter。

- [ ] **Step 6: 最终仓库检查**

Run:

```bash
git status --short
git log --oneline -6
```

Expected: `git status --short` 无输出；日志包含本计划的 5 个实现/文档提交和计划文档提交。

## 计划自检映射

- 规格 §2–§3（边界与非目标）：Global Constraints、Task 1、Task 3。
- 规格 §4（用户体验）：Task 3 状态机、Task 4 控制器反馈、Task 5 文档。
- 规格 §5.1–§5.5（组件、快照、分类、空值、输入）：Task 1–Task 4。
- 规格 §6（错误与日志）：Task 1/Task 3 的 LocalizedError；Task 4 保留控制器仅记录错误类型。
- 规格 §7（代码结构）：文件结构和 Task 4 清理。
- 规格 §8–§9（测试与验收）：各任务 TDD、Task 5 probe、Task 6 全量与实机验收。
- 规格 §10（风险）：保守分类、上下文上限、元素身份重验、值确认和统一 Enter 限制均有测试。
