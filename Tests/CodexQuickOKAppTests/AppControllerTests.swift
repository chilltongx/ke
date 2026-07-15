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

    private func makeController(
        panel: FakePanel,
        sender: FakeSender = FakeSender(),
        confirmationTimeout: TimeInterval = 2
    ) -> AppController {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        return AppController(
            store: SessionStateStore(directory: directory),
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

    func show(mode: CompanionMode) { lastMode = mode }
    func hide() { lastMode = .hidden }
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

    func sendOK(sessionId: String) async throws {
        sessionIds.append(sessionId)
        if delay > 0 {
            try await Task.sleep(for: .seconds(delay))
        }
    }
}

private enum Fixtures {
    static func waiting(_ id: String) -> SessionState {
        let now = Date()
        return SessionState(
            sessionId: id,
            phase: .waitingForApproval,
            updatedAt: now,
            waitingSince: now
        )
    }

    static func running(_ id: String) -> SessionState {
        SessionState(sessionId: id, phase: .running, updatedAt: Date())
    }
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
    func testTerminationMarksLifecycleAsShuttingDown() {
        let delegate = AppDelegate()

        delegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )

        XCTAssertTrue(delegate.isShuttingDown)
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
