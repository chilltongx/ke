import Foundation
import XCTest

@testable import CodexQuickOKApp

@MainActor
final class CurrentWindowApprovalSenderTests: XCTestCase {
    func testAutomationPreparesOnePidBoundFocusedConversation() async throws {
        let accessibility = FakeAccessibilityController()
        let automation = CurrentCodexAutomation(accessibility: accessibility)

        try await automation.activateCurrentWindow()

        XCTAssertEqual(accessibility.preparationTimeouts, [1.5])
    }

    func testSendsOneChineseApprovalToCurrentWindow() async throws {
        let automation = FakeCurrentCodexAutomation(
            bundleId: "com.openai.codex",
            value: ""
        )

        try await CurrentWindowApprovalSender(automation: automation).sendOK()

        XCTAssertEqual(automation.activationCount, 1)
        XCTAssertEqual(automation.revalidationCount, 2)
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

    func testActivationFailureNeverWritesOrSends() async {
        let automation = FakeCurrentCodexAutomation(
            bundleId: "com.openai.codex",
            value: ""
        )
        automation.activationError = FakeCurrentCodexAutomation.FakeError.activationFailed

        await assertRejectedWithoutWriting(automation)
    }

    func testComposerFailureNeverWritesOrSends() async {
        let automation = FakeCurrentCodexAutomation(
            bundleId: "com.openai.codex",
            value: ""
        )
        automation.composerError = FakeCurrentCodexAutomation.FakeError.composerUnavailable

        await assertRejectedWithoutWriting(automation)
    }

    func testUnreadableAXComposerNeverWritesOrSends() async {
        let automation = FakeCurrentCodexAutomation(
            bundleId: "com.openai.codex",
            value: ""
        )
        automation.composerError = AccessibilityClient.AXError.composerValueUnreadable

        await assertRejectedWithoutWriting(automation)
    }

    func testFrontmostSwitchImmediatelyBeforeComposerMutationFailsClosed() async {
        let automation = FakeCurrentCodexAutomation(
            bundleId: "com.openai.codex",
            value: ""
        )
        automation.revalidationErrors = [
            AccessibilityClient.AXError.targetApplicationChanged,
        ]

        await assertRejectedWithoutWriting(automation)
        XCTAssertEqual(automation.revalidationCount, 1)
    }

    func testFrontmostSwitchImmediatelyBeforeSendLeavesApprovalWithoutPressing() async {
        let automation = FakeCurrentCodexAutomation(
            bundleId: "com.openai.codex",
            value: ""
        )
        automation.revalidationErrors = [
            nil,
            AccessibilityClient.AXError.targetApplicationChanged,
        ]

        do {
            try await CurrentWindowApprovalSender(automation: automation).sendOK()
            XCTFail("Expected PID revalidation failure")
        } catch {}

        XCTAssertEqual(automation.writtenValues, ["可"])
        XCTAssertEqual(automation.sendAttempts, 0)
        XCTAssertEqual(automation.revalidationCount, 2)
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
private final class FakeAccessibilityController: AccessibilityControlling {
    private(set) var preparationTimeouts: [TimeInterval] = []

    func prepareFocusedConversation(timeout: TimeInterval) async throws {
        preparationTimeouts.append(timeout)
    }

    func frontmostBundleIdentifier() -> String? { "com.openai.codex" }
    func revalidateFocusedConversation() throws {}
    func composerValue() throws -> String { "" }
    func setComposerValue(_ value: String) throws {}
    func pressSend() throws {}
}

@MainActor
private final class FakeCurrentCodexAutomation: CurrentCodexAutomating {
    enum FakeError: Error {
        case activationFailed
        case composerUnavailable
        case sendUnavailable
    }

    var bundleId: String?
    var value: String
    var activationGate: (() async throws -> Void)?
    var activationError: Error?
    var composerError: Error?
    var sendError: Error?
    var revalidationErrors: [Error?] = []
    private(set) var activationCount = 0
    private(set) var revalidationCount = 0
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
        if let activationError { throw activationError }
    }

    func frontmostBundleIdentifier() -> String? { bundleId }
    func revalidateTarget() throws {
        let index = revalidationCount
        revalidationCount += 1
        if revalidationErrors.indices.contains(index), let error = revalidationErrors[index] {
            throw error
        }
    }
    func composerValue() throws -> String {
        if let composerError { throw composerError }
        return value
    }

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
