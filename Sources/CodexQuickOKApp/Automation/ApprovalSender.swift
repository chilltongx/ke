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
    func sendOK(
        sessionId: String,
        onReceipt: @escaping @MainActor (ApprovalSendReceipt) -> Void
    ) async throws
}

struct ApprovalSendReceipt: Equatable, Sendable {
    let sentAt: Date
}

extension ApprovalSending {
    func sendOK(sessionId: String) async throws {
        try await sendOK(sessionId: sessionId) { _ in }
    }
}

@MainActor
final class ApprovalSender: ApprovalSending {
    private let automation: CodexAutomating
    private let isStillTarget: (String) async -> Bool
    private let now: () -> Date
    private var sending = false

    init(
        automation: CodexAutomating,
        isStillTarget: @escaping (String) async -> Bool = { _ in true },
        now: @escaping () -> Date = Date.init
    ) {
        self.automation = automation
        self.isStillTarget = isStillTarget
        self.now = now
    }

    func sendOK(
        sessionId: String,
        onReceipt: @escaping @MainActor (ApprovalSendReceipt) -> Void
    ) async throws {
        guard !sending else {
            return
        }
        sending = true
        defer { sending = false }

        try await automation.activateAndOpen(sessionId: sessionId)
        guard await isStillTarget(sessionId) else {
            throw SendSafetyError.sessionMismatch
        }

        let sessionMatched = try await automation.currentSessionMatches(sessionId)
        let composerValue = try automation.composerValue()
        try SendSafety.validate(
            bundleId: automation.frontmostBundleIdentifier(),
            sessionMatched: sessionMatched,
            composerValue: composerValue
        )

        try automation.setComposerValue("可")
        try automation.performSend()
        onReceipt(ApprovalSendReceipt(sentAt: now()))
    }
}
