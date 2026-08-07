import AppKit
import CodexQuickOKCore
import Foundation
import OSLog

@MainActor
final class ManualApprovalController {
    private static let logger = Logger(
        subsystem: "com.codexquickok.CodexQuickOK",
        category: "send"
    )

    private let panel: any CompanionPanel
    private let sender: any CurrentApprovalSending
    private var sendTask: Task<Void, Never>?
    private var attemptID: UInt64 = 0
    private var attentionRequired = false
    private var isVisible = false

    init(panel: any CompanionPanel, sender: any CurrentApprovalSending) {
        self.panel = panel
        self.sender = sender
        panel.onActivate = { [weak self] in self?.beginSend() }
        panel.onTemporaryHide = { [weak self] in self?.isVisible = false }
    }

    func start() {
        show()
    }

    func show() {
        isVisible = true
        panel.show(mode: attentionRequired ? .waiting : .running)
    }

    func setAttentionRequired(_ required: Bool) {
        guard attentionRequired != required else { return }
        attentionRequired = required
        guard isVisible else { return }
        panel.show(mode: required ? .waiting : .running)
    }

    func stop() {
        attemptID &+= 1
        sendTask?.cancel()
        isVisible = false
        panel.setSending(false)
        panel.hide()
    }

    private func beginSend() {
        guard sendTask == nil else { return }
        attemptID &+= 1
        let currentAttempt = attemptID
        panel.setSending(true)
        sendTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                sendTask = nil
                if attemptID == currentAttempt {
                    panel.setSending(false)
                }
            }
            do {
                try await sender.sendOK()
                guard attemptID == currentAttempt else { return }
                setAttentionRequired(false)
                panel.showSuccess()
            } catch is CancellationError {
                return
            } catch {
                let diagnosticCode = Self.diagnosticCode(for: error)
                let bundleIdentifier = NSWorkspace.shared
                    .frontmostApplication?.bundleIdentifier ?? "none"
                Self.logger.error(
                    "Send failed: \(diagnosticCode, privacy: .public) frontmost=\(bundleIdentifier, privacy: .public)"
                )
                let message = (error as? LocalizedError)?.errorDescription
                    ?? "发送失败，请检查当前聊天框"
                guard attemptID == currentAttempt else { return }
                panel.showFailure(message)
            }
        }
    }

    static func diagnosticCode(for error: Error) -> String {
        switch error {
        case let error as AccessibilityClient.AXError:
            "accessibility.\(String(describing: error))"
        case let error as ChatTargetClassificationError:
            "classification.\(String(describing: error))"
        case let error as FocusedChatSendError:
            "send.\(String(describing: error))"
        default:
            String(reflecting: type(of: error))
        }
    }
}
