import XCTest
@testable import CodexQuickOKCore

final class QuotaSelectorTests: XCTestCase {
    func testSelectsOnlySevenDayCodexWindow() throws {
        let data = Data("""
        {"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":80,"windowDurationMins":300,"resetsAt":1000},"secondary":{"usedPercent":25,"windowDurationMins":10080,"resetsAt":2000}}}}
        """.utf8)
        let result = try JSONDecoder().decode(RateLimitsReadResult.self, from: data)
        let quota = try XCTUnwrap(QuotaSelector.weeklyQuota(from: result))
        XCTAssertEqual(quota.remainingPercent, 75)
        XCTAssertEqual(quota.resetsAt, Date(timeIntervalSince1970: 2000))
    }

    func testReturnsNilInsteadOfFallingBackToShortWindow() throws {
        let data = Data("""
        {"rateLimits":{"limitId":"codex","primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":1000}}}
        """.utf8)
        let result = try JSONDecoder().decode(RateLimitsReadResult.self, from: data)
        XCTAssertNil(QuotaSelector.weeklyQuota(from: result))
    }
}
