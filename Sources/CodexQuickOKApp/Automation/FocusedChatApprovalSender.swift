import Foundation

@MainActor
protocol CurrentApprovalSending: AnyObject {
    func sendOK() async throws
}

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
        guard !sending else {
            throw FocusedChatSendError.inProgress
        }
        sending = true
        defer { sending = false }

        try await input.prepareTargetCapture()
        let target = try input.captureTarget()
        let match = try classifier.classify(
            bundleIdentifier: target.bundleIdentifier,
            context: target.context
        )
        let rawValue = try input.composerValue(in: target)
        let value = match.normalizedComposerValue(rawValue)
        guard value.isEmpty else {
            throw FocusedChatSendError.existingDraft
        }

        try input.revalidate(target)
        let latestRawValue = try input.composerValue(in: target)
        let latestValue = match.normalizedComposerValue(latestRawValue)
        guard latestValue.isEmpty else {
            throw FocusedChatSendError.existingDraft
        }
        try input.setComposerValue(
            "可",
            expectedCurrentValue: latestRawValue,
            in: target
        )
        try await input.waitUntilComposerValue(
            "可",
            in: target,
            timeout: 0.5
        )
        try input.revalidate(target)
        try input.pressReturn(in: target)
    }
}
