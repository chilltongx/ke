import Foundation

public struct HookEvent: Decodable, Sendable {
    public let sessionId: String
    public let hookEventName: String
    public let cwd: String?
    public let lastAssistantMessage: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case hookEventName = "hook_event_name"
        case cwd
        case lastAssistantMessage = "last_assistant_message"
    }

    public static func decode(_ data: Data) throws -> HookEvent {
        try JSONDecoder().decode(HookEvent.self, from: data)
    }
}

public enum HookReducer {
    public static func reduce(
        event: HookEvent, previous: SessionState?, now: Date
    ) -> SessionState? {
        switch event.hookEventName {
        case "SessionStart":
            return SessionState(sessionId: event.sessionId, phase: .idle, updatedAt: now, cwd: event.cwd)
        case "UserPromptSubmit":
            return SessionState(sessionId: event.sessionId, phase: .running, updatedAt: now, cwd: event.cwd)
        case "Stop":
            let waiting = ApprovalClassifier.isApprovalRequest(event.lastAssistantMessage)
            return SessionState(
                sessionId: event.sessionId,
                phase: waiting ? .waitingForApproval : .idle,
                updatedAt: now,
                waitingSince: waiting ? now : nil,
                cwd: event.cwd ?? previous?.cwd
            )
        default:
            return nil
        }
    }
}
