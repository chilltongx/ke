# Codex Quick OK Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native macOS floating “可” button that targets the latest Codex chat awaiting approval, sends exactly one “可”, and displays only the real weekly Codex quota.

**Architecture:** A dependency-free Swift package produces three targets: a shared core library, a native AppKit application, and a tiny Codex Hook executable. A plugin writes minimal per-session state, the app coordinates visibility and quota data, and an Accessibility adapter performs a guarded Codex-only send.

**Tech Stack:** Swift 6.3.3, Swift Package Manager, AppKit, ApplicationServices Accessibility, ServiceManagement, Foundation `Process`/JSON-RPC, XCTest, shell packaging scripts, Codex plugin Hooks.

## Global Constraints

- Target the current Mac running macOS 26.5.2 and Xcode 26.6; set the package deployment floor to macOS 14.
- Use no third-party Swift or JavaScript dependencies.
- Target only the Codex app whose Bundle ID is exactly `com.openai.codex`.
- Send exactly one Unicode string, `可`; do not add a global keyboard shortcut or configurable macros.
- Show a 64 pt floating button only while a session is `running` or `waitingForApproval`.
- Treat pointer movement greater than 5 pt as drag, never as click.
- Prefer the greatest `waitingSince` timestamp when multiple sessions wait for approval.
- Expire session state after 12 hours and clear all in-memory state when Codex exits.
- Treat only `windowDurationMins == 10080` as weekly quota; refresh every 300 seconds.
- Confirm a send with same-session `UserPromptSubmit` within 2 seconds; never retry automatically.
- Do not request Full Disk Access, Screen Recording, administrator access, or an OpenAI API key.
- Do not read or persist full transcripts, credentials, or clipboard history. A Hook may read
  `last_assistant_message` only in memory for local approval classification; never persist, log,
  or transmit its content.
- Keep the canonical behavior aligned with `docs/superpowers/specs/2026-07-15-codex-quick-ok-design.md`.

---

## File Structure

```text
Package.swift                                      SwiftPM products and target graph
Sources/CodexQuickOKCore/SessionState.swift        Session value types and phases
Sources/CodexQuickOKCore/SessionStateStore.swift   Atomic per-session JSON persistence
Sources/CodexQuickOKCore/HookEvent.swift           Hook JSON decoding and reduction
Sources/CodexQuickOKCore/ApprovalClassifier.swift  Local approval-intent rules
Sources/CodexQuickOKCore/SessionSnapshot.swift     Visibility and target selection
Sources/CodexQuickOKCore/QuotaModels.swift         App Server quota wire types
Sources/CodexQuickOKCore/QuotaSelector.swift       Exact weekly-window selection
Sources/CodexQuickOKCore/GestureDecision.swift     Click-versus-drag pure logic
Sources/CodexQuickOKCore/SendSafety.swift          Send preconditions and errors
Sources/CodexQuickOKHook/main.swift                Fast stdin Hook event processor
Sources/CodexQuickOKApp/AppMain.swift              NSApplication entry point
Sources/CodexQuickOKApp/AppDelegate.swift          App lifecycle and login item
Sources/CodexQuickOKApp/AppController.swift        Session, UI, quota, and send orchestration
Sources/CodexQuickOKApp/SessionDirectoryMonitor.swift  State-directory file watching
Sources/CodexQuickOKApp/CodexProcessMonitor.swift  Bundle launch/termination tracking
Sources/CodexQuickOKApp/Quota/LineJSONRPCClient.swift  Newline JSON-RPC transport
Sources/CodexQuickOKApp/Quota/CodexAppServerClient.swift Codex process and quota requests
Sources/CodexQuickOKApp/UI/HaloButtonView.swift    Ring drawing, hover, and mouse events
Sources/CodexQuickOKApp/UI/FloatingPanelController.swift NSPanel and feedback states
Sources/CodexQuickOKApp/UI/PanelPositionStore.swift Multi-display normalized position
Sources/CodexQuickOKApp/Automation/AccessibilityClient.swift AX wrapper restricted to Codex
Sources/CodexQuickOKApp/Automation/CodexSessionNavigator.swift Exact-session navigation
Sources/CodexQuickOKApp/Automation/ApprovalSender.swift Guarded write and single send
Resources/Info.plist                              App bundle metadata
Resources/PrivacyInfo.xcprivacy                   Declared local-only data access
plugin/codex-quick-ok/.codex-plugin/plugin.json   Plugin manifest
plugin/codex-quick-ok/hooks.json                  Hook event registrations
marketplace/.agents/plugins/marketplace.json      Local marketplace descriptor
scripts/build-release.sh                          Build and ad-hoc sign `.app`
scripts/install-local.sh                          Install app and local marketplace/plugin
scripts/uninstall-local.sh                        Remove only this app/plugin/state
Tests/CodexQuickOKCoreTests/*.swift               Pure unit tests
Tests/CodexQuickOKAppTests/*.swift                Transport and automation tests with fakes
README.md                                         Install, trust, permission, and usage guide
docs/manual-verification.md                       Real Codex acceptance checklist
```

Scope check: the Hook, session state, guarded sender, and halo form one end-to-end approval pipeline and are not independently useful deliverables, so they remain in one plan with reviewable task boundaries.

### Task 1: Swift Package and Atomic Session Store

**Files:**
- Create: `Package.swift`
- Create: `Sources/CodexQuickOKCore/SessionState.swift`
- Create: `Sources/CodexQuickOKCore/SessionStateStore.swift`
- Create: `Tests/CodexQuickOKCoreTests/SessionStateStoreTests.swift`

**Interfaces:**
- Produces: `SessionPhase`, `SessionState`, and actor `SessionStateStore`.
- Produces: `SessionStateStore.save(_:)`, `loadAll(now:staleAfter:)`, `remove(sessionId:)`, and `removeAll()`.

- [ ] **Step 1: Create the package graph and a failing persistence test**

```swift
// Package.swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexQuickOK",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CodexQuickOKCore", targets: ["CodexQuickOKCore"]),
        .executable(name: "CodexQuickOKApp", targets: ["CodexQuickOKApp"]),
        .executable(name: "CodexQuickOKHook", targets: ["CodexQuickOKHook"]),
    ],
    targets: [
        .target(name: "CodexQuickOKCore"),
        .executableTarget(name: "CodexQuickOKHook", dependencies: ["CodexQuickOKCore"]),
        .executableTarget(name: "CodexQuickOKApp", dependencies: ["CodexQuickOKCore"]),
        .testTarget(name: "CodexQuickOKCoreTests", dependencies: ["CodexQuickOKCore"]),
        .testTarget(name: "CodexQuickOKAppTests", dependencies: ["CodexQuickOKApp", "CodexQuickOKCore"]),
    ]
)
```

```swift
// Tests/CodexQuickOKCoreTests/SessionStateStoreTests.swift
import XCTest
@testable import CodexQuickOKCore

final class SessionStateStoreTests: XCTestCase {
    func testRoundTripsAndExpiresStaleSessions() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = SessionStateStore(directory: directory)
        let now = Date(timeIntervalSince1970: 10_000)
        try await store.save(SessionState(
            sessionId: "session-1", phase: .waitingForApproval,
            updatedAt: now, waitingSince: now, cwd: "/tmp/project"
        ))

        XCTAssertEqual(try await store.loadAll(now: now, staleAfter: 43_200).count, 1)
        XCTAssertEqual(try await store.loadAll(now: now.addingTimeInterval(43_201), staleAfter: 43_200), [])
    }
}
```

- [ ] **Step 2: Run the test and verify the missing types fail compilation**

Run: `swift test --filter SessionStateStoreTests`

Expected: FAIL with `cannot find 'SessionStateStore' in scope`.

- [ ] **Step 3: Implement the session model and atomic file store**

```swift
// Sources/CodexQuickOKCore/SessionState.swift
import Foundation

public enum SessionPhase: String, Codable, Equatable, Sendable {
    case running
    case waitingForApproval
    case idle
}

public struct SessionState: Codable, Equatable, Sendable, Identifiable {
    public var id: String { sessionId }
    public let sessionId: String
    public var phase: SessionPhase
    public var updatedAt: Date
    public var waitingSince: Date?
    public var cwd: String?

    enum CodingKeys: String, CodingKey {
        case sessionId
        case phase = "state"
        case updatedAt, waitingSince, cwd
    }

    public init(
        sessionId: String, phase: SessionPhase, updatedAt: Date,
        waitingSince: Date? = nil, cwd: String? = nil
    ) {
        self.sessionId = sessionId
        self.phase = phase
        self.updatedAt = updatedAt
        self.waitingSince = waitingSince
        self.cwd = cwd
    }
}
```

```swift
// Sources/CodexQuickOKCore/SessionStateStore.swift
import Foundation

public actor SessionStateStore {
    public let directory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        return base.appendingPathComponent("CodexQuickOK/sessions", isDirectory: true)
    }

    public func save(_ state: SessionState) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(state.sessionId).appendingPathExtension("json")
        try encoder.encode(state).write(to: url, options: [.atomic])
    }

    public func loadAll(now: Date, staleAfter: TimeInterval) throws -> [SessionState] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        var result: [SessionState] = []
        for url in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let state = try? decoder.decode(SessionState.self, from: data) else { continue }
            if now.timeIntervalSince(state.updatedAt) > staleAfter {
                try? fileManager.removeItem(at: url)
            } else {
                result.append(state)
            }
        }
        return result
    }

    public func remove(sessionId: String) throws {
        let url = directory.appendingPathComponent(sessionId).appendingPathExtension("json")
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    public func removeAll() throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        for url in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.pathExtension == "json" {
            try fileManager.removeItem(at: url)
        }
    }
}
```

- [ ] **Step 4: Run the focused and full test suites**

Run: `swift test --filter SessionStateStoreTests && swift test`

Expected: both commands PASS.

- [ ] **Step 5: Commit the store boundary**

```bash
git add Package.swift Sources/CodexQuickOKCore Tests/CodexQuickOKCoreTests
git commit -m "feat(core): Add atomic session state store"
```

### Task 2: Codex Hook Decoder, Approval Classifier, and Plugin

**Files:**
- Create: `Sources/CodexQuickOKCore/HookEvent.swift`
- Create: `Sources/CodexQuickOKCore/ApprovalClassifier.swift`
- Create: `Sources/CodexQuickOKHook/main.swift`
- Create: `Tests/CodexQuickOKCoreTests/HookReducerTests.swift`
- Create: `plugin/codex-quick-ok/.codex-plugin/plugin.json`
- Create: `plugin/codex-quick-ok/hooks.json`

**Interfaces:**
- Consumes: `SessionState` and `SessionStateStore` from Task 1.
- Produces: `HookEvent`, `ApprovalClassifier.isApprovalRequest(_:)`, and `HookReducer.reduce(event:previous:now:)`.
- Produces: a Hook executable that exits `0` without writing conversation content to disk.

- [ ] **Step 1: Write failing classifier and transition tests**

```swift
// Tests/CodexQuickOKCoreTests/HookReducerTests.swift
import XCTest
@testable import CodexQuickOKCore

final class HookReducerTests: XCTestCase {
    func testClassifiesApprovalRequestsWithoutTreatingOrdinaryQuestionsAsApproval() {
        XCTAssertTrue(ApprovalClassifier.isApprovalRequest("要我继续执行吗？"))
        XCTAssertTrue(ApprovalClassifier.isApprovalRequest("Please confirm, then I will proceed."))
        XCTAssertFalse(ApprovalClassifier.isApprovalRequest("这个函数为什么返回 nil？"))
        XCTAssertFalse(ApprovalClassifier.isApprovalRequest("修改已经完成。"))
    }

    func testReducesPromptAndStopEvents() throws {
        let prompt = try HookEvent.decode(Data("""
        {"session_id":"s1","hook_event_name":"UserPromptSubmit","cwd":"/tmp/p"}
        """.utf8))
        let running = HookReducer.reduce(event: prompt, previous: nil, now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(running?.phase, .running)

        let stop = try HookEvent.decode(Data("""
        {"session_id":"s1","hook_event_name":"Stop","cwd":"/tmp/p","last_assistant_message":"可以继续吗？"}
        """.utf8))
        let waiting = HookReducer.reduce(event: stop, previous: running, now: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(waiting?.phase, .waitingForApproval)
        XCTAssertEqual(waiting?.waitingSince, Date(timeIntervalSince1970: 2))
    }
}
```

- [ ] **Step 2: Run the tests and verify missing Hook types fail**

Run: `swift test --filter HookReducerTests`

Expected: FAIL with `cannot find 'ApprovalClassifier' in scope`.

- [ ] **Step 3: Implement exact Hook decoding and reduction**

```swift
// Sources/CodexQuickOKCore/HookEvent.swift
import Foundation

public struct HookEvent: Decodable, Sendable {
    public let sessionId: String
    public let hookEventName: String
    public let cwd: String?
    public let lastAssistantMessage: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case hookEventName = "hook_event_name"
        case cwd
        case lastAssistantMessage = "last_assistant_message"
    }

    public static func decode(_ data: Data) throws -> HookEvent {
        try JSONDecoder().decode(HookEvent.self, from: data)
    }
}

public enum HookReducer {
    public static func reduce(
        event: HookEvent, previous: SessionState?, now: Date
    ) -> SessionState? {
        switch event.hookEventName {
        case "SessionStart":
            return SessionState(sessionId: event.sessionId, phase: .idle, updatedAt: now, cwd: event.cwd)
        case "UserPromptSubmit":
            return SessionState(sessionId: event.sessionId, phase: .running, updatedAt: now, cwd: event.cwd)
        case "Stop":
            let waiting = ApprovalClassifier.isApprovalRequest(event.lastAssistantMessage)
            return SessionState(
                sessionId: event.sessionId,
                phase: waiting ? .waitingForApproval : .idle,
                updatedAt: now,
                waitingSince: waiting ? now : nil,
                cwd: event.cwd ?? previous?.cwd
            )
        default:
            return nil
        }
    }
}
```

```swift
// Sources/CodexQuickOKCore/ApprovalClassifier.swift
import Foundation

public enum ApprovalClassifier {
    private static let patterns = [
        #"可以(?:继续|执行|开始|安装|修改|提交|删除|运行|写入|创建)?吗[？?]?"#,
        #"可否(?:继续|执行|开始|安装|修改|提交|删除|运行|写入|创建)"#,
        #"是否(?:继续|执行|开始|安装|修改|提交|删除|运行|写入|创建)"#,
        #"请(?:确认|批准)"#,
        #"要我(?:继续|执行|开始|安装|修改|提交|删除|运行|写入|创建)"#,
        #"回复[“\"']?可"#,
        #"\b(?:shall|should|may|can)\s+i\s+(?:continue|proceed|run|apply|install|delete|write|create)\b"#,
        #"\bplease\s+(?:confirm|approve)\b"#,
        #"\b(?:ready to proceed|proceed with this)\b"#,
    ]

    public static func isApprovalRequest(_ message: String?) -> Bool {
        guard let message, !message.isEmpty else { return false }
        return patterns.contains { pattern in
            message.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }
}
```

- [ ] **Step 4: Implement the non-blocking Hook executable**

```swift
// Sources/CodexQuickOKHook/main.swift
import CodexQuickOKCore
import Foundation

@main
struct CodexQuickOKHookMain {
    static func main() async {
        do {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            let event = try HookEvent.decode(data)
            let store = SessionStateStore(directory: try SessionStateStore.defaultDirectory())
            let existing = try await store.loadAll(now: Date(), staleAfter: 43_200)
                .first(where: { $0.sessionId == event.sessionId })
            if let next = HookReducer.reduce(event: event, previous: existing, now: Date()) {
                try await store.save(next)
            }
        } catch {
            FileHandle.standardError.write(Data("CodexQuickOKHook: \(error)\n".utf8))
        }
    }
}
```

- [ ] **Step 5: Add the plugin manifest and exact Hook registrations**

```json
{
  "name": "codex-quick-ok",
  "version": "0.1.0",
  "description": "Reports minimal Codex session state to the Codex 可 macOS companion."
}
```

```json
{
  "hooks": {
    "SessionStart": [{
      "matcher": "startup|resume|clear|compact",
      "hooks": [{"type":"command","command":"./bin/CodexQuickOKHook","timeout":2}]
    }],
    "UserPromptSubmit": [{
      "hooks": [{"type":"command","command":"./bin/CodexQuickOKHook","timeout":2}]
    }],
    "Stop": [{
      "hooks": [{"type":"command","command":"./bin/CodexQuickOKHook","timeout":2}]
    }]
  }
}
```

- [ ] **Step 6: Verify tests and a real stdin invocation**

Run:

```bash
swift test --filter HookReducerTests
printf '%s\n' '{"session_id":"smoke","hook_event_name":"Stop","cwd":"/tmp","last_assistant_message":"可以继续吗？"}' | swift run CodexQuickOKHook
test -f "$HOME/Library/Application Support/CodexQuickOK/sessions/smoke.json"
```

Expected: tests PASS, Hook exits `0`, and the smoke state file exists without a message field. Remove the smoke file after inspection.

- [ ] **Step 7: Commit the plugin event path**

```bash
git add Sources/CodexQuickOKCore Sources/CodexQuickOKHook Tests/CodexQuickOKCoreTests plugin
git commit -m "feat(hooks): Track Codex approval state"
```

### Task 3: Session Visibility and Latest-Waiting Selection

**Files:**
- Create: `Sources/CodexQuickOKCore/SessionSnapshot.swift`
- Create: `Tests/CodexQuickOKCoreTests/SessionSnapshotTests.swift`

**Interfaces:**
- Consumes: `[SessionState]` from Task 1.
- Produces: `CompanionMode`, `CompanionSnapshot`, and `SessionSnapshotEvaluator.evaluate(...)`.

- [ ] **Step 1: Write failing mode and target-selection tests**

```swift
// Tests/CodexQuickOKCoreTests/SessionSnapshotTests.swift
import XCTest
@testable import CodexQuickOKCore

final class SessionSnapshotTests: XCTestCase {
    func testHidesWithoutCodexAndSelectsNewestWaitingSession() {
        let now = Date(timeIntervalSince1970: 100)
        let states = [
            SessionState(sessionId: "older", phase: .waitingForApproval, updatedAt: now, waitingSince: now.addingTimeInterval(-5)),
            SessionState(sessionId: "newer", phase: .waitingForApproval, updatedAt: now, waitingSince: now.addingTimeInterval(-1)),
        ]
        XCTAssertEqual(SessionSnapshotEvaluator.evaluate(states: states, codexRunning: false, now: now).mode, .hidden)
        let visible = SessionSnapshotEvaluator.evaluate(states: states, codexRunning: true, now: now)
        XCTAssertEqual(visible.mode, .waiting)
        XCTAssertEqual(visible.targetSessionId, "newer")
    }

    func testShowsRunningButHasNoSendTarget() {
        let now = Date()
        let snapshot = SessionSnapshotEvaluator.evaluate(
            states: [SessionState(sessionId: "run", phase: .running, updatedAt: now)],
            codexRunning: true, now: now
        )
        XCTAssertEqual(snapshot.mode, .running)
        XCTAssertNil(snapshot.targetSessionId)
    }
}
```

- [ ] **Step 2: Run the tests and verify missing evaluator failure**

Run: `swift test --filter SessionSnapshotTests`

Expected: FAIL with `cannot find 'SessionSnapshotEvaluator' in scope`.

- [ ] **Step 3: Implement the pure snapshot evaluator**

```swift
// Sources/CodexQuickOKCore/SessionSnapshot.swift
import Foundation

public enum CompanionMode: Equatable, Sendable { case hidden, running, waiting }

public struct CompanionSnapshot: Equatable, Sendable {
    public let mode: CompanionMode
    public let targetSessionId: String?

    public init(mode: CompanionMode, targetSessionId: String?) {
        self.mode = mode
        self.targetSessionId = targetSessionId
    }
}

public enum SessionSnapshotEvaluator {
    public static func evaluate(
        states: [SessionState], codexRunning: Bool, now: Date,
        staleAfter: TimeInterval = 43_200
    ) -> CompanionSnapshot {
        guard codexRunning else { return CompanionSnapshot(mode: .hidden, targetSessionId: nil) }
        let fresh = states.filter { now.timeIntervalSince($0.updatedAt) <= staleAfter }
        let waiting = fresh.filter { $0.phase == .waitingForApproval }
            .sorted { ($0.waitingSince ?? .distantPast) > ($1.waitingSince ?? .distantPast) }
        if let target = waiting.first {
            return CompanionSnapshot(mode: .waiting, targetSessionId: target.sessionId)
        }
        if fresh.contains(where: { $0.phase == .running }) {
            return CompanionSnapshot(mode: .running, targetSessionId: nil)
        }
        return CompanionSnapshot(mode: .hidden, targetSessionId: nil)
    }
}
```

- [ ] **Step 4: Run all core tests**

Run: `swift test --filter SessionSnapshotTests && swift test`

Expected: PASS.

- [ ] **Step 5: Commit the coordinator policy**

```bash
git add Sources/CodexQuickOKCore/SessionSnapshot.swift Tests/CodexQuickOKCoreTests/SessionSnapshotTests.swift
git commit -m "feat(core): Select latest waiting Codex session"
```

### Task 4: Exact Weekly Quota Selection

**Files:**
- Create: `Sources/CodexQuickOKCore/QuotaModels.swift`
- Create: `Sources/CodexQuickOKCore/QuotaSelector.swift`
- Create: `Tests/CodexQuickOKCoreTests/QuotaSelectorTests.swift`

**Interfaces:**
- Produces: wire types `RateLimitsReadResult`, `RateLimitBucket`, `RateLimitWindow`.
- Produces: `WeeklyQuota` and `QuotaSelector.weeklyQuota(from:) -> WeeklyQuota?`.

- [ ] **Step 1: Write failing tests for weekly-only semantics**

```swift
// Tests/CodexQuickOKCoreTests/QuotaSelectorTests.swift
import XCTest
@testable import CodexQuickOKCore

final class QuotaSelectorTests: XCTestCase {
    func testSelectsOnlySevenDayCodexWindow() throws {
        let data = Data("""
        {"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":80,"windowDurationMins":300,"resetsAt":1000},"secondary":{"usedPercent":25,"windowDurationMins":10080,"resetsAt":2000}}}}
        """.utf8)
        let result = try JSONDecoder().decode(RateLimitsReadResult.self, from: data)
        let quota = try XCTUnwrap(QuotaSelector.weeklyQuota(from: result))
        XCTAssertEqual(quota.remainingPercent, 75)
        XCTAssertEqual(quota.resetsAt, Date(timeIntervalSince1970: 2000))
    }

    func testReturnsNilInsteadOfFallingBackToShortWindow() throws {
        let data = Data("""
        {"rateLimits":{"limitId":"codex","primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":1000}}}
        """.utf8)
        let result = try JSONDecoder().decode(RateLimitsReadResult.self, from: data)
        XCTAssertNil(QuotaSelector.weeklyQuota(from: result))
    }
}
```

- [ ] **Step 2: Run tests and verify missing quota types**

Run: `swift test --filter QuotaSelectorTests`

Expected: FAIL with `cannot find 'RateLimitsReadResult' in scope`.

- [ ] **Step 3: Implement the wire types and strict selector**

```swift
// Sources/CodexQuickOKCore/QuotaModels.swift
import Foundation

public struct RateLimitsReadResult: Decodable, Sendable {
    public let rateLimits: RateLimitBucket?
    public let rateLimitsByLimitId: [String: RateLimitBucket]?
}

public struct RateLimitBucket: Decodable, Sendable {
    public let limitId: String?
    public let primary: RateLimitWindow?
    public let secondary: RateLimitWindow?
}

public struct RateLimitWindow: Decodable, Sendable {
    public let usedPercent: Double
    public let windowDurationMins: Int?
    public let resetsAt: TimeInterval?
}

public struct WeeklyQuota: Equatable, Sendable {
    public let remainingPercent: Double
    public let resetsAt: Date
}
```

```swift
// Sources/CodexQuickOKCore/QuotaSelector.swift
import Foundation

public enum QuotaSelector {
    public static func weeklyQuota(from result: RateLimitsReadResult) -> WeeklyQuota? {
        let bucket = result.rateLimitsByLimitId?["codex"] ?? result.rateLimits
        guard let bucket else { return nil }
        guard let window = [bucket.primary, bucket.secondary]
            .compactMap({ $0 }).first(where: { $0.windowDurationMins == 10_080 }),
              let resetsAt = window.resetsAt else { return nil }
        return WeeklyQuota(
            remainingPercent: min(100, max(0, 100 - window.usedPercent)),
            resetsAt: Date(timeIntervalSince1970: resetsAt)
        )
    }
}
```

- [ ] **Step 4: Run quota and full tests**

Run: `swift test --filter QuotaSelectorTests && swift test`

Expected: PASS.

- [ ] **Step 5: Commit weekly quota semantics**

```bash
git add Sources/CodexQuickOKCore/QuotaModels.swift Sources/CodexQuickOKCore/QuotaSelector.swift Tests/CodexQuickOKCoreTests/QuotaSelectorTests.swift
git commit -m "feat(quota): Select exact weekly Codex window"
```

### Task 5: Codex App Server JSON-RPC Client

**Files:**
- Create: `Sources/CodexQuickOKApp/Quota/LineJSONRPCClient.swift`
- Create: `Sources/CodexQuickOKApp/Quota/CodexAppServerClient.swift`
- Create: `Tests/CodexQuickOKAppTests/LineJSONRPCClientTests.swift`

**Interfaces:**
- Consumes: `RateLimitsReadResult` from Task 4.
- Produces: actor `LineJSONRPCClient.request(method:params:)`, `sendNotification(method:params:)`, and `setNotificationHandler(_:)`.
- Produces: actor `CodexAppServerClient.start()`, `readRateLimits()`, `readThreadMetadata(sessionId:)`, `setRateLimitUpdateHandler(_:)`, and `stop()`.

- [ ] **Step 1: Write a failing codec test using pipes**

```swift
// Tests/CodexQuickOKAppTests/LineJSONRPCClientTests.swift
import XCTest
@testable import CodexQuickOKApp

final class LineJSONRPCClientTests: XCTestCase {
    func testMatchesResponseToRequestId() async throws {
        let input = Pipe()
        let output = Pipe()
        let client = LineJSONRPCClient(input: input.fileHandleForReading, output: output.fileHandleForWriting)
        let task = Task { try await client.request(method: "account/rateLimits/read", params: [:]) }

        let requestData = output.fileHandleForReading.availableData
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
        let id = try XCTUnwrap(request["id"] as? Int)
        input.fileHandleForWriting.write(Data("{\"id\":\(id),\"result\":{\"ok\":true}}\n".utf8))

        let result = try await task.value
        XCTAssertEqual(result["ok"] as? Bool, true)
    }
}
```

- [ ] **Step 2: Run the transport test and verify missing client failure**

Run: `swift test --filter LineJSONRPCClientTests`

Expected: FAIL with `cannot find 'LineJSONRPCClient' in scope`.

- [ ] **Step 3: Implement newline JSON-RPC with one continuation per ID**

```swift
// Sources/CodexQuickOKApp/Quota/LineJSONRPCClient.swift
import Foundation

actor LineJSONRPCClient {
    enum RPCError: Error { case closed, server(String), malformedResponse }
    private let input: FileHandle
    private let output: FileHandle
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var readerTask: Task<Void, Never>?
    private var notificationHandler: (@Sendable (String) -> Void)?

    init(input: FileHandle, output: FileHandle) {
        self.input = input
        self.output = output
    }

    func request(method: String, params: [String: Any]) async throws -> [String: Any] {
        ensureReaderStarted()
        let id = nextId
        nextId += 1
        let body: [String: Any] = ["method": method, "id": id, "params": params]
        let data = try JSONSerialization.data(withJSONObject: body) + Data([0x0A])
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            output.write(data)
        }
    }

    func sendNotification(method: String, params: [String: Any]) throws {
        ensureReaderStarted()
        let body: [String: Any] = ["method": method, "params": params]
        output.write(try JSONSerialization.data(withJSONObject: body) + Data([0x0A]))
    }

    func setNotificationHandler(_ handler: @escaping @Sendable (String) -> Void) {
        notificationHandler = handler
    }

    private func ensureReaderStarted() {
        guard readerTask == nil else { return }
        readerTask = Task { await self.readLoop() }
    }

    private func readLoop() async {
        do {
            for try await line in input.bytes.lines {
                guard let data = line.data(using: .utf8),
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                if let method = object["method"] as? String, object["id"] == nil {
                    notificationHandler?(method)
                    continue
                }
                guard let id = object["id"] as? Int,
                      let continuation = pending.removeValue(forKey: id) else { continue }
                if let error = object["error"] { continuation.resume(throwing: RPCError.server(String(describing: error))) }
                else if let result = object["result"] as? [String: Any] { continuation.resume(returning: result) }
                else { continuation.resume(throwing: RPCError.malformedResponse) }
            }
            for continuation in pending.values { continuation.resume(throwing: RPCError.closed) }
            pending.removeAll()
        } catch {
            for continuation in pending.values { continuation.resume(throwing: error) }
            pending.removeAll()
        }
    }
}
```

- [ ] **Step 4: Implement App Server launch, initialization, and quota decoding**

```swift
// Sources/CodexQuickOKApp/Quota/CodexAppServerClient.swift
import CodexQuickOKCore
import Foundation

actor CodexAppServerClient {
    enum ClientError: Error { case codexBinaryMissing, notStarted }
    struct ThreadMetadata: Equatable, Sendable {
        let id: String
        let title: String
        let cwd: String
        let updatedAt: Date
    }
    private var process: Process?
    private var rpc: LineJSONRPCClient?

    func start(codexBinary: URL) async throws {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = codexBinary
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let rpc = LineJSONRPCClient(input: stdout.fileHandleForReading, output: stdin.fileHandleForWriting)
        self.process = process
        self.rpc = rpc
        do {
            _ = try await rpc.request(method: "initialize", params: [
                "clientInfo": ["name":"codex_quick_ok", "title":"Codex 可", "version":"0.1.0"]
            ])
            try await rpc.sendNotification(method: "initialized", params: [:])
        } catch {
            process.terminate()
            self.process = nil
            self.rpc = nil
            throw error
        }
    }

    func readRateLimits() async throws -> RateLimitsReadResult {
        guard let rpc else { throw ClientError.notStarted }
        let object = try await rpc.request(method: "account/rateLimits/read", params: [:])
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(RateLimitsReadResult.self, from: data)
    }

    func readThreadMetadata(sessionId: String) async throws -> ThreadMetadata {
        guard let rpc else { throw ClientError.notStarted }
        let result = try await rpc.request(
            method: "thread/read", params: ["threadId": sessionId, "includeTurns": false]
        )
        guard let thread = result["thread"] as? [String: Any],
              let id = thread["id"] as? String,
              let preview = thread["preview"] as? String,
              let cwd = thread["cwd"] as? String,
              let updatedAt = (thread["updatedAt"] as? NSNumber)?.doubleValue else {
            throw LineJSONRPCClient.RPCError.malformedResponse
        }
        let name = thread["name"] as? String
        return ThreadMetadata(
            id: id, title: name?.isEmpty == false ? name! : preview,
            cwd: cwd, updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }

    func setRateLimitUpdateHandler(_ handler: @escaping @Sendable () -> Void) async throws {
        guard let rpc else { throw ClientError.notStarted }
        await rpc.setNotificationHandler { method in
            if method == "account/rateLimits/updated" { handler() }
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        rpc = nil
    }
}
```

- [ ] **Step 5: Run transport tests and a read-only App Server smoke test**

Run:

```bash
swift test --filter LineJSONRPCClientTests
swift test
```

Then launch a debug build and log only whether `readRateLimits()` decoded a weekly window; do not log raw account data. Expected: tests PASS and the smoke path returns quota or the explicit unavailable state without crashing.

- [ ] **Step 6: Commit the App Server client**

```bash
git add Sources/CodexQuickOKApp/Quota Tests/CodexQuickOKAppTests/LineJSONRPCClientTests.swift
git commit -m "feat(quota): Read limits from Codex App Server"
```

### Task 6: Floating Panel, Halo, Dragging, and Position Persistence

**Files:**
- Create: `Sources/CodexQuickOKCore/GestureDecision.swift`
- Create: `Sources/CodexQuickOKApp/UI/HaloButtonView.swift`
- Create: `Sources/CodexQuickOKApp/UI/FloatingPanelController.swift`
- Create: `Sources/CodexQuickOKApp/UI/PanelPositionStore.swift`
- Create: `Tests/CodexQuickOKCoreTests/GestureDecisionTests.swift`

**Interfaces:**
- Produces: `GestureDecision.isClick(start:end:threshold:)`.
- Produces: `FloatingPanelController.show(mode:)`, `hide()`, `setQuota(_:)`, `setSending(_:)`, `showFailure(_:)`, and `onActivate`.

- [ ] **Step 1: Write the failing 5 pt gesture boundary test**

```swift
// Tests/CodexQuickOKCoreTests/GestureDecisionTests.swift
import CoreGraphics
import XCTest
@testable import CodexQuickOKCore

final class GestureDecisionTests: XCTestCase {
    func testMovementOverFivePointsIsDrag() {
        XCTAssertTrue(GestureDecision.isClick(start: .init(x: 0, y: 0), end: .init(x: 3, y: 4)))
        XCTAssertFalse(GestureDecision.isClick(start: .init(x: 0, y: 0), end: .init(x: 5.1, y: 0)))
    }
}
```

- [ ] **Step 2: Run the test and verify missing decision type**

Run: `swift test --filter GestureDecisionTests`

Expected: FAIL with `cannot find 'GestureDecision' in scope`.

- [ ] **Step 3: Implement click-versus-drag logic**

```swift
// Sources/CodexQuickOKCore/GestureDecision.swift
import CoreGraphics

public enum GestureDecision {
    public static func isClick(start: CGPoint, end: CGPoint, threshold: CGFloat = 5) -> Bool {
        hypot(end.x - start.x, end.y - start.y) <= threshold
    }
}
```

- [ ] **Step 4: Implement the minimal halo view and non-activating panel**

```swift
// Sources/CodexQuickOKApp/UI/HaloButtonView.swift
import AppKit
import CodexQuickOKCore
import QuartzCore

@MainActor
final class HaloButtonView: NSView {
    var onActivate: (() -> Void)?
    var onMoveOrigin: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?
    var isActivationEnabled = true
    private var startScreen: NSPoint?
    private var grabOffset: NSPoint?
    private(set) var remainingPercent: Double?

    override var intrinsicContentSize: NSSize { NSSize(width: 64, height: 64) }
    override func mouseDown(with event: NSEvent) {
        startScreen = NSEvent.mouseLocation
        grabOffset = event.locationInWindow
    }
    override func mouseDragged(with event: NSEvent) {
        guard let grabOffset else { return }
        let mouse = NSEvent.mouseLocation
        onMoveOrigin?(NSPoint(x: mouse.x - grabOffset.x, y: mouse.y - grabOffset.y))
    }
    override func mouseUp(with event: NSEvent) {
        guard let startScreen else { return }
        if GestureDecision.isClick(start: startScreen, end: NSEvent.mouseLocation),
           isActivationEnabled {
            onActivate?()
        } else {
            onDragEnded?()
        }
        self.startScreen = nil
        self.grabOffset = nil
    }

    func setQuota(_ quota: WeeklyQuota?) {
        remainingPercent = quota?.remainingPercent
        toolTip = quota.map { "周额度剩余 \(Int($0.remainingPercent.rounded()))%，重置于 \($0.resetsAt.formatted())" }
            ?? "周额度暂不可用"
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds.insetBy(dx: 3, dy: 3)
        NSColor(calibratedWhite: 0.12, alpha: 0.96).setFill()
        NSBezierPath(ovalIn: bounds).fill()
        let percent = remainingPercent.map { CGFloat($0 / 100) } ?? 1
        let color: NSColor = remainingPercent == nil ? .systemGray
            : remainingPercent! < 20 ? .systemRed
            : remainingPercent! <= 50 ? .systemOrange : .systemMint
        color.setStroke()
        let ring = NSBezierPath()
        ring.lineWidth = 4
        ring.appendArc(withCenter: NSPoint(x: 32, y: 32), radius: 29,
                       startAngle: 90, endAngle: 90 - 360 * percent, clockwise: true)
        ring.stroke()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 21, weight: .bold), .foregroundColor: NSColor.white
        ]
        let text = NSAttributedString(string: "可", attributes: attributes)
        text.draw(at: NSPoint(x: 32 - text.size().width / 2, y: 32 - text.size().height / 2))
    }
}
```

```swift
// Sources/CodexQuickOKApp/UI/FloatingPanelController.swift
import AppKit
import CodexQuickOKCore
import QuartzCore

@MainActor
protocol CompanionPanel: AnyObject {
    var onActivate: (() -> Void)? { get set }
    var onTemporaryHide: (() -> Void)? { get set }
    func show(mode: CompanionMode)
    func hide()
    func setQuota(_ quota: WeeklyQuota?)
    func setSending(_ sending: Bool)
    func showSuccess()
    func showFailure(_ message: String)
}

@MainActor
final class FloatingPanelController: CompanionPanel {
    private let panel: NSPanel
    private let positionStore: PanelPositionStore
    let button = HaloButtonView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
    private let quotaDetailItem = NSMenuItem(title: "周额度暂不可用", action: nil, keyEquivalent: "")
    var onActivate: (() -> Void)? { didSet { button.onActivate = onActivate } }

    init(positionStore: PanelPositionStore = PanelPositionStore()) {
        self.positionStore = positionStore
        panel = NSPanel(contentRect: button.bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = true
        panel.contentView = button
        button.wantsLayer = true
        button.onMoveOrigin = { [weak self] origin in self?.panel.setFrameOrigin(origin) }
        button.onDragEnded = { [weak self] in self?.persistPosition() }
        if let origin = positionStore.restore(panelSize: panel.frame.size, screens: NSScreen.screens) {
            panel.setFrameOrigin(origin)
        } else if let visible = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.maxX - 88, y: visible.midY - 32))
        }
        let menu = NSMenu()
        quotaDetailItem.isEnabled = false
        menu.addItem(quotaDetailItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "刷新周额度", action: #selector(refreshQuota), keyEquivalent: "")
        menu.addItem(withTitle: "暂时隐藏", action: #selector(hideTemporarily), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Codex 可", action: #selector(quit), keyEquivalent: "")
        for item in menu.items { item.target = self }
        button.menu = menu
    }

    var onRefreshQuota: (() -> Void)?
    var onTemporaryHide: (() -> Void)?
    func show(mode: CompanionMode) {
        guard mode != .hidden else { hide(); return }
        panel.orderFrontRegardless()
        let animation = CABasicAnimation(keyPath: "shadowOpacity")
        animation.fromValue = mode == .waiting ? 0.15 : 0.05
        animation.toValue = mode == .waiting ? 0.45 : 0.20
        animation.duration = mode == .waiting ? 0.9 : 1.8
        animation.autoreverses = true
        animation.repeatCount = .infinity
        panel.contentView?.layer?.add(animation, forKey: "presence")
    }
    func hide() { panel.orderOut(nil) }
    func setQuota(_ quota: WeeklyQuota?) {
        button.setQuota(quota)
        quotaDetailItem.title = quota.map {
            "周额度剩余 \(Int($0.remainingPercent.rounded()))%，\($0.resetsAt.formatted()) 重置"
        } ?? "周额度暂不可用"
    }
    func setSending(_ sending: Bool) {
        button.isActivationEnabled = !sending
        if sending {
            let animation = CABasicAnimation(keyPath: "transform.rotation.z")
            animation.byValue = Double.pi * 2
            animation.duration = 0.8
            animation.repeatCount = .infinity
            button.layer?.add(animation, forKey: "sending")
        } else {
            button.layer?.removeAnimation(forKey: "sending")
        }
    }
    func showSuccess() {
        let animation = CAKeyframeAnimation(keyPath: "transform.scale")
        animation.values = [1, 1.12, 1]
        animation.duration = 0.28
        button.layer?.add(animation, forKey: "success")
    }
    func showFailure(_ message: String) {
        NSSound.beep()
        button.toolTip = message
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [1, 0.25, 1, 0.25, 1]
        animation.duration = 0.55
        button.layer?.add(animation, forKey: "failure")
    }
    @objc private func refreshQuota() { onRefreshQuota?() }
    @objc private func hideTemporarily() { hide(); onTemporaryHide?() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    private func persistPosition() {
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(panel.frame) }) ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        var origin = panel.frame.origin
        origin.x = min(max(origin.x, visible.minX), visible.maxX - panel.frame.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - panel.frame.height)
        panel.setFrameOrigin(origin)
        positionStore.save(frame: panel.frame, screen: screen)
    }
}
```

- [ ] **Step 5: Persist normalized screen position and connect panel dragging**

```swift
// Sources/CodexQuickOKApp/UI/PanelPositionStore.swift
import AppKit

struct StoredPanelPosition: Codable, Equatable {
    let screenIdentifier: String
    let xFraction: Double
    let yFraction: Double
}

final class PanelPositionStore {
    private let defaults: UserDefaults
    private let key = "panelPosition.v1"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func save(frame: NSRect, screen: NSScreen) {
        let visible = screen.visibleFrame
        let xRange = max(1, visible.width - frame.width)
        let yRange = max(1, visible.height - frame.height)
        let value = StoredPanelPosition(
            screenIdentifier: screen.codexQuickOKIdentifier,
            xFraction: min(1, max(0, (frame.minX - visible.minX) / xRange)),
            yFraction: min(1, max(0, (frame.minY - visible.minY) / yRange))
        )
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    func restore(panelSize: NSSize, screens: [NSScreen]) -> NSPoint? {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(StoredPanelPosition.self, from: data),
              let screen = screens.first(where: { $0.codexQuickOKIdentifier == value.screenIdentifier }) ?? screens.first
        else { return nil }
        let visible = screen.visibleFrame
        return NSPoint(
            x: visible.minX + value.xFraction * max(1, visible.width - panelSize.width),
            y: visible.minY + value.yFraction * max(1, visible.height - panelSize.height)
        )
    }
}

private extension NSScreen {
    var codexQuickOKIdentifier: String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? NSNumber)?.stringValue ?? localizedName
    }
}
```

The controller now saves after a completed drag, restores before first display, and clamps the final frame to the selected screen's `visibleFrame`. Keep the 5 pt threshold only in `GestureDecision`.

- [ ] **Step 6: Run tests and a visual debug smoke launch**

Run: `swift test && swift run CodexQuickOKApp`

Expected: all tests PASS; a 64 pt non-activating panel renders above windows, drag does not call `onActivate`, and quota `nil` renders gray.

- [ ] **Step 7: Commit the floating UI**

```bash
git add Sources/CodexQuickOKCore/GestureDecision.swift Sources/CodexQuickOKApp/UI Tests/CodexQuickOKCoreTests/GestureDecisionTests.swift
git commit -m "feat(ui): Add floating weekly quota halo"
```

### Task 7: Codex-Only Navigation and Safe Single Send

**Files:**
- Create: `Sources/CodexQuickOKCore/SendSafety.swift`
- Create: `Sources/CodexQuickOKApp/Automation/AccessibilityClient.swift`
- Create: `Sources/CodexQuickOKApp/Automation/CodexSessionNavigator.swift`
- Create: `Sources/CodexQuickOKApp/Automation/ApprovalSender.swift`
- Create: `Tests/CodexQuickOKCoreTests/SendSafetyTests.swift`
- Create: `Tests/CodexQuickOKAppTests/ApprovalSenderTests.swift`
- Create: `Tests/CodexQuickOKAppTests/FakeCodexAutomation.swift`

**Interfaces:**
- Produces: `SendSafety.validate(bundleId:sessionMatched:composerValue:)`.
- Produces: protocol `CodexAutomating` and `ApprovalSender.sendOK(sessionId:)`.
- Consumes: the same-session Hook confirmation written by Task 2.

- [ ] **Step 1: Write failing safety-gate tests**

```swift
// Tests/CodexQuickOKCoreTests/SendSafetyTests.swift
import XCTest
@testable import CodexQuickOKCore

final class SendSafetyTests: XCTestCase {
    func testRejectsOtherAppsAndExistingDrafts() {
        XCTAssertThrowsError(try SendSafety.validate(bundleId: "com.apple.TextEdit", sessionMatched: true, composerValue: ""))
        XCTAssertThrowsError(try SendSafety.validate(bundleId: "com.openai.codex", sessionMatched: true, composerValue: "draft"))
        XCTAssertNoThrow(try SendSafety.validate(bundleId: "com.openai.codex", sessionMatched: true, composerValue: ""))
    }
}
```

```swift
// Tests/CodexQuickOKAppTests/ApprovalSenderTests.swift
import XCTest
@testable import CodexQuickOKApp

@MainActor
final class ApprovalSenderTests: XCTestCase {
    func testSendsExactlyOnceAfterAllChecksPass() async throws {
        let automation = FakeCodexAutomation(bundleId: "com.openai.codex", matched: true, value: "")
        let sender = ApprovalSender(automation: automation)
        try await sender.sendOK(sessionId: "s1")
        XCTAssertEqual(automation.writtenValues, ["可"])
        XCTAssertEqual(automation.sendCount, 1)
    }

    func testRejectsWrongAppSessionMismatchAndExistingDraft() async {
        let cases = [
            FakeCodexAutomation(bundleId: "com.apple.TextEdit", matched: true, value: ""),
            FakeCodexAutomation(bundleId: "com.openai.codex", matched: false, value: ""),
            FakeCodexAutomation(bundleId: "com.openai.codex", matched: true, value: "draft"),
        ]
        for automation in cases {
            do {
                try await ApprovalSender(automation: automation).sendOK(sessionId: "s1")
                XCTFail("Expected safety rejection")
            } catch {}
            XCTAssertEqual(automation.writtenValues, [])
            XCTAssertEqual(automation.sendCount, 0)
        }

        let staleTarget = FakeCodexAutomation(
            bundleId: "com.openai.codex", matched: true, value: ""
        )
        do {
            try await ApprovalSender(
                automation: staleTarget, isStillTarget: { _ in false }
            ).sendOK(sessionId: "s1")
            XCTFail("Expected latest-target rejection")
        } catch {}
        XCTAssertEqual(staleTarget.writtenValues, [])
        XCTAssertEqual(staleTarget.sendCount, 0)
    }

    func testDuplicateInFlightClickAndActivationFailureNeverDoubleSend() async throws {
        let delayed = FakeCodexAutomation(bundleId: "com.openai.codex", matched: true, value: "")
        delayed.activationDelay = .milliseconds(100)
        let sender = ApprovalSender(automation: delayed)
        async let first: Void = sender.sendOK(sessionId: "s1")
        async let second: Void = sender.sendOK(sessionId: "s1")
        _ = try await (first, second)
        XCTAssertEqual(delayed.writtenValues, ["可"])
        XCTAssertEqual(delayed.sendCount, 1)

        let failed = FakeCodexAutomation(bundleId: "com.openai.codex", matched: true, value: "")
        failed.activationError = FakeCodexAutomation.FakeError.activationFailed
        do {
            try await ApprovalSender(automation: failed).sendOK(sessionId: "s1")
            XCTFail("Expected activation failure")
        } catch {}
        XCTAssertEqual(failed.writtenValues, [])
        XCTAssertEqual(failed.sendCount, 0)
    }
}
```

- [ ] **Step 2: Run tests and verify missing safety types**

Run: `swift test --filter SendSafetyTests && swift test --filter ApprovalSenderTests`

Expected: FAIL because `SendSafety` and `ApprovalSender` do not exist.

- [ ] **Step 3: Implement the pure safety gate**

```swift
// Sources/CodexQuickOKCore/SendSafety.swift
public enum SendSafetyError: Error, Equatable {
    case wrongApplication, sessionMismatch, existingDraft
}

public enum SendSafety {
    public static func validate(bundleId: String?, sessionMatched: Bool, composerValue: String) throws {
        guard bundleId == "com.openai.codex" else { throw SendSafetyError.wrongApplication }
        guard sessionMatched else { throw SendSafetyError.sessionMismatch }
        guard composerValue.isEmpty else { throw SendSafetyError.existingDraft }
    }
}
```

- [ ] **Step 4: Implement the testable automation contract and one-shot sender**

```swift
// Sources/CodexQuickOKApp/Automation/ApprovalSender.swift
import CodexQuickOKCore
import Foundation

@MainActor
protocol CodexAutomating: AnyObject {
    func activateAndOpen(sessionId: String) async throws
    func frontmostBundleIdentifier() -> String?
    func currentSessionMatches(_ sessionId: String) async throws -> Bool
    func composerValue() throws -> String
    func setComposerValue(_ value: String) throws
    func performSend() throws
}

@MainActor
protocol ApprovalSending: AnyObject {
    func sendOK(sessionId: String) async throws
}

@MainActor
final class ApprovalSender: ApprovalSending {
    private let automation: CodexAutomating
    private let isStillTarget: (String) async -> Bool
    private var sending = false

    init(
        automation: CodexAutomating,
        isStillTarget: @escaping (String) async -> Bool = { _ in true }
    ) {
        self.automation = automation
        self.isStillTarget = isStillTarget
    }

    func sendOK(sessionId: String) async throws {
        guard !sending else { return }
        sending = true
        defer { sending = false }
        try await automation.activateAndOpen(sessionId: sessionId)
        guard await isStillTarget(sessionId) else { throw SendSafetyError.sessionMismatch }
        let matched = try await automation.currentSessionMatches(sessionId)
        let value = try automation.composerValue()
        try SendSafety.validate(
            bundleId: automation.frontmostBundleIdentifier(),
            sessionMatched: matched,
            composerValue: value
        )
        try automation.setComposerValue("可")
        try automation.performSend()
    }
}
```

- [ ] **Step 5: Implement the system Accessibility adapter**

Use `NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")` to activate Codex. Open `codex://threads/<percent-encoded-session-id>` through `NSWorkspace`, then poll the Codex AX tree for at most 1.5 seconds. Validate the visible task identity against App Server `thread/read` metadata before returning. Locate only an editable `AXTextArea` or `AXTextField` inside the Codex window; reject native approval-card roles. Set `kAXValueAttribute` to `可`, then invoke exactly one uniquely identified composer send button's `kAXPressAction`. If no unique send button exists, fail without synthesizing Return.

Use this exact boundary so the AX traversal remains isolated:

```swift
// Sources/CodexQuickOKApp/Automation/AccessibilityClient.swift
import AppKit
import ApplicationServices

@MainActor
final class AccessibilityClient {
    enum AXError: Error {
        case permissionMissing, codexNotRunning, taskNotFound, ambiguousTask
        case composerMissing, nativeApprovalCard, sendActionMissing
    }
    private var composer: AXUIElement?

    func activateCodex() throws {
        guard AXIsProcessTrusted() else { throw AXError.permissionMissing }
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.openai.codex"
        ).first else { throw AXError.codexNotRunning }
        app.activate(options: [.activateIgnoringOtherApps])
    }

    func openThreadURL(sessionId: String) throws {
        guard let encoded = sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "codex://threads/\(encoded)"),
              NSWorkspace.shared.open(url) else { throw AXError.taskNotFound }
    }

    func waitForTask(title: String, cwd: String, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try currentTaskMatches(title: title, cwd: cwd) {
                composer = try uniqueComposer()
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw AXError.taskNotFound
    }

    func currentTaskMatches(title: String, cwd: String) throws -> Bool {
        let strings = try descendants().compactMap { string($0, kAXValueAttribute) ?? string($0, kAXTitleAttribute) }
        return strings.contains(title) && strings.contains(where: { $0.contains(cwd) })
    }

    func frontmostBundleIdentifier() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    func composerValue() throws -> String {
        guard let composer else { throw AXError.composerMissing }
        return string(composer, kAXValueAttribute) ?? ""
    }

    func setComposerValue(_ value: String) throws {
        guard let composer else { throw AXError.composerMissing }
        guard AXUIElementSetAttributeValue(composer, kAXValueAttribute, value as CFString) == .success
        else { throw AXError.composerMissing }
    }

    func pressSend() throws {
        let buttons = try descendants().filter {
            string($0, kAXRoleAttribute) == kAXButtonRole as String &&
            [string($0, kAXTitleAttribute), string($0, kAXDescriptionAttribute)]
                .compactMap { $0 }.contains(where: { ["Send", "发送"].contains($0) })
        }
        guard buttons.count == 1,
              AXUIElementPerformAction(buttons[0], kAXPressAction) == .success
        else { throw AXError.sendActionMissing }
    }

    private func uniqueComposer() throws -> AXUIElement {
        let elements = try descendants()
        let labels = elements.compactMap { string($0, kAXTitleAttribute) ?? string($0, kAXDescriptionAttribute) }
        if labels.contains(where: { ["Approve", "Allow", "批准", "允许"].contains($0) }) {
            throw AXError.nativeApprovalCard
        }
        let candidates = elements.filter {
            let role = string($0, kAXRoleAttribute)
            return role == kAXTextAreaRole as String || role == kAXTextFieldRole as String
        }
        guard candidates.count == 1 else {
            throw candidates.isEmpty ? AXError.composerMissing : AXError.ambiguousTask
        }
        return candidates[0]
    }

    private func descendants() throws -> [AXUIElement] {
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.openai.codex"
        ).first else { throw AXError.codexNotRunning }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute, &focusedValue
        ) == .success,
              let focusedWindow = focusedValue as? AXUIElement else {
            throw AXError.taskNotFound
        }
        var queue = [focusedWindow]
        var result: [AXUIElement] = []
        while !queue.isEmpty && result.count < 5_000 {
            let element = queue.removeFirst()
            result.append(element)
            queue.append(contentsOf: children(element))
        }
        return result
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute, &value) == .success
        else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func string(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success
        else { return nil }
        return value as? String
    }
}
```

```swift
// Sources/CodexQuickOKApp/Automation/CodexSessionNavigator.swift
@MainActor
final class SystemCodexAutomation: CodexAutomating {
    private let accessibility: AccessibilityClient
    private let appServer: CodexAppServerClient
    private var metadata: CodexAppServerClient.ThreadMetadata?

    init(accessibility: AccessibilityClient, appServer: CodexAppServerClient) {
        self.accessibility = accessibility
        self.appServer = appServer
    }

    func activateAndOpen(sessionId: String) async throws {
        let metadata = try await appServer.readThreadMetadata(sessionId: sessionId)
        try accessibility.activateCodex()
        try accessibility.openThreadURL(sessionId: sessionId)
        try await accessibility.waitForTask(title: metadata.title, cwd: metadata.cwd, timeout: 1.5)
        self.metadata = metadata
    }

    func frontmostBundleIdentifier() -> String? { accessibility.frontmostBundleIdentifier() }
    func currentSessionMatches(_ sessionId: String) async throws -> Bool {
        guard let metadata, metadata.id == sessionId else { return false }
        return try accessibility.currentTaskMatches(title: metadata.title, cwd: metadata.cwd)
    }
    func composerValue() throws -> String { try accessibility.composerValue() }
    func setComposerValue(_ value: String) throws { try accessibility.setComposerValue(value) }
    func performSend() throws { try accessibility.pressSend() }
}
```

This adapter walks only the Codex process AX tree, throws the typed errors above, and never uses the system clipboard.

- [ ] **Step 6: Add fake automation and verify all failure paths**

```swift
// Tests/CodexQuickOKAppTests/FakeCodexAutomation.swift
@MainActor
final class FakeCodexAutomation: CodexAutomating {
    enum FakeError: Error { case activationFailed }
    var bundleId: String?
    var matched: Bool
    var value: String
    var activationDelay: Duration?
    var activationError: Error?
    var writtenValues: [String] = []
    var sendCount = 0

    init(bundleId: String?, matched: Bool, value: String) {
        self.bundleId = bundleId
        self.matched = matched
        self.value = value
    }

    func activateAndOpen(sessionId: String) async throws {
        if let activationDelay { try await Task.sleep(for: activationDelay) }
        if let activationError { throw activationError }
    }
    func frontmostBundleIdentifier() -> String? { bundleId }
    func currentSessionMatches(_ sessionId: String) async throws -> Bool { matched }
    func composerValue() throws -> String { value }
    func setComposerValue(_ value: String) throws { writtenValues.append(value); self.value = value }
    func performSend() throws { sendCount += 1 }
}
```

The tests above cover wrong bundle ID, session mismatch, non-empty draft, duplicate in-flight click, and an AX-style activation failure. Every failure leaves `writtenValues == []` and `sendCount == 0`.

- [ ] **Step 7: Run full tests and a permission-revoked smoke test**

Run: `swift test`

Then revoke Accessibility permission for the debug app and click the button. Expected: tests PASS; the app shows its permission guidance, does not type into Codex, and does not type into the previously frontmost application.

- [ ] **Step 8: Commit safe automation**

```bash
git add Sources/CodexQuickOKCore/SendSafety.swift Sources/CodexQuickOKApp/Automation Tests/CodexQuickOKCoreTests/SendSafetyTests.swift Tests/CodexQuickOKAppTests/ApprovalSenderTests.swift
git commit -m "feat(automation): Send approval only to verified Codex task"
```

### Task 8: App Orchestration, Process Monitoring, and Login Item

**Files:**
- Create: `Sources/CodexQuickOKApp/AppMain.swift`
- Create: `Sources/CodexQuickOKApp/AppDelegate.swift`
- Create: `Sources/CodexQuickOKApp/AppController.swift`
- Create: `Sources/CodexQuickOKApp/SessionDirectoryMonitor.swift`
- Create: `Sources/CodexQuickOKApp/CodexProcessMonitor.swift`
- Create: `Tests/CodexQuickOKAppTests/AppControllerTests.swift`

**Interfaces:**
- Consumes: store, snapshot evaluator, panel, quota client, and approval sender from Tasks 1–7.
- Produces: one lifecycle owner that shows/hides the panel, refreshes quota, and confirms same-session sends.

- [ ] **Step 1: Write a failing orchestration test**

```swift
// Tests/CodexQuickOKAppTests/AppControllerTests.swift
import CodexQuickOKCore
import XCTest
@testable import CodexQuickOKApp

@MainActor
final class AppControllerTests: XCTestCase {
    func testCodexTerminationHidesPanelAndClearsTarget() async throws {
        let panel = FakePanel()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let controller = AppController(
            store: SessionStateStore(directory: directory), panel: panel, sender: FakeSender()
        )
        controller.apply(states: [Fixtures.waiting("s1")], codexRunning: true)
        XCTAssertEqual(panel.lastMode, .waiting)
        controller.apply(states: [Fixtures.waiting("s1")], codexRunning: false)
        XCTAssertEqual(panel.lastMode, .hidden)
        XCTAssertNil(controller.targetSessionId)
    }

    func testConfirmationTimeoutDoesNotRetry() async throws {
        let panel = FakePanel()
        let sender = FakeSender()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let controller = AppController(
            store: SessionStateStore(directory: directory), panel: panel,
            sender: sender, confirmationTimeout: 0.01
        )
        controller.apply(states: [Fixtures.waiting("s1")], codexRunning: true)
        panel.onActivate?()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(sender.sessionIds, ["s1"])
        XCTAssertEqual(panel.failures, ["发送结果不确定，请检查 Codex"])
    }
}

@MainActor
private final class FakePanel: CompanionPanel {
    var onActivate: (() -> Void)?
    var onTemporaryHide: (() -> Void)?
    var lastMode: CompanionMode = .hidden
    var failures: [String] = []
    func show(mode: CompanionMode) { lastMode = mode }
    func hide() { lastMode = .hidden }
    func setQuota(_ quota: WeeklyQuota?) {}
    func setSending(_ sending: Bool) {}
    func showSuccess() {}
    func showFailure(_ message: String) { failures.append(message) }
}

@MainActor
private final class FakeSender: ApprovalSending {
    var sessionIds: [String] = []
    func sendOK(sessionId: String) async throws { sessionIds.append(sessionId) }
}

private enum Fixtures {
    static func waiting(_ id: String) -> SessionState {
        let now = Date()
        return SessionState(
            sessionId: id, phase: .waitingForApproval,
            updatedAt: now, waitingSince: now
        )
    }
}
```

- [ ] **Step 2: Run test and verify missing controller failure**

Run: `swift test --filter AppControllerTests`

Expected: FAIL with `cannot find 'AppController' in scope`.

- [ ] **Step 3: Implement process and directory monitors**

```swift
// Sources/CodexQuickOKApp/CodexProcessMonitor.swift
import AppKit

@MainActor
final class CodexProcessMonitor: NSObject {
    var onChange: ((Bool) -> Void)?
    private let workspace = NSWorkspace.shared
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let center = workspace.notificationCenter
        center.addObserver(
            self, selector: #selector(applicationChanged(_:)),
            name: NSWorkspace.didLaunchApplicationNotification, object: nil
        )
        center.addObserver(
            self, selector: #selector(applicationChanged(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil
        )
        onChange?(isCodexRunning)
    }

    func stop() {
        guard started else { return }
        workspace.notificationCenter.removeObserver(self)
        started = false
    }

    private var isCodexRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").isEmpty
    }

    @objc private func applicationChanged(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
              app.bundleIdentifier == "com.openai.codex" else { return }
        onChange?(isCodexRunning)
    }

    deinit { workspace.notificationCenter.removeObserver(self) }
}
```

```swift
// Sources/CodexQuickOKApp/SessionDirectoryMonitor.swift
import Darwin
import Foundation

@MainActor
final class SessionDirectoryMonitor {
    enum MonitorError: Error { case cannotOpenDirectory }
    var onChange: (() -> Void)?
    private let directory: URL
    private var descriptor: CInt = -1
    private var source: DispatchSourceFileSystemObject?
    private var debounce: DispatchWorkItem?

    init(directory: URL) { self.directory = directory }

    func start() throws {
        guard source == nil else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { throw MonitorError.cannotOpenDirectory }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .attrib], queue: .main
        )
        source.setEventHandler { [weak self] in self?.scheduleChange() }
        source.setCancelHandler { [descriptor] in close(descriptor) }
        self.source = source
        source.resume()
        onChange?()
    }

    func stop() {
        debounce?.cancel()
        debounce = nil
        source?.cancel()
        source = nil
        descriptor = -1
    }

    private func scheduleChange() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange?() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100), execute: work)
    }

    deinit {
        source?.cancel()
        if source == nil, descriptor >= 0 { close(descriptor) }
    }
}
```

- [ ] **Step 4: Implement the controller state loop**

```swift
// Sources/CodexQuickOKApp/AppController.swift
import CodexQuickOKCore
import Foundation

@MainActor
final class AppController {
    private let store: SessionStateStore
    private let panel: any CompanionPanel
    private let sender: any ApprovalSending
    private let confirmationTimeout: TimeInterval
    private var codexRunning = false
    private(set) var targetSessionId: String?
    private var pendingConfirmation: (sessionId: String, deadline: Date)?
    private var currentSnapshot = CompanionSnapshot(mode: .hidden, targetSessionId: nil)
    private var temporarilyHiddenSnapshot: CompanionSnapshot?

    init(
        store: SessionStateStore, panel: any CompanionPanel, sender: any ApprovalSending,
        confirmationTimeout: TimeInterval = 2
    ) {
        self.store = store
        self.panel = panel
        self.sender = sender
        self.confirmationTimeout = confirmationTimeout
        panel.onActivate = { [weak self] in Task { await self?.activate() } }
        panel.onTemporaryHide = { [weak self] in
            guard let self else { return }
            self.temporarilyHiddenSnapshot = self.currentSnapshot
            self.panel.hide()
        }
    }

    func apply(states: [SessionState], codexRunning: Bool) {
        self.codexRunning = codexRunning
        if let pendingConfirmation,
           Date() <= pendingConfirmation.deadline,
           states.contains(where: {
               $0.sessionId == pendingConfirmation.sessionId && $0.phase == .running
           }) {
            panel.showSuccess()
            self.pendingConfirmation = nil
        }
        let snapshot = SessionSnapshotEvaluator.evaluate(states: states, codexRunning: codexRunning, now: Date())
        currentSnapshot = snapshot
        targetSessionId = snapshot.targetSessionId
        if temporarilyHiddenSnapshot == snapshot {
            panel.hide()
            return
        }
        temporarilyHiddenSnapshot = nil
        panel.show(mode: snapshot.mode)
    }

    func updateCodexRunning(_ running: Bool) async {
        codexRunning = running
        if running { await reload() }
        else {
            try? await store.removeAll()
            apply(states: [], codexRunning: false)
        }
    }

    func reload() async {
        let states = (try? await store.loadAll(now: Date(), staleAfter: 43_200)) ?? []
        apply(states: states, codexRunning: codexRunning)
    }

    private func activate() async {
        guard let targetSessionId else {
            panel.showFailure("暂无待批准会话")
            return
        }
        panel.setSending(true)
        defer { panel.setSending(false) }
        pendingConfirmation = (targetSessionId, Date().addingTimeInterval(confirmationTimeout))
        do {
            try await sender.sendOK(sessionId: targetSessionId)
            try? await Task.sleep(for: .seconds(confirmationTimeout))
            if let pendingConfirmation, Date() >= pendingConfirmation.deadline {
                self.pendingConfirmation = nil
                panel.showFailure("发送结果不确定，请检查 Codex")
            }
        }
        catch {
            pendingConfirmation = nil
            panel.showFailure(String(describing: error))
        }
    }
}
```

- [ ] **Step 5: Add app entry, Accessibility onboarding, and login item registration**

```swift
// Sources/CodexQuickOKApp/AppMain.swift
import AppKit

@main
struct CodexQuickOKAppMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
```

In `AppDelegate.applicationDidFinishLaunching`, handle uninstall mode before normal startup:

```swift
if CommandLine.arguments.contains("--unregister-login-item") {
    Task { @MainActor in
        try? await SMAppService.mainApp.unregister()
        NSApplication.shared.terminate(nil)
    }
    return
}
```

Implement the rest of the lifecycle owner exactly as follows:

```swift
// Sources/CodexQuickOKApp/AppDelegate.swift
import AppKit
import ApplicationServices
import CodexQuickOKCore
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appServer = CodexAppServerClient()
    private var panel: FloatingPanelController?
    private var controller: AppController?
    private var sessionMonitor: SessionDirectoryMonitor?
    private var processMonitor: CodexProcessMonitor?
    private var quotaTimer: Timer?
    private var appServerStarted = false
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--unregister-login-item") {
            Task { @MainActor in
                try? await SMAppService.mainApp.unregister()
                NSApplication.shared.terminate(nil)
            }
            return
        }

        showOnboardingIfNeeded()
        if !AXIsProcessTrusted() {
            let options = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
            ] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        if SMAppService.mainApp.status == .notRegistered {
            try? SMAppService.mainApp.register()
        }

        guard let directory = try? SessionStateStore.defaultDirectory() else {
            NSApplication.shared.terminate(nil)
            return
        }
        let store = SessionStateStore(directory: directory)
        let panel = FloatingPanelController()
        let automation = SystemCodexAutomation(
            accessibility: AccessibilityClient(), appServer: appServer
        )
        let sender = ApprovalSender(automation: automation) { sessionId in
            let states = (try? await store.loadAll(now: Date(), staleAfter: 43_200)) ?? []
            return SessionSnapshotEvaluator.evaluate(
                states: states, codexRunning: true, now: Date()
            ).targetSessionId == sessionId
        }
        let controller = AppController(
            store: store, panel: panel, sender: sender
        )
        let sessionMonitor = SessionDirectoryMonitor(directory: directory)
        let processMonitor = CodexProcessMonitor()
        self.panel = panel
        self.controller = controller
        self.sessionMonitor = sessionMonitor
        self.processMonitor = processMonitor

        panel.hide()
        panel.onRefreshQuota = { [weak self] in self?.refreshQuota() }
        sessionMonitor.onChange = { [weak controller] in
            Task { @MainActor in await controller?.reload() }
        }
        processMonitor.onChange = { [weak controller] running in
            Task { @MainActor in await controller?.updateCodexRunning(running) }
        }
        do { try sessionMonitor.start() }
        catch { panel.showFailure("无法监控 Codex 会话状态") }
        processMonitor.start()

        quotaTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) {
            [weak self] _ in Task { @MainActor in self?.refreshQuota() }
        }
        Task { @MainActor [weak self] in await self?.startAppServer() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        quotaTimer?.invalidate()
        reconnectTask?.cancel()
        sessionMonitor?.stop()
        processMonitor?.stop()
        Task { await appServer.stop() }
    }

    private func startAppServer() async {
        do {
            let binary = try Self.codexBinaryURL()
            try await appServer.start(codexBinary: binary)
            try await appServer.setRateLimitUpdateHandler { [weak self] in
                Task { @MainActor in self?.refreshQuota() }
            }
            appServerStarted = true
            reconnectAttempt = 0
            refreshQuota()
        } catch {
            appServerStarted = false
            panel?.setQuota(nil)
            scheduleReconnect()
        }
    }

    private func refreshQuota() {
        guard appServerStarted else { panel?.setQuota(nil); return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await appServer.readRateLimits()
                panel?.setQuota(QuotaSelector.weeklyQuota(from: result))
            } catch {
                appServerStarted = false
                panel?.setQuota(nil)
                await appServer.stop()
                scheduleReconnect()
            }
        }
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        let delay = min(pow(2.0, Double(reconnectAttempt)), 300)
        reconnectAttempt += 1
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            reconnectTask = nil
            await startAppServer()
        }
    }

    private func showOnboardingIfNeeded() {
        let key = "didShowOnboarding.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "启用 Codex 可"
        alert.informativeText = "接下来只需授予辅助功能权限，并在 Codex 的 /hooks 页面审查并信任 codex-quick-ok。登录项默认开启；没有活动任务时按钮会自动隐藏。"
        alert.addButton(withTitle: "继续")
        alert.runModal()
        UserDefaults.standard.set(true, forKey: key)
    }

    private static func codexBinaryURL() throws -> URL {
        guard let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.openai.codex"
        ) else { throw CodexAppServerClient.ClientError.codexBinaryMissing }
        let binary = appURL.appendingPathComponent("Contents/Resources/codex")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw CodexAppServerClient.ClientError.codexBinaryMissing
        }
        return binary
    }
}
```

This code prompts only for Accessibility, registers the main app once, resolves the Codex CLI from the installed `com.openai.codex` bundle, refreshes quota every 300 seconds, and stops owned monitors and the child App Server process on termination.

- [ ] **Step 6: Confirm sends only from same-session Hook changes**

After `ApprovalSender.performSend`, record the target and deadline. A session-directory update confirms success only when the same `sessionId` becomes `.running` within 2 seconds. On confirmation, flash green and re-evaluate visibility. On timeout, show “发送结果不确定，请检查 Codex”; do not call `sendOK` again.

- [ ] **Step 7: Run orchestration tests and app lifecycle smoke tests**

Run: `swift test && swift run CodexQuickOKApp`

Expected: tests PASS; app has no Dock icon, registers as a login item, stays hidden while idle, shows for a synthetic running/waiting state, and hides immediately when Codex terminates.

- [ ] **Step 8: Commit orchestration**

```bash
git add Sources/CodexQuickOKApp Tests/CodexQuickOKAppTests/AppControllerTests.swift
git commit -m "feat(app): Orchestrate Codex session companion"
```

### Task 9: App Bundle, Local Marketplace, Install, and Uninstall

**Files:**
- Modify: `.gitignore`
- Create: `Resources/Info.plist`
- Create: `Resources/PrivacyInfo.xcprivacy`
- Create: `marketplace/.agents/plugins/marketplace.json`
- Create: `scripts/build-release.sh`
- Create: `scripts/install-local.sh`
- Create: `scripts/uninstall-local.sh`
- Create: `README.md`

**Interfaces:**
- Consumes: release binaries from SwiftPM and plugin sources from Task 2.
- Produces: `dist/Codex 可.app` and `dist/marketplace`.
- Produces: reversible local installation with no edits to existing Hook files.

- [ ] **Step 1: Add exact app and marketplace metadata**

Append `dist/` to `.gitignore` so packaged binaries do not dirty the tracked worktree.

```xml
<!-- Resources/Info.plist -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>CodexQuickOKApp</string>
  <key>CFBundleIdentifier</key><string>com.codexquickok.CodexQuickOK</string>
  <key>CFBundleName</key><string>Codex 可</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
```

```xml
<!-- Resources/PrivacyInfo.xcprivacy -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>NSPrivacyTracking</key><false/>
  <key>NSPrivacyCollectedDataTypes</key><array/>
  <key>NSPrivacyAccessedAPITypes</key><array/>
</dict></plist>
```

```json
{
  "name": "codex-quick-ok-local",
  "interface": {"displayName": "Codex Quick OK Local"},
  "plugins": [{
    "name": "codex-quick-ok",
    "source": {"source":"local","path":"./plugins/codex-quick-ok"},
    "policy": {"installation":"AVAILABLE","authentication":"ON_INSTALL"},
    "category": "Productivity"
  }]
}
```

- [ ] **Step 2: Implement deterministic release packaging**

```bash
#!/bin/zsh
# scripts/build-release.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
swift build --package-path "$ROOT" -c release
rm -rf "$ROOT/dist"
APP="$ROOT/dist/Codex 可.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/dist/marketplace/plugins/codex-quick-ok/bin"
cp "$ROOT/.build/release/CodexQuickOKApp" "$APP/Contents/MacOS/CodexQuickOKApp"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/PrivacyInfo.xcprivacy" "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
cp -R "$ROOT/plugin/codex-quick-ok/." "$ROOT/dist/marketplace/plugins/codex-quick-ok/"
cp "$ROOT/.build/release/CodexQuickOKHook" "$ROOT/dist/marketplace/plugins/codex-quick-ok/bin/CodexQuickOKHook"
mkdir -p "$ROOT/dist/marketplace/.agents/plugins"
cp "$ROOT/marketplace/.agents/plugins/marketplace.json" "$ROOT/dist/marketplace/.agents/plugins/marketplace.json"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
```

- [ ] **Step 3: Implement scoped install and uninstall scripts**

```bash
#!/bin/zsh
# scripts/install-local.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="$ROOT/dist/Codex 可.app"
DEST_APP="$HOME/Applications/Codex 可.app"
test -d "$SOURCE_APP" || zsh "$ROOT/scripts/build-release.sh"
mkdir -p "$HOME/Applications"
rm -rf "$DEST_APP"
ditto "$SOURCE_APP" "$DEST_APP"
codex plugin marketplace add "$ROOT/dist/marketplace" --json
codex plugin add codex-quick-ok --marketplace codex-quick-ok-local --json
open "$DEST_APP"
print '下一步 1：在系统设置中仅授予“Codex 可”辅助功能权限。'
print '下一步 2：在 Codex /hooks 中审查并信任 codex-quick-ok。'
```

```bash
#!/bin/zsh
# scripts/uninstall-local.sh
set -euo pipefail
APP="$HOME/Applications/Codex 可.app"
codex plugin remove codex-quick-ok --marketplace codex-quick-ok-local --json || true
codex plugin marketplace remove codex-quick-ok-local || true
if [[ -d "$APP" ]]; then
  open -W "$APP" --args --unregister-login-item || true
fi
rm -rf "$APP" "$HOME/Library/Application Support/CodexQuickOK"
```

The uninstall script deletes only these owned paths:

```text
$HOME/Applications/Codex 可.app
$HOME/Library/Application Support/CodexQuickOK
```

It must not remove `~/.codex/config.toml`, `~/.codex/hooks.json`, unrelated plugins, or Accessibility permissions for other apps.

- [ ] **Step 4: Write the user guide with exact onboarding order**

Create `README.md` with these exact sections and commands:

````markdown
# Codex 可

一个只向 Codex 对话回复“可”的 macOS 悬浮按钮，光环只显示周额度。

## 安装

```bash
zsh scripts/build-release.sh
zsh scripts/install-local.sh
```

安装后只授予“辅助功能”权限，然后在 Codex `/hooks` 中审查并信任
`codex-quick-ok`。新开或恢复一个 Codex 任务后，Hook 才会产生状态。

## 使用

- 任务运行或等待批准时显示；完全空闲时隐藏。
- 单击会切换到最近待批准任务并发送一次“可”。
- 拖动超过 5 pt 只移动按钮；右键可看周额度、刷新、隐藏或退出。
- 灰色光环表示官方接口暂未提供明确周额度，不代表额度为零。

## 安全边界

原生审批卡片不受支持；输入框已有草稿时不会覆盖或发送；目标无法唯一确认时安全失败。

## 卸载

```bash
zsh scripts/uninstall-local.sh
```
````

- [ ] **Step 5: Package and validate artifacts**

Run:

```bash
zsh scripts/build-release.sh
plutil -lint 'dist/Codex 可.app/Contents/Info.plist'
codesign --verify --deep --strict 'dist/Codex 可.app'
test -x 'dist/marketplace/plugins/codex-quick-ok/bin/CodexQuickOKHook'
codex plugin marketplace add ./dist/marketplace --json
codex plugin list --json
```

Expected: build succeeds, plist and signature validate, Hook is executable, marketplace is accepted, and `codex-quick-ok` appears as available or installed.

- [ ] **Step 6: Commit packaging and documentation**

```bash
git add .gitignore Resources marketplace scripts README.md
git commit -m "build: Package Codex Quick OK companion"
```

### Task 10: Real Codex End-to-End Verification and Deliverable

**Files:**
- Create: `docs/manual-verification.md`
- Modify only if failures require fixes: files owned by Tasks 1–9

**Interfaces:**
- Consumes: installed `.app`, trusted plugin, and real Codex app.
- Produces: checked acceptance evidence and a user-facing `.app` artifact.

- [ ] **Step 1: Record the exact acceptance matrix**

```markdown
# Manual Verification

- [ ] Idle Codex: button hidden.
- [ ] Running task: button visible with breathing halo.
- [ ] Approval-style Stop message: button remains visible.
- [ ] Ordinary completed answer: button hides.
- [ ] Two waiting tasks: newest waiting task is selected.
- [ ] Other app frontmost: click activates Codex and sends exactly one `可`.
- [ ] Running-only state: click shows `暂无待批准会话` and sends nothing.
- [ ] Non-empty Codex draft: click refuses and preserves the draft.
- [ ] Native approval card: click reports unsupported and sends nothing.
- [ ] Accessibility revoked: click opens guidance and sends nothing.
- [ ] Weekly quota present: ring equals `100 - usedPercent` and tooltip reset time is local.
- [ ] Weekly quota absent: ring is gray; no short-window fallback appears.
- [ ] Drag over 5 pt: position changes without a send.
- [ ] Repeated click during send: at most one `可` is submitted.
- [ ] Codex exits: panel hides immediately.
- [ ] App restart and display change: normalized panel position is restored on-screen.
- [ ] Uninstall: app, login item, plugin, marketplace, and owned state are removed only.
```

- [ ] **Step 2: Run automated verification before manual interaction**

Run:

```bash
swift test
zsh scripts/build-release.sh
codesign --verify --deep --strict 'dist/Codex 可.app'
git diff --check
```

Expected: all tests PASS, packaging succeeds, signature verifies, and `git diff --check` prints nothing.

- [ ] **Step 3: Install, trust the Hook, and execute every manual check**

Run `zsh scripts/install-local.sh`, grant only Accessibility when macOS prompts, review the Hook in Codex, and execute the matrix in order. Add the test date, Codex desktop version `26.707.72221`, CLI version `0.143.0`, macOS version `26.5.2`, and PASS/FAIL beside every row. Any failure returns to the owning task and requires a focused regression test before repeating the matrix.

- [ ] **Step 4: Copy the verified app to the user-facing output directory**

Run:

```bash
rm -rf outputs/'Codex 可.app'
cp -R dist/'Codex 可.app' outputs/'Codex 可.app'
ditto -c -k --keepParent dist/marketplace outputs/'CodexQuickOK-Codex插件.zip'
```

Expected: `outputs/Codex 可.app` launches and the plugin ZIP contains the local marketplace descriptor plus executable Hook.

- [ ] **Step 5: Commit verification evidence**

```bash
git add docs/manual-verification.md
git commit -m "test: Verify Codex Quick OK end to end"
```

- [ ] **Step 6: Final clean-tree and artifact checks**

Run:

```bash
git status --short
git log --oneline --decorate -10
test -d 'outputs/Codex 可.app'
test -f 'outputs/CodexQuickOK-Codex插件.zip'
```

Expected: tracked worktree is clean; the task commits are visible; both user-facing artifacts exist.
