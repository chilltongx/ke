import CodexQuickOKCore
import Foundation

protocol SessionStateStoring: Sendable {
    func loadAll(now: Date, staleAfter: TimeInterval) async throws -> [SessionState]
    func removeAll() async throws
}

extension SessionStateStore: SessionStateStoring {}

@MainActor
final class AppController {
    private struct ActiveAttempt {
        let id: UInt64
        let sessionId: String
        let baselineUpdatedAt: Date
        var sendTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?
    }

    private struct PendingConfirmation {
        let attemptId: UInt64
        let sessionId: String
        let minimumUpdatedAt: Date
        let deadline: Date
    }

    private let store: any SessionStateStoring
    private let panel: any CompanionPanel
    private let sender: any ApprovalSending
    private let confirmationTimeout: TimeInterval
    private var codexRunning = false
    private var stateGeneration: UInt64 = 0
    private var processLoadTask: Task<Void, Never>?
    private var attemptGeneration: UInt64 = 0
    private var activeAttempt: ActiveAttempt?
    private var pendingConfirmation: PendingConfirmation?
    private var currentStates: [SessionState] = []
    private var currentSnapshot = CompanionSnapshot(mode: .hidden, targetSessionId: nil)
    private var temporarilyHiddenSnapshot: CompanionSnapshot?

    private(set) var targetSessionId: String?

    init(
        store: any SessionStateStoring,
        panel: any CompanionPanel,
        sender: any ApprovalSending,
        confirmationTimeout: TimeInterval = 2
    ) {
        self.store = store
        self.panel = panel
        self.sender = sender
        self.confirmationTimeout = confirmationTimeout

        panel.onActivate = { [weak self] in
            self?.beginActivation()
        }
        panel.onTemporaryHide = { [weak self] in
            guard let self else { return }
            self.temporarilyHiddenSnapshot = self.currentSnapshot
            self.panel.hide()
        }
    }

    func apply(states: [SessionState], codexRunning: Bool) {
        stateGeneration &+= 1
        processLoadTask?.cancel()
        processLoadTask = nil
        self.codexRunning = codexRunning
        applySnapshot(states: states, codexRunning: codexRunning)
    }

    func processStateChanged(_ running: Bool) {
        stateGeneration &+= 1
        let generation = stateGeneration
        processLoadTask?.cancel()
        processLoadTask = nil
        codexRunning = running

        guard running else {
            applySnapshot(states: [], codexRunning: false)
            return
        }

        processLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let states = (try? await store.loadAll(now: Date(), staleAfter: 43_200)) ?? []
            guard generation == stateGeneration, codexRunning else { return }
            processLoadTask = nil
            applySnapshot(states: states, codexRunning: true)
        }
    }

    func reload() async {
        stateGeneration &+= 1
        let generation = stateGeneration
        guard codexRunning else { return }

        let states = (try? await store.loadAll(now: Date(), staleAfter: 43_200)) ?? []
        guard generation == stateGeneration, codexRunning else { return }
        applySnapshot(states: states, codexRunning: true)
    }

    func stop() {
        stateGeneration &+= 1
        processLoadTask?.cancel()
        processLoadTask = nil
        codexRunning = false
        cancelActiveAttempt()
        currentStates = []
        currentSnapshot = CompanionSnapshot(mode: .hidden, targetSessionId: nil)
        temporarilyHiddenSnapshot = nil
        targetSessionId = nil
        panel.hide()
    }

    private func applySnapshot(states: [SessionState], codexRunning: Bool) {
        if !codexRunning {
            cancelActiveAttempt()
        } else if let pendingConfirmation,
                  Date() <= pendingConfirmation.deadline,
                  states.contains(where: {
                      $0.sessionId == pendingConfirmation.sessionId
                          && $0.phase == .running
                          && $0.updatedAt > pendingConfirmation.minimumUpdatedAt
                  }) {
            completeAttempt(attemptId: pendingConfirmation.attemptId)
            panel.showSuccess()
        }

        currentStates = states
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

    private func beginActivation() {
        guard activeAttempt == nil else { return }
        guard codexRunning, let targetSessionId else {
            panel.showFailure("暂无待批准会话")
            return
        }

        attemptGeneration &+= 1
        let attemptId = attemptGeneration
        let baseline = currentStates.first(where: { $0.sessionId == targetSessionId })?
            .updatedAt ?? .distantPast
        activeAttempt = ActiveAttempt(
            id: attemptId,
            sessionId: targetSessionId,
            baselineUpdatedAt: baseline
        )
        panel.setSending(true)

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await performActivation(attemptId: attemptId, sessionId: targetSessionId)
        }
        guard activeAttempt?.id == attemptId else {
            task.cancel()
            return
        }
        activeAttempt?.sendTask = task
    }

    private func performActivation(attemptId: UInt64, sessionId: String) async {
        do {
            try await sender.sendOK(sessionId: sessionId) { [weak self] receipt in
                self?.recordReceipt(receipt, attemptId: attemptId, sessionId: sessionId)
            }
            guard activeAttempt?.id == attemptId else { return }
            guard pendingConfirmation?.attemptId == attemptId else {
                failAttempt(
                    attemptId: attemptId,
                    message: "发送结果不确定，请检查 Codex"
                )
                return
            }
        } catch is CancellationError {
            return
        } catch {
            failAttempt(attemptId: attemptId, message: String(describing: error))
        }
    }

    private func recordReceipt(
        _ receipt: ApprovalSendReceipt,
        attemptId: UInt64,
        sessionId: String
    ) {
        guard var attempt = activeAttempt,
              attempt.id == attemptId,
              attempt.sessionId == sessionId,
              pendingConfirmation?.attemptId != attemptId else { return }

        let deadline = receipt.sentAt.addingTimeInterval(confirmationTimeout)
        pendingConfirmation = PendingConfirmation(
            attemptId: attemptId,
            sessionId: sessionId,
            minimumUpdatedAt: max(attempt.baselineUpdatedAt, receipt.sentAt),
            deadline: deadline
        )
        attempt.timeoutTask = Task { @MainActor [weak self] in
            let delay = max(0, deadline.timeIntervalSinceNow)
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.confirmationTimedOut(attemptId: attemptId)
        }
        activeAttempt = attempt
    }

    private func confirmationTimedOut(attemptId: UInt64) {
        guard pendingConfirmation?.attemptId == attemptId else { return }
        failAttempt(
            attemptId: attemptId,
            message: "发送结果不确定，请检查 Codex"
        )
    }

    private func failAttempt(attemptId: UInt64, message: String) {
        guard activeAttempt?.id == attemptId else { return }
        completeAttempt(attemptId: attemptId)
        panel.showFailure(message)
    }

    private func completeAttempt(attemptId: UInt64) {
        guard let attempt = activeAttempt, attempt.id == attemptId else { return }
        attempt.sendTask?.cancel()
        attempt.timeoutTask?.cancel()
        activeAttempt = nil
        if pendingConfirmation?.attemptId == attemptId {
            pendingConfirmation = nil
        }
        panel.setSending(false)
    }

    private func cancelActiveAttempt() {
        guard let attempt = activeAttempt else {
            pendingConfirmation = nil
            return
        }
        attempt.sendTask?.cancel()
        attempt.timeoutTask?.cancel()
        activeAttempt = nil
        if pendingConfirmation?.attemptId == attempt.id {
            pendingConfirmation = nil
        }
        panel.setSending(false)
    }
}
