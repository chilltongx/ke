import CodexQuickOKCore
import Foundation

@MainActor
final class AppController {
    private let store: SessionStateStore
    private let panel: any CompanionPanel
    private let sender: any ApprovalSending
    private let confirmationTimeout: TimeInterval
    private var codexRunning = false
    private var pendingConfirmation: (sessionId: String, deadline: Date)?
    private var currentSnapshot = CompanionSnapshot(mode: .hidden, targetSessionId: nil)
    private var temporarilyHiddenSnapshot: CompanionSnapshot?
    private var activationTask: Task<Void, Never>?

    private(set) var targetSessionId: String?

    init(
        store: SessionStateStore,
        panel: any CompanionPanel,
        sender: any ApprovalSending,
        confirmationTimeout: TimeInterval = 2
    ) {
        self.store = store
        self.panel = panel
        self.sender = sender
        self.confirmationTimeout = confirmationTimeout

        panel.onActivate = { [weak self] in
            guard let self, self.activationTask == nil else { return }
            self.activationTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.activate()
                self.activationTask = nil
            }
        }
        panel.onTemporaryHide = { [weak self] in
            guard let self else { return }
            self.temporarilyHiddenSnapshot = self.currentSnapshot
            self.panel.hide()
        }
    }

    func apply(states: [SessionState], codexRunning: Bool) {
        self.codexRunning = codexRunning

        if !codexRunning {
            cancelPendingSend()
        } else if let pendingConfirmation,
                  Date() <= pendingConfirmation.deadline,
                  states.contains(where: {
                      $0.sessionId == pendingConfirmation.sessionId && $0.phase == .running
                  }) {
            self.pendingConfirmation = nil
            panel.showSuccess()
            activationTask?.cancel()
        }

        let snapshot = SessionSnapshotEvaluator.evaluate(
            states: states,
            codexRunning: codexRunning,
            now: Date()
        )
        currentSnapshot = snapshot
        targetSessionId = snapshot.targetSessionId

        if temporarilyHiddenSnapshot == snapshot {
            panel.hide()
            return
        }
        temporarilyHiddenSnapshot = nil
        panel.show(mode: snapshot.mode)
    }

    func updateCodexRunning(_ running: Bool) async {
        codexRunning = running
        if running {
            await reload()
        } else {
            try? await store.removeAll()
            apply(states: [], codexRunning: false)
        }
    }

    func reload() async {
        let states = (try? await store.loadAll(now: Date(), staleAfter: 43_200)) ?? []
        apply(states: states, codexRunning: codexRunning)
    }

    func stop() {
        cancelPendingSend()
        codexRunning = false
        currentSnapshot = CompanionSnapshot(mode: .hidden, targetSessionId: nil)
        temporarilyHiddenSnapshot = nil
        targetSessionId = nil
        panel.hide()
    }

    private func activate() async {
        guard codexRunning, let targetSessionId else {
            panel.showFailure("暂无待批准会话")
            return
        }

        panel.setSending(true)
        defer { panel.setSending(false) }

        do {
            try await sender.sendOK(sessionId: targetSessionId)
            try Task.checkCancellation()

            let deadline = Date().addingTimeInterval(confirmationTimeout)
            pendingConfirmation = (targetSessionId, deadline)
            try await Task.sleep(for: .seconds(confirmationTimeout))
            try Task.checkCancellation()

            if let pendingConfirmation,
               pendingConfirmation.sessionId == targetSessionId,
               Date() >= pendingConfirmation.deadline {
                self.pendingConfirmation = nil
                panel.showFailure("发送结果不确定，请检查 Codex")
            }
        } catch is CancellationError {
            pendingConfirmation = nil
        } catch {
            pendingConfirmation = nil
            panel.showFailure(String(describing: error))
        }
    }

    private func cancelPendingSend() {
        pendingConfirmation = nil
        activationTask?.cancel()
        activationTask = nil
    }
}
