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
        XCTAssertEqual(button.accessibilityValue() as? String, "已发送可")
    }

    func testFailureReplacingSuccessInvalidatesInvertedSeal() {
        let button = HaloButtonView(
            frame: NSRect(x: 0, y: 0, width: 64, height: 64)
        )
        let window = NSWindow(
            contentRect: button.bounds,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = button
        button.setQuota(nil)
        button.showSuccessFeedback()
        XCTAssertEqual(button.feedbackState, .success)
        button.displayIfNeeded()
        button.needsDisplay = false
        XCTAssertFalse(button.needsDisplay)

        button.showFailureFeedback("发送失败")

        XCTAssertEqual(button.feedbackState, .failure)
        XCTAssertTrue(
            button.needsDisplay || button.layer?.needsDisplay() == true,
            "Layer-backed views may forward invalidation directly to their backing layer"
        )
        XCTAssertEqual(
            button.drawingState,
            HaloDrawingState(
                sealFill: .red,
                glyph: .chalk,
                halo: .red
            )
        )
    }

    func testAttentionAddsAmberHaloAndAccessibleReminder() {
        let button = HaloButtonView(
            frame: NSRect(x: 0, y: 0, width: 64, height: 64)
        )

        button.setAttentionRequired(true)

        XCTAssertTrue(button.attentionRequired)
        XCTAssertEqual(button.attentionHaloLayer.opacity, 1)
        XCTAssertEqual(button.accessibilityValue() as? String, "Codex 等待你的确认")
        XCTAssertTrue(button.toolTip?.contains("Codex 等待你的确认") == true)

        button.setAttentionRequired(false)
        XCTAssertEqual(button.attentionHaloLayer.opacity, 0)
    }
}
