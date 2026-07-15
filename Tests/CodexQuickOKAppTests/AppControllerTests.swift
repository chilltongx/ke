import AppKit
import CodexQuickOKCore
import Foundation
import XCTest
@testable import CodexQuickOKApp

@MainActor
final class AppControllerTests: XCTestCase {
    func testCodexTerminationHidesPanelAndClearsTarget() {
        let panel = FakePanel()
        let controller = makeController(panel: panel)

        controller.apply(states: [Fixtures.waiting("s1")], codexRunning: true)
        XCTAssertEqual(panel.lastMode, .waiting)

        controller.apply(states: [Fixtures.waiting("s1")], codexRunning: false)

        XCTAssertEqual(panel.lastMode, .hidden)
        XCTAssertNil(controller.targetSessionId)
    }

    func testConfirmationTimeoutDoesNotRetry() async throws {
        let panel = FakePanel()
        let sender = FakeSender()
        let controller = makeController(
            panel: panel,
            sender: sender,
            confirmationTimeout: 0.01
        )
        controller.apply(states: [Fixtures.waiting("s1")], codexRunning: true)

        panel.onActivate?()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(sender.sessionIds, ["s1"])
        XCTAssertEqual(panel.failures, ["发送结果不确定，请检查 Codex"])
        XCTAssertEqual(panel.sendingValues, [true, false])
    }

    func testSameSessionRunningConfirmsSendWithinDeadline() async throws {
        let panel = FakePanel()
        let sender = FakeSender()
        let controller = makeController(
            panel: panel,
            sender: sender,
            confirmationTimeout: 1
        )
        controller.apply(states: [Fixtures.waiting("s1")], codexRunning: true)

        panel.onActivate?()
        try await Task.sleep(for: .milliseconds(5))
        controller.apply(states: [Fixtures.running("s1")], codexRunning: true)
        try await Task.sleep(for: .milliseconds(5))

        XCTAssertEqual(sender.sessionIds, ["s1"])
        XCTAssertEqual(panel.successCount, 1)
        XCTAssertTrue(panel.failures.isEmpty)
        XCTAssertEqual(panel.lastMode, .running)
    }

    func testDifferentSessionRunningDoesNotConfirmSend() async throws {
        let panel = FakePanel()
        let sender = FakeSender()
        let controller = makeController(
            panel: panel,
            sender: sender,
            confirmationTimeout: 0.01
        )
        controller.apply(states: [Fixtures.waiting("s1")], codexRunning: true)

        panel.onActivate?()
        try await Task.sleep(for: .milliseconds(2))
        controller.apply(states: [Fixtures.running("s2")], codexRunning: true)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(panel.successCount, 0)
        XCTAssertEqual(panel.failures, ["发送结果不确定，请检查 Codex"])
        XCTAssertEqual(sender.sessionIds, ["s1"])
    }

    func testConfirmationUnlocksSendingImmediately() async throws {
        let panel = FakePanel()
        let controller = makeController(
            panel: panel,
            confirmationTimeout: 1
        )
        controller.apply(states: [Fixtures.waiting("s1")], codexRunning: true)

        panel.onActivate?()
        try await Task.sleep(for: .milliseconds(5))
        controller.apply(states: [Fixtures.running("s1")], codexRunning: true)
        try await Task.sleep(for: .milliseconds(5))

        XCTAssertEqual(panel.sendingValues, [true, false])
    }

    func testActivationIsLockedWhileSendIsInProgress() async throws {
        let panel = FakePanel()
        let sender = FakeSender(delay: 0.03)
        let controller = makeController(
            panel: panel,
            sender: sender,
            confirmationTimeout: 0.01
        )
        controller.apply(states: [Fixtures.waiting("s1")], codexRunning: true)

        panel.onActivate?()
        panel.onActivate?()
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(sender.sessionIds, ["s1"])
        XCTAssertEqual(panel.failures, ["发送结果不确定，请检查 Codex"])
    }

    func testTemporaryHidePersistsUntilSnapshotChanges() {
        let panel = FakePanel()
        let controller = makeController(panel: panel)
        let waiting = Fixtures.waiting("s1")
        controller.apply(states: [waiting], codexRunning: true)

        panel.onTemporaryHide?()
        controller.apply(states: [waiting], codexRunning: true)

        XCTAssertEqual(panel.lastMode, .hidden)

        controller.apply(states: [Fixtures.running("s1")], codexRunning: true)

        XCTAssertEqual(panel.lastMode, .running)
    }

    func testNoTargetActivationDoesNotCallSender() async throws {
        let panel = FakePanel()
        let sender = FakeSender()
        let controller = makeController(panel: panel, sender: sender)
        controller.apply(states: [Fixtures.running("s1")], codexRunning: true)

        panel.onActivate?()
        try await Task.sleep(for: .milliseconds(5))

        XCTAssertTrue(sender.sessionIds.isEmpty)
        XCTAssertEqual(panel.failures, ["暂无待批准会话"])
    }

    func testStopCancelsPendingSendAndClearsTarget() async throws {
        let panel = FakePanel()
        let sender = FakeSender(delay: 1)
        let controller = makeController(panel: panel, sender: sender)
        controller.apply(states: [Fixtures.waiting("s1")], codexRunning: true)
        panel.onActivate?()
        try await Task.sleep(for: .milliseconds(5))

        controller.stop()
        try await Task.sleep(for: .milliseconds(5))

        XCTAssertNil(controller.targetSessionId)
        XCTAssertEqual(panel.lastMode, .hidden)
        XCTAssertTrue(panel.failures.isEmpty)
        XCTAssertEqual(panel.sendingValues, [true, false])
    }

    func testTerminateThenLaunchIgnoresOlderSuspendedTermination() async throws {
        let panel = FakePanel()
        let store = ControlledSessionStore(suspendRemoval: true)
        let controller = makeController(panel: panel, store: store)

        controller.processStateChanged(false)
        controller.processStateChanged(true)
        await waitUntil { await store.loadCallCount == 1 }
        await store.resumeLoad(with: [Fixtures.waiting("relaunched")])
        await store.resumeRemovalIfNeeded()
        await waitUntil { controller.targetSessionId == "relaunched" }

        XCTAssertEqual(panel.lastMode, .waiting)
        XCTAssertEqual(controller.targetSessionId, "relaunched")
        let removeCallCount = await store.removeCallCount
        XCTAssertEqual(removeCallCount, 0)
    }

    func testLaunchThenTerminatePreventsOlderLoadFromApplying() async throws {
        let panel = FakePanel()
        let store = ControlledSessionStore()
        let controller = makeController(panel: panel, store: store)

        controller.processStateChanged(true)
        await waitUntil { await store.loadCallCount == 1 }
        controller.processStateChanged(false)
        await store.resumeLoad(with: [Fixtures.waiting("stale-launch")])
        await spinMainActor()

        XCTAssertEqual(panel.lastMode, .hidden)
        XCTAssertNil(controller.targetSessionId)
        XCTAssertEqual(panel.shownModes.filter { $0 == .hidden }.count, 1)
    }

    func testOldCancelledSendCannotReleaseReplacementAttempt() async throws {
        let panel = FakePanel()
        let sender = ControlledApprovalSender()
        let controller = makeController(panel: panel, sender: sender, confirmationTimeout: 1)
        let receiptDate = Date()
        controller.apply(
            states: [Fixtures.waiting("s1", updatedAt: receiptDate.addingTimeInterval(-10))],
            codexRunning: true
        )

        panel.onActivate?()
        await waitUntil { sender.callCount == 1 }
        controller.apply(states: [], codexRunning: false)
        controller.apply(
            states: [Fixtures.waiting("s2", updatedAt: receiptDate.addingTimeInterval(-5))],
            codexRunning: true
        )
        panel.onActivate?()
        await waitUntil { sender.callCount == 2 }
        sender.emitReceipt(forCall: 1, sentAt: receiptDate)

        sender.finish(call: 0)
        await spinMainActor()
        panel.onActivate?()
        await spinMainActor()

        XCTAssertEqual(sender.sessionIds, ["s1", "s2"])
        XCTAssertEqual(panel.sendingValues.last, true)

        controller.apply(
            states: [Fixtures.running("s2", updatedAt: receiptDate.addingTimeInterval(0.1))],
            codexRunning: true
        )
        XCTAssertEqual(panel.successCount, 1)
        XCTAssertEqual(panel.sendingValues.last, false)
        sender.finish(call: 1)
    }

    func testReceiptCanConfirmBeforeSendMethodReturns() async throws {
        let panel = FakePanel()
        let sender = ControlledApprovalSender()
        let controller = makeController(panel: panel, sender: sender, confirmationTimeout: 1)
        let receiptDate = Date()
        controller.apply(
            states: [Fixtures.waiting("s1", updatedAt: receiptDate.addingTimeInterval(-1))],
            codexRunning: true
        )

        panel.onActivate?()
        await waitUntil { sender.callCount == 1 }
        sender.emitReceipt(forCall: 0, sentAt: receiptDate)
        controller.apply(
            states: [Fixtures.running("s1", updatedAt: receiptDate.addingTimeInterval(0.1))],
            codexRunning: true
        )

        XCTAssertEqual(panel.successCount, 1)
        XCTAssertEqual(panel.sendingValues.last, false)
        sender.finish(call: 0)
    }

    func testStaleSameSessionRunningDoesNotConfirmNewAttempt() async throws {
        let panel = FakePanel()
        let sender = ControlledApprovalSender()
        let controller = makeController(panel: panel, sender: sender, confirmationTimeout: 0.01)
        let receiptDate = Date()
        controller.apply(
            states: [Fixtures.waiting("s1", updatedAt: receiptDate.addingTimeInterval(-2))],
            codexRunning: true
        )

        panel.onActivate?()
        await waitUntil { sender.callCount == 1 }
        sender.emitReceipt(forCall: 0, sentAt: receiptDate)
        controller.apply(
            states: [Fixtures.running("s1", updatedAt: receiptDate.addingTimeInterval(-1))],
            codexRunning: true
        )
        sender.finish(call: 0)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(panel.successCount, 0)
        XCTAssertEqual(panel.failures, ["发送结果不确定，请检查 Codex"])
        XCTAssertEqual(sender.sessionIds, ["s1"])
    }

    private func makeController(
        panel: FakePanel,
        sender: any ApprovalSending = FakeSender(),
        store: (any SessionStateStoring)? = nil,
        confirmationTimeout: TimeInterval = 2
    ) -> AppController {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        return AppController(
            store: store ?? SessionStateStore(directory: directory),
            panel: panel,
            sender: sender,
            confirmationTimeout: confirmationTimeout
        )
    }
}

@MainActor
private final class FakePanel: CompanionPanel {
    var onActivate: (() -> Void)?
    var onTemporaryHide: (() -> Void)?
    var lastMode: CompanionMode = .hidden
    var failures: [String] = []
    var successCount = 0
    var sendingValues: [Bool] = []
    var shownModes: [CompanionMode] = []

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
private final class FakeSender: ApprovalSending {
    var sessionIds: [String] = []
    private let delay: TimeInterval

    init(delay: TimeInterval = 0) {
        self.delay = delay
    }

    func sendOK(
        sessionId: String,
        onReceipt: @escaping @MainActor (ApprovalSendReceipt) -> Void
    ) async throws {
        sessionIds.append(sessionId)
        onReceipt(ApprovalSendReceipt(sentAt: Date()))
        if delay > 0 {
            try await Task.sleep(for: .seconds(delay))
        }
    }
}

private enum Fixtures {
    static func waiting(_ id: String, updatedAt: Date = Date()) -> SessionState {
        return SessionState(
            sessionId: id,
            phase: .waitingForApproval,
            updatedAt: updatedAt,
            waitingSince: updatedAt
        )
    }

    static func running(_ id: String, updatedAt: Date = Date()) -> SessionState {
        SessionState(sessionId: id, phase: .running, updatedAt: updatedAt)
    }
}

private actor ControlledSessionStore: SessionStateStoring {
    private let suspendRemoval: Bool
    private var loadContinuations: [CheckedContinuation<[SessionState], Error>] = []
    private var removalContinuation: CheckedContinuation<Void, Error>?
    private(set) var loadCallCount = 0
    private(set) var removeCallCount = 0

    init(suspendRemoval: Bool = false) {
        self.suspendRemoval = suspendRemoval
    }

    func loadAll(now: Date, staleAfter: TimeInterval) async throws -> [SessionState] {
        loadCallCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            loadContinuations.append(continuation)
        }
    }

    func removeAll() async throws {
        removeCallCount += 1
        guard suspendRemoval else { return }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            removalContinuation = continuation
        }
    }

    func resumeLoad(with states: [SessionState]) {
        loadContinuations.removeFirst().resume(returning: states)
    }

    func resumeRemovalIfNeeded() {
        removalContinuation?.resume(returning: ())
        removalContinuation = nil
    }
}

@MainActor
private final class ControlledApprovalSender: ApprovalSending {
    private struct Call {
        let sessionId: String
        let onReceipt: @MainActor (ApprovalSendReceipt) -> Void
        let continuation: CheckedContinuation<Void, Error>
    }

    private var calls: [Call] = []

    var callCount: Int { calls.count }
    var sessionIds: [String] { calls.map(\.sessionId) }

    func sendOK(
        sessionId: String,
        onReceipt: @escaping @MainActor (ApprovalSendReceipt) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            calls.append(
                Call(
                    sessionId: sessionId,
                    onReceipt: onReceipt,
                    continuation: continuation
                )
            )
        }
    }

    func emitReceipt(forCall index: Int, sentAt: Date) {
        calls[index].onReceipt(ApprovalSendReceipt(sentAt: sentAt))
    }

    func finish(call index: Int) {
        calls[index].continuation.resume(returning: ())
    }
}

@MainActor
private func spinMainActor(iterations: Int = 10) async {
    for _ in 0..<iterations {
        await Task.yield()
    }
}

@MainActor
private func waitUntil(
    _ condition: @escaping @MainActor () async -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    for _ in 0..<1_000 {
        if await condition() { return }
        await Task.yield()
    }
    XCTFail("Condition was not met", file: file, line: line)
}

@MainActor
final class CodexProcessMonitorTests: XCTestCase {
    func testOnlyExactCodexBundleStateDrivesChanges() {
        let center = NotificationCenter()
        var running = false
        let monitor = CodexProcessMonitor(
            notificationCenter: center,
            isCodexRunning: { running },
            bundleIdentifierFromNotification: {
                $0.userInfo?["bundleIdentifier"] as? String
            }
        )
        var values: [Bool] = []
        monitor.onChange = { values.append($0) }

        monitor.start()
        center.post(
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            userInfo: ["bundleIdentifier": "com.example.other"]
        )
        running = true
        center.post(
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            userInfo: ["bundleIdentifier": "com.openai.codex"]
        )
        monitor.stop()
        running = false
        center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        XCTAssertEqual(values, [false, true])
        XCTAssertEqual(CodexProcessMonitor.codexBundleIdentifier, "com.openai.codex")
    }

    func testStartIsIdempotent() {
        let center = NotificationCenter()
        let monitor = CodexProcessMonitor(
            notificationCenter: center,
            isCodexRunning: { false }
        )
        var values: [Bool] = []
        monitor.onChange = { values.append($0) }

        monitor.start()
        monitor.start()

        XCTAssertEqual(values, [false])
        monitor.stop()
    }
}

@MainActor
final class SessionDirectoryMonitorTests: XCTestCase {
    func testStartAndDirectoryWriteNotifyWithDebounce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let monitor = SessionDirectoryMonitor(directory: directory, debounceInterval: 0.01)
        let initial = expectation(description: "initial state")
        let changed = expectation(description: "directory changed")
        var callbackCount = 0
        monitor.onChange = {
            callbackCount += 1
            if callbackCount == 1 { initial.fulfill() }
            if callbackCount == 2 { changed.fulfill() }
        }

        try monitor.start()
        await fulfillment(of: [initial], timeout: 1)
        try Data("{}".utf8).write(to: directory.appendingPathComponent("s1.json"))
        await fulfillment(of: [changed], timeout: 1)
        monitor.stop()

        XCTAssertEqual(callbackCount, 2)
        try? FileManager.default.removeItem(at: directory)
    }

    func testStartIsIdempotent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let monitor = SessionDirectoryMonitor(directory: directory)
        var callbackCount = 0
        monitor.onChange = { callbackCount += 1 }

        try monitor.start()
        try monitor.start()

        XCTAssertEqual(callbackCount, 1)
        monitor.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
final class AppDelegateConfigurationTests: XCTestCase {
    func testTerminationWaitsForInFlightStartThenStopsBeforeReplying() async {
        let appServer = ControlledAppServer()
        var replies: [Bool] = []
        let delegate = AppDelegate(
            appServer: appServer,
            codexBinaryProvider: { URL(fileURLWithPath: "/tmp/codex") },
            terminationReply: { replies.append($0) }
        )
        delegate.beginAppServerStart()
        await waitUntil { await appServer.startCount == 1 }

        let termination = delegate.applicationShouldTerminate(NSApplication.shared)
        await spinMainActor()

        XCTAssertEqual(termination, NSApplication.TerminateReply.terminateLater)
        XCTAssertTrue(delegate.isShuttingDown)
        XCTAssertTrue(replies.isEmpty)
        let earlyStopCount = await appServer.stopCount
        XCTAssertEqual(earlyStopCount, 1)

        await appServer.resumeStart()
        await waitUntil { !replies.isEmpty }

        XCTAssertEqual(replies, [true])
        let events = await appServer.events
        XCTAssertEqual(events, ["start", "stop", "start-finished", "stop"])
        XCTAssertFalse(delegate.isAppServerStarted)
    }

    func testTerminationPhaseRetainsLifecycleOwnerUntilStopReplies() async {
        let appServer = ControlledAppServer()
        var replies: [Bool] = []
        var delegate: AppDelegate? = AppDelegate(
            appServer: appServer,
            codexBinaryProvider: { URL(fileURLWithPath: "/tmp/codex") },
            terminationReply: { replies.append($0) }
        )
        delegate?.beginAppServerStart()
        await waitUntil { await appServer.startCount == 1 }

        _ = delegate?.applicationShouldTerminate(NSApplication.shared)
        delegate = nil

        await appServer.resumeStart()
        await waitUntil { !replies.isEmpty }
        XCTAssertEqual(replies, [true])
        let stopCount = await appServer.stopCount
        XCTAssertEqual(stopCount, 2)
    }

    func testQuotaRefreshUsesFiveMinuteInterval() {
        XCTAssertEqual(AppDelegate.quotaRefreshInterval, 300)
    }

    func testReconnectBackoffCapsAtFiveMinutes() {
        XCTAssertEqual(AppDelegate.reconnectDelay(forAttempt: 0), 1)
        XCTAssertEqual(AppDelegate.reconnectDelay(forAttempt: 1), 2)
        XCTAssertEqual(AppDelegate.reconnectDelay(forAttempt: 8), 256)
        XCTAssertEqual(AppDelegate.reconnectDelay(forAttempt: 9), 300)
        XCTAssertEqual(AppDelegate.reconnectDelay(forAttempt: 40), 300)
    }

    func testCodexBinaryMustBeExecutableInsideExactAppBundle() throws {
        let appURL = URL(fileURLWithPath: "/Applications/Codex.app")

        let binary = try AppDelegate.codexBinaryURL(
            appURL: appURL,
            isExecutable: { $0 == "/Applications/Codex.app/Contents/Resources/codex" }
        )

        XCTAssertEqual(binary.path, "/Applications/Codex.app/Contents/Resources/codex")
        XCTAssertThrowsError(
            try AppDelegate.codexBinaryURL(appURL: appURL, isExecutable: { _ in false })
        )
        XCTAssertEqual(AppDelegate.codexBundleIdentifier, "com.openai.codex")
    }
}

private actor ControlledAppServer: CodexAppServerServing {
    enum TestError: Error {
        case unavailable
    }

    private var startContinuation: CheckedContinuation<Void, Never>?
    private(set) var events: [String] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(codexBinary: URL) async throws {
        startCount += 1
        events.append("start")
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
        events.append("start-finished")
    }

    func readRateLimits() async throws -> RateLimitsReadResult {
        throw TestError.unavailable
    }

    func readThreadMetadata(
        sessionId: String
    ) async throws -> CodexAppServerClient.ThreadMetadata {
        throw TestError.unavailable
    }

    func setRateLimitUpdateHandler(
        _ handler: @escaping @Sendable () -> Void
    ) async throws {}

    func stop() async {
        stopCount += 1
        events.append("stop")
    }

    func resumeStart() {
        startContinuation?.resume()
        startContinuation = nil
    }
}
