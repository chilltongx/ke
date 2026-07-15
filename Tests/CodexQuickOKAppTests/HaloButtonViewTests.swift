import CodexQuickOKCore
import XCTest
@testable import CodexQuickOKApp

@MainActor
final class HaloButtonViewTests: XCTestCase {
    func testHighQuotaSuccessUsesInvertedSealDrawingState() throws {
        let rateLimits = try JSONDecoder().decode(
            RateLimitsReadResult.self,
            from: Data("""
            {
              "rateLimits": {
                "primary": {
                  "usedPercent": 33,
                  "windowDurationMins": 10080,
                  "resetsAt": 1800000000
                }
              }
            }
            """.utf8)
        )
        let button = HaloButtonView(
            frame: NSRect(x: 0, y: 0, width: 64, height: 64)
        )
        button.setQuota(QuotaSelector.weeklyQuota(from: rateLimits))

        XCTAssertEqual(
            button.drawingState,
            HaloDrawingState(
                sealFill: .coal,
                glyph: .chalk,
                halo: .mint
            )
        )

        button.showSuccessFeedback()

        XCTAssertEqual(
            button.drawingState,
            HaloDrawingState(
                sealFill: .mint,
                glyph: .coal,
                halo: .chalk
            )
        )
    }
}
