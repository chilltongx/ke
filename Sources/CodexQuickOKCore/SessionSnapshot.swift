import Foundation

public enum CompanionMode: Equatable, Sendable { case hidden, running, waiting }

public struct CompanionSnapshot: Equatable, Sendable {
    public let mode: CompanionMode
    public let targetSessionId: String?

    public init(mode: CompanionMode, targetSessionId: String?) {
        self.mode = mode
        self.targetSessionId = targetSessionId
    }
}

public enum SessionSnapshotEvaluator {
    public static func evaluate(
        states: [SessionState], codexRunning: Bool, now: Date,
        staleAfter: TimeInterval = 43_200
    ) -> CompanionSnapshot {
        guard codexRunning else { return CompanionSnapshot(mode: .hidden, targetSessionId: nil) }
        let fresh = states.filter { now.timeIntervalSince($0.updatedAt) <= staleAfter }
        let waiting = fresh.filter { $0.phase == .waitingForApproval }
            .sorted { ($0.waitingSince ?? .distantPast) > ($1.waitingSince ?? .distantPast) }
        if let target = waiting.first {
            return CompanionSnapshot(mode: .waiting, targetSessionId: target.sessionId)
        }
        if fresh.contains(where: { $0.phase == .running }) {
            return CompanionSnapshot(mode: .running, targetSessionId: nil)
        }
        return CompanionSnapshot(mode: .hidden, targetSessionId: nil)
    }
}
