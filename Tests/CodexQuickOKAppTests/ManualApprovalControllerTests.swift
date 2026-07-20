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
