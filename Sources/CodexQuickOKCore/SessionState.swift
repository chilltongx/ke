import Foundation

public enum SessionPhase: String, Codable, Equatable, Sendable {
    case running
    case waitingForApproval
    case idle
}

public struct SessionState: Codable, Equatable, Sendable, Identifiable {
    public var id: String { sessionId }
    public let sessionId: String
    public var phase: SessionPhase
    public var updatedAt: Date
    public var waitingSince: Date?
    public var cwd: String?

    enum CodingKeys: String, CodingKey {
        case sessionId
        case phase = "state"
        case updatedAt, waitingSince, cwd
    }

    public init(
        sessionId: String, phase: SessionPhase, updatedAt: Date,
        waitingSince: Date? = nil, cwd: String? = nil
    ) {
        self.sessionId = sessionId
        self.phase = phase
        self.updatedAt = updatedAt
        self.waitingSince = waitingSince
        self.cwd = cwd
    }
}
