import CodexQuickOKCore
import Foundation

@MainActor
final class ManualApprovalController {
    private let panel: any CompanionPanel
    private let sender: any CurrentApprovalSending
    private var sendTask: Task<Void, Never>?
    private var attemptID: UInt64 = 0

    init(panel: any CompanionPanel, sender: any CurrentApprovalSending) {
        self.panel = panel
        self.sender = sender
        panel.onActivate = { [weak self] in self?.beginSend() }
    }

    func start() {
        show()
    }

    func show() {
        panel.show(mode: .running)
    }

    func stop() {
        attemptID &+= 1
        sendTask?.cancel()
        sendTask = nil
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
                if attemptID == currentAttempt {
                    sendTask = nil
                    panel.setSending(false)
                }
            }
            do {
                try await sender.sendOK()
                panel.showSuccess()
            } catch is CancellationError {
                return
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? "发送失败，请检查 Codex"
                panel.showFailure(message)
            }
        }
    }
}
