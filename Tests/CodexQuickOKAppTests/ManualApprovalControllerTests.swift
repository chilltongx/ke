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

    func testAttentionUsesWaitingModeAndSuccessfulSendClearsIt() async {
        let panel = RecordingPanel()
        let sender = StubSender()
        let controller = ManualApprovalController(panel: panel, sender: sender)
        controller.start()

        controller.setAttentionRequired(true)
        XCTAssertEqual(panel.lastMode, .waiting)

        panel.onActivate?()
        await waitUntil { panel.successCount == 1 }

        XCTAssertEqual(panel.lastMode, .running)
        XCTAssertEqual(sender.callCount, 1)
    }

    func testAttentionDoesNotReshowTemporarilyHiddenPanel() {
        let panel = RecordingPanel()
        let controller = ManualApprovalController(panel: panel, sender: StubSender())
        controller.start()
        panel.hide()
        panel.onTemporaryHide?()

        controller.setAttentionRequired(true)

        XCTAssertEqual(panel.lastMode, .hidden)
        controller.show()
        XCTAssertEqual(panel.lastMode, .waiting)
    }

    func testTaskTerminalReminderWaitsWhileHiddenAndForwardsOnReopen() {
        let panel = RecordingPanel()
        let controller = ManualApprovalController(panel: panel, sender: StubSender())
        controller.start()

        controller.showTaskTerminal(.completed)
        panel.hide()
        panel.onTemporaryHide?()
        controller.showTaskTerminal(.interrupted)

        XCTAssertEqual(panel.terminalOutcomes, [.completed])
        controller.show()
        XCTAssertEqual(panel.terminalOutcomes, [.completed, .interrupted])
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
        let sender = StubSender(error: FocusedChatSendError.existingDraft)
        let controller = ManualApprovalController(panel: panel, sender: sender)
        controller.start()

        panel.onActivate?()
        await waitUntil { !panel.failures.isEmpty }

        XCTAssertEqual(sender.callCount, 1)
        XCTAssertEqual(panel.failures, ["检测到未发送草稿"])
        XCTAssertEqual(panel.sendingValues, [true, false])
    }

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
        struct PayloadError: Error {
            let message: String
        }
        let code = ManualApprovalController.diagnosticCode(
            for: PayloadError(message: "private draft text")
        )

        XCTAssertTrue(code.contains("PayloadError"))
        XCTAssertFalse(code.contains("private draft text"))
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

    func testStoppedCancellationInsensitiveSendBlocksOverlapAndSuppressesStaleFeedback() async {
        let panel = RecordingPanel()
        let sender = CancellationInsensitiveSender()
        let controller = ManualApprovalController(panel: panel, sender: sender)
        controller.start()
        panel.onActivate?()
        await waitUntil { sender.callCount == 1 }

        controller.stop()
        controller.show()
        panel.onActivate?()
        await Task.yield()

        XCTAssertEqual(sender.callCount, 1)

        sender.finish(call: 0)
        await waitUntil { sender.finishedCalls == [0] }
        await Task.yield()

        XCTAssertEqual(panel.successCount, 0)
        XCTAssertTrue(panel.failures.isEmpty)

        panel.onActivate?()
        await waitUntil { sender.callCount == 2 }
        sender.finish(call: 1)
        await waitUntil { panel.successCount == 1 }

        XCTAssertTrue(panel.failures.isEmpty)
    }
}

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
    private(set) var quotas: [WeeklyQuota?] = []
    private(set) var terminalOutcomes: [CodexTerminalOutcome] = []

    func show(mode: CompanionMode) {
        lastMode = mode
        shownModes.append(mode)
    }

    func hide() {
        lastMode = .hidden
        shownModes.append(.hidden)
    }

    func setQuota(_ quota: WeeklyQuota?) { quotas.append(quota) }
    func setSending(_ sending: Bool) { sendingValues.append(sending) }
    func showSuccess() { successCount += 1 }
    func showFailure(_ message: String) { failures.append(message) }
    func showTaskTerminal(_ outcome: CodexTerminalOutcome) {
        terminalOutcomes.append(outcome)
    }
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
final class CancellationInsensitiveSender: CurrentApprovalSending {
    private var continuations: [CheckedContinuation<Void, Never>?] = []
    private(set) var callCount = 0
    private(set) var finishedCalls: [Int] = []

    func sendOK() async throws {
        let call = callCount
        callCount += 1
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
        finishedCalls.append(call)
    }

    func finish(call: Int) {
        continuations[call]?.resume()
        continuations[call] = nil
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
