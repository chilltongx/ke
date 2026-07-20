import CodexQuickOKCore
import Foundation

@MainActor
protocol CurrentApprovalSending: AnyObject {
    func sendOK() async throws
}

enum CurrentApprovalSendError: Error, Equatable, LocalizedError {
    case inProgress

    var errorDescription: String? {
        "上一次发送仍在进行，请稍后重试"
    }
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
