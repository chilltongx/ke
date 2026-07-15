import Foundation

public enum QuotaSelector {
    public static func weeklyQuota(from result: RateLimitsReadResult) -> WeeklyQuota? {
        let bucket = result.rateLimitsByLimitId?["codex"] ?? result.rateLimits
        guard let bucket else { return nil }
        guard let window = [bucket.primary, bucket.secondary]
            .compactMap({ $0 }).first(where: { $0.windowDurationMins == 10_080 }),
              let resetsAt = window.resetsAt else { return nil }
        return WeeklyQuota(
            remainingPercent: min(100, max(0, 100 - window.usedPercent)),
            resetsAt: Date(timeIntervalSince1970: resetsAt)
        )
    }
}
