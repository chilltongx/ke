# Codex Auto-Focus First Input Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the macOS floating “可” button focus the first editable input in the frontmost Codex window when no editable input currently has focus, then run the existing guarded send flow.

**Architecture:** Keep target recovery inside `AccessibilityClient.captureTarget()`. Preserve the current focused-input path for every app; only frontmost `com.openai.codex` may scan and focus the first editable descendant. After focus assignment, re-read the frontmost app, focused window, and focused element before returning the existing `FocusedTargetSnapshot`, so classification, empty-draft checks, insertion confirmation, and Enter delivery remain unchanged.

**Tech Stack:** Swift 6, AppKit, macOS Accessibility API (`AXUIElement`), CoreGraphics keyboard events, XCTest, Swift Package Manager.

## Global Constraints

- Platform scope is macOS only; Windows behavior must not change.
- Auto-focus is enabled only for frontmost Bundle ID `com.openai.codex`.
- Scan only the current focused Codex window, in existing merged Accessibility child order.
- Select the first enabled, value-settable `AXTextArea` or `AXTextField`; do not require uniqueness.
- Preserve the existing Codex classifier after selection.
- Preserve existing draft, PID, window, element, write-confirmation, and single-Enter checks.
- Do not cache an old element, switch applications, use screen coordinates, or retry a send.
- Stop after inspecting 2,048 elements and fail closed.

---

## File Structure

- `Sources/CodexQuickOKApp/Automation/AccessibilityClient.swift`: add the narrow focus-assignment system interface and Codex-only first-editable target recovery.
- `Tests/CodexQuickOKAppTests/AccessibilityClientTests.swift`: model focus assignment and cover selection order, app scope, bounds, assignment failures, and post-focus races.
- `README.md`: explain the Codex no-focus behavior and retained classifier/draft safeguards.
- `docs/manual-verification.md`: add real Codex acceptance checks without automating Enter.

### Task 1: Recover the first editable Codex input

**Files:**
- Modify: `Tests/CodexQuickOKAppTests/AccessibilityClientTests.swift:47-301`
- Modify: `Tests/CodexQuickOKAppTests/AccessibilityClientTests.swift:318-551`
- Modify: `Sources/CodexQuickOKApp/Automation/AccessibilityClient.swift:5-26`
- Modify: `Sources/CodexQuickOKApp/Automation/AccessibilityClient.swift:103-180`
- Modify: `Sources/CodexQuickOKApp/Automation/AccessibilityClient.swift:349-371`
- Modify: `Sources/CodexQuickOKApp/Automation/AccessibilityClient.swift:467-710`

**Interfaces:**
- Consumes: `AccessibilitySystemProviding.children(of:)`, `summary(of:parentIndex:)`, `focusedElement(processIdentifier:)`, and `elementsAreEqual(_:_:)`.
- Produces: `AccessibilitySystemProviding.setFocusedElement(_ element: AnyObject) throws`.
- Produces: unchanged public behavior of `AccessibilityClient.captureTarget() throws -> FocusedTargetSnapshot`.

- [ ] **Step 1: Add failing target-recovery tests**

Add these tests inside `AccessibilityClientTests` before `assertTargetChanged`:

```swift
func testCodexAutoFocusesComposerWhenNoElementIsFocused() throws {
    let system = FakeAccessibilitySystem.validConversation(pid: 870)
    system.focusedElementNode = nil
    system.composer.isFocused = false

    let target = try AccessibilityClient(system: system).captureTarget()

    XCTAssertTrue(system.elementsAreEqual(target.element, system.composer))
    XCTAssertEqual(system.focusAttempts.count, 1)
    XCTAssertTrue(system.focusAttempts[0] === system.composer)
}

func testCodexAutoFocusesComposerWhenButtonOwnsFocus() throws {
    let system = FakeAccessibilitySystem.validConversation(pid: 871)
    system.focusedElementNode = system.sendButton

    let target = try AccessibilityClient(system: system).captureTarget()

    XCTAssertTrue(system.elementsAreEqual(target.element, system.composer))
    XCTAssertTrue(system.focusAttempts.first === system.composer)
}

func testCodexAutoFocusUsesFirstEditableInputInTraversalOrder() throws {
    let system = FakeAccessibilitySystem.validConversation(pid: 872)
    let firstInput = system.addEditableInputBeforeComposer(title: "Unlabeled input")
    system.focusedElementNode = nil

    let target = try AccessibilityClient(system: system).captureTarget()

    XCTAssertTrue(system.elementsAreEqual(target.element, firstInput))
    XCTAssertTrue(system.focusAttempts.first === firstInput)
}

func testExistingEditableFocusIsNeverReplaced() throws {
    let system = FakeAccessibilitySystem.validConversation(pid: 873)
    _ = system.addEditableInputBeforeComposer(title: "Earlier input")
    system.focusedElementNode = system.composer

    let target = try AccessibilityClient(system: system).captureTarget()

    XCTAssertTrue(system.elementsAreEqual(target.element, system.composer))
    XCTAssertTrue(system.focusAttempts.isEmpty)
}

func testNonCodexAppNeverAutoFocusesAnInput() {
    let system = FakeAccessibilitySystem.validConversation(pid: 874)
    system.frontmostBundleIdentifier = "com.microsoft.VSCode"
    system.focusedElementNode = nil
    system.composer.isFocused = false

    XCTAssertThrowsError(
        try AccessibilityClient(system: system).captureTarget()
    ) { error in
        XCTAssertEqual(
            error as? AccessibilityClient.AXError,
            .focusedElementUnavailable
        )
    }
    XCTAssertTrue(system.focusAttempts.isEmpty)
}

func testAutoFocusRequiresAssignmentToTakeEffect() {
    let system = FakeAccessibilitySystem.validConversation(pid: 875)
    system.focusedElementNode = system.sendButton
    system.ignoreFocusAssignment = true

    XCTAssertThrowsError(
        try AccessibilityClient(system: system).captureTarget()
    ) { error in
        XCTAssertEqual(error as? AccessibilityClient.AXError, .targetChanged)
    }
    XCTAssertEqual(system.focusAttempts.count, 1)
}

func testAutoFocusPropagatesAssignmentFailure() {
    let system = FakeAccessibilitySystem.validConversation(pid: 876)
    system.focusedElementNode = system.sendButton
    system.focusError = AccessibilityClient.AXError.focusedElementUnavailable

    XCTAssertThrowsError(
        try AccessibilityClient(system: system).captureTarget()
    ) { error in
        XCTAssertEqual(
            error as? AccessibilityClient.AXError,
            .focusedElementUnavailable
        )
    }
    XCTAssertEqual(system.focusAttempts.count, 1)
}

func testAutoFocusRejectsWindowChangeDuringAssignment() {
    let system = FakeAccessibilitySystem.validConversation(pid: 877)
    system.focusedElementNode = system.sendButton
    system.afterFocusAttempt = {
        system.focusedWindowNode = system.alternateWindow
    }

    XCTAssertThrowsError(
        try AccessibilityClient(system: system).captureTarget()
    ) { error in
        XCTAssertEqual(error as? AccessibilityClient.AXError, .targetChanged)
    }
}

func testAutoFocusScanStopsAtElementLimit() {
    let system = FakeAccessibilitySystem.validConversation(pid: 878)
    system.focusedElementNode = system.root
    system.replaceWindowChildrenWithNonEditableNodes(
        count: AccessibilityClient.maximumFocusedElementScanCount + 1
    )

    XCTAssertThrowsError(
        try AccessibilityClient(system: system).captureTarget()
    ) { error in
        XCTAssertEqual(
            error as? AccessibilityClient.AXError,
            .accessibilityTreeTruncated
        )
    }
    XCTAssertTrue(system.focusAttempts.isEmpty)
}
```

Extend `FakeAccessibilitySystem` with focus state and deterministic tree helpers:

```swift
var focusError: Error?
var ignoreFocusAssignment = false
var afterFocusAttempt: (() -> Void)?
private(set) var focusAttempts: [Node] = []

func setFocusedElement(_ element: AnyObject) throws {
    let node = element as! Node
    focusAttempts.append(node)
    if let focusError { throw focusError }
    guard !ignoreFocusAssignment else { return }
    focusedElementNode?.isFocused = false
    node.isFocused = true
    focusedElementNode = node
    afterFocusAttempt?()
}

func addEditableInputBeforeComposer(title: String) -> Node {
    let input = Node(processIdentifier: frontmostPID)
    input.parent = main
    childrenByNode[ObjectIdentifier(input)] = []
    summariesByNode[ObjectIdentifier(input)] = makeSummary(
        role: "AXTextField",
        title: title,
        valueSettable: true
    )
    childrenByNode[ObjectIdentifier(main)] = [
        input,
        composer,
        sendButton,
    ]
    return input
}

func replaceWindowChildrenWithNonEditableNodes(count: Int) {
    let nodes = (0..<count).map { _ in
        Node(processIdentifier: frontmostPID)
    }
    childrenByNode[ObjectIdentifier(root)] = nodes
    for node in nodes {
        node.parent = root
        childrenByNode[ObjectIdentifier(node)] = []
        summariesByNode[ObjectIdentifier(node)] = makeSummary(role: "AXGroup")
    }
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
swift test --filter AccessibilityClientTests
```

Expected: the new Codex tests fail because `captureTarget()` still returns or rejects the old focused element and never records `focusAttempts`.

- [ ] **Step 3: Add the focus-assignment interface and Codex capture policy**

Add the system interface method:

```swift
func setFocusedElement(_ element: AnyObject) throws
```

Add these constants beside the current scan limits:

```swift
static let codexBundleIdentifier = "com.openai.codex"
static let editableInputRoles = Set([
    kAXTextAreaRole as String,
    kAXTextFieldRole as String,
])
```

Replace the direct `resolveFocusedElement` call in `captureTarget()` with:

```swift
let element = try captureElement(
    processIdentifier: pid,
    bundleIdentifier: bundleIdentifier,
    window: window
)
```

Add these private methods before `resolveFocusedElement`:

```swift
private func captureElement(
    processIdentifier: pid_t,
    bundleIdentifier: String,
    window: AnyObject
) throws -> AnyObject {
    let current: AnyObject?
    do {
        current = try resolveFocusedElement(
            processIdentifier: processIdentifier,
            window: window
        )
    } catch AXError.focusedElementUnavailable {
        current = nil
    }

    if let current {
        if try isEditableInput(
            current,
            expectedProcessIdentifier: processIdentifier
        ) {
            return current
        }
        guard bundleIdentifier == Self.codexBundleIdentifier else {
            return current
        }
    } else if bundleIdentifier != Self.codexBundleIdentifier {
        throw AXError.focusedElementUnavailable
    }

    return try focusFirstEditableInput(
        processIdentifier: processIdentifier,
        bundleIdentifier: bundleIdentifier,
        window: window
    )
}

private func isEditableInput(
    _ element: AnyObject,
    expectedProcessIdentifier: pid_t
) throws -> Bool {
    guard try system.processIdentifier(of: element)
        == expectedProcessIdentifier else {
        throw AXError.focusedElementUnavailable
    }
    let summary = try system.summary(of: element, parentIndex: nil)
    return summary.enabled
        && summary.valueSettable
        && Self.editableInputRoles.contains(summary.role ?? "")
}

private func focusFirstEditableInput(
    processIdentifier: pid_t,
    bundleIdentifier: String,
    window: AnyObject
) throws -> AnyObject {
    var queue = try system.children(of: window)
    var offset = 0

    while offset < queue.count {
        guard offset < Self.maximumFocusedElementScanCount else {
            throw AXError.accessibilityTreeTruncated
        }
        let candidate = queue[offset]
        offset += 1

        if try isEditableInput(
            candidate,
            expectedProcessIdentifier: processIdentifier
        ) {
            try system.setFocusedElement(candidate)
            return try confirmAutoFocusedElement(
                candidate,
                processIdentifier: processIdentifier,
                bundleIdentifier: bundleIdentifier,
                window: window
            )
        }
        queue.append(contentsOf: try system.children(of: candidate))
    }
    throw AXError.focusedElementUnavailable
}

private func confirmAutoFocusedElement(
    _ candidate: AnyObject,
    processIdentifier: pid_t,
    bundleIdentifier: String,
    window: AnyObject
) throws -> AnyObject {
    guard system.frontmostPID == processIdentifier,
          system.frontmostBundleIdentifier == bundleIdentifier
    else {
        throw AXError.targetChanged
    }

    let latestWindow: AnyObject
    let latestElement: AnyObject
    do {
        latestWindow = try system.focusedWindow(
            processIdentifier: processIdentifier
        )
        latestElement = try resolveFocusedElement(
            processIdentifier: processIdentifier,
            window: latestWindow
        )
    } catch {
        throw AXError.targetChanged
    }

    guard system.elementsAreEqual(latestWindow, window),
          system.elementsAreEqual(latestElement, candidate),
          try system.processIdentifier(of: latestElement) == processIdentifier
    else {
        throw AXError.targetChanged
    }
    return candidate
}
```

Implement the system provider method without changing application activation:

```swift
func setFocusedElement(_ element: AnyObject) throws {
    guard AXUIElementSetAttributeValue(
        axElement(element),
        kAXFocusedAttribute as CFString,
        kCFBooleanTrue
    ) == .success else {
        throw AccessibilityClient.AXError.focusedElementUnavailable
    }
}
```

Keep the existing focus write inside `setComposerValue`; it remains a final insertion-time safeguard.

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run:

```bash
swift test --filter AccessibilityClientTests
```

Expected: all `AccessibilityClientTests` pass with 0 failures.

- [ ] **Step 5: Run sender and classifier regression tests**

Run:

```bash
swift test --filter FocusedChatApprovalSenderTests
swift test --filter ChatTargetClassifierTests
```

Expected: both suites pass. Existing Codex search-deny tests prove that selection still passes through the classifier; sender tests prove draft and revalidation gates remain intact.

- [ ] **Step 6: Commit the tested behavior**

```bash
git add Sources/CodexQuickOKApp/Automation/AccessibilityClient.swift \
  Tests/CodexQuickOKAppTests/AccessibilityClientTests.swift
git commit -m "feat(macOS): Focus first Codex input when idle"
```

### Task 2: Document, package, and install the behavior

**Files:**
- Modify: `README.md:28-44`
- Modify: `docs/manual-verification.md:16-41`

**Interfaces:**
- Consumes: Task 1 `AccessibilityClient.captureTarget()` behavior.
- Produces: user-facing operating limits and a manual acceptance checklist.

- [ ] **Step 1: Update macOS usage and safety text**

Replace the macOS usage bullets with wording that distinguishes Codex from other apps:

```markdown
- 在 Visual Studio Code 侧边栏聊天、微信或其他受支持聊天应用中，先聚焦空输入框。
- Codex 已聚焦输入框时沿用相同流程；Codex 没有可编辑焦点时，会自动聚焦当前窗口中扫描到的第一个可编辑输入框。
- 自动选中的 Codex 输入框仍须通过聊天分类和空内容检查；明确的搜索框会被拒绝，Accessibility 语义不完整的较早输入框仍可能被误选。
- 单击按钮后写入“可”，再向同一应用发送 Enter。
```

Append this sentence to the macOS safety boundary:

```markdown
Codex 自动定位不扫描其他窗口、不缓存旧输入框，也不会绕过已有草稿保护。
```

- [ ] **Step 2: Add manual acceptance rows**

Append these rows to the manual acceptance table:

```markdown
| 21 | 从其他应用切回 Codex，不点击 composer，单击“可”后发送一次 | PENDING (manual) |
| 22 | Codex 首个可编辑元素为明确搜索框时闪红且不输入 | PENDING (manual) |
| 23 | VS Code 和微信没有输入焦点时不启用 Codex 自动扫描 | PENDING (manual) |
```

Keep the existing rule that real Enter verification is performed only by the user in a dedicated test conversation.

- [ ] **Step 3: Run all automated tests**

Run:

```bash
swift test
zsh Tests/PackagingTests.sh
zsh Tests/AppIconTests.sh
zsh Tests/SigningTests.sh
```

Expected: 0 Swift test failures and each shell suite prints its existing success message.

- [ ] **Step 4: Build and verify the signed local release**

Run:

```bash
zsh scripts/build-release.sh
codesign --verify --deep --strict "dist/Codex 可.app"
```

Expected: build exits 0 and `codesign` exits 0 without diagnostics.

- [ ] **Step 5: Install the verified build**

Run:

```bash
zsh scripts/install-local.sh
```

Expected: the script installs the stable-signed build and launches “Codex 可” without resetting unrelated macOS settings.

- [ ] **Step 6: Inspect the final diff and commit documentation**

Run:

```bash
git diff --check
git status --short
```

Expected: only `README.md` and `docs/manual-verification.md` are listed. If the build scripts changed any tracked file, stop and inspect that change before staging.

Commit:

```bash
git add README.md docs/manual-verification.md
git commit -m "docs(macOS): Explain Codex auto-focus behavior"
```

- [ ] **Step 7: Push the feature branch**

Run:

```bash
git push origin HEAD:feature/windows-version
```

Expected: GitHub updates `feature/windows-version` to the final local commit; no force push is used.

## Final Acceptance

- `swift test` reports 0 failures.
- Existing package, icon, signing, draft, classifier, and focus-race checks pass.
- The installed app can recover the first editable Codex input only when no editable input already owns focus.
- The user performs real-send checks 21–23 in dedicated test conversations.
- Git working tree is clean and the remote feature branch contains the implementation and docs commits.
