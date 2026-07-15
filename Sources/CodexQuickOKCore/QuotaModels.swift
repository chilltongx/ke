import Foundation

public struct RateLimitsReadResult: Decodable, Sendable {
    public let rateLimits: RateLimitBucket?
    public let rateLimitsByLimitId: [String: RateLimitBucket]?
}

public struct RateLimitBucket: Decodable, Sendable {
    public let limitId: String?
    public let primary: RateLimitWindow?
    public let secondary: RateLimitWindow?
}

public struct RateLimitWindow: Decodable, Sendable {
    public let usedPercent: Double
    public let windowDurationMins: Int?
    public let resetsAt: TimeInterval?
}

public struct WeeklyQuota: Equatable, Sendable {
    public let remainingPercent: Double
    public let resetsAt: Date
}
