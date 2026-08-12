import CodexQuickOKCore
import XCTest
@testable import CodexQuickOKApp

@MainActor
final class HaloButtonViewTests: XCTestCase {
    func testExposesButtonSemanticsAndAccessibilityPress() {
        let button = HaloButtonView(
            frame: NSRect(x: 0, y: 0, width: 64, height: 64)
        )
        var activations = 0
        button.onActivate = { activations += 1 }

        XCTAssertTrue(button.isAccessibilityElement())
        XCTAssertEqual(button.accessibilityRole(), .button)
        XCTAssertEqual(button.accessibilityLabel(), "发送可")
        XCTAssertTrue(button.accessibilityHelp()?.contains("空白聊天输入框") == true)
        XCTAssertTrue(button.isAccessibilityEnabled())
        XCTAssertTrue(button.accessibilityPerformPress())
        XCTAssertEqual(activations, 1)

        button.isActivationEnabled = false
        XCTAssertFalse(button.isAccessibilityEnabled())
        XCTAssertEqual(button.accessibilityValue() as? String, "暂不可用")
        XCTAssertFalse(button.accessibilityPerformPress())
        XCTAssertEqual(activations, 1)
    }

    func testSendingStateIsExposedAccessibly() {
        let button = HaloButtonView(
            frame: NSRect(x: 0, y: 0, width: 64, height: 64)
        )

        button.setSending(true)
        XCTAssertFalse(button.isAccessibilityEnabled())
        XCTAssertEqual(button.accessibilityValue() as? String, "正在发送可")

        button.setSending(false)
        XCTAssertTrue(button.isAccessibilityEnabled())
        XCTAssertEqual(button.accessibilityValue() as? String, "周额度暂不可用")
    }

    func testPointerDownRespondsImmediatelyWithoutMotion() throws {
        let button = HaloButtonView(
            frame: NSRect(x: 0, y: 0, width: 64, height: 64)
        )
        button.reduceMotion = { true }
        let window = NSWindow(
            contentRect: button.bounds,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = button
        let down = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: NSPoint(x: 32, y: 32),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            )
        )

        button.mouseDown(with: down)

        XCTAssertTrue(button.isPointerDown)
        XCTAssertEqual(button.layer?.opacity, 0.72)
    }

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

    func testTerminalGlowReusesCurrentQuotaArcAndColor() throws {
        let rateLimits = try JSONDecoder().decode(
            RateLimitsReadResult.self,
            from: Data("""
            {
              "rateLimits": {
                "primary": {
                  "usedPercent": 63,
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
        button.layoutSubtreeIfNeeded()

        button.showTerminalFlash(.completed)
        let completedColor = button.terminalFlashLayer.shadowColor
        XCTAssertEqual(button.terminalFlashFraction, 0.37, accuracy: 0.001)
        XCTAssertEqual(button.terminalFlashLayer.lineWidth, 4)
        XCTAssertEqual(button.terminalFlashLayer.lineCap, .round)
        XCTAssertEqual(button.terminalFlashLayer.strokeColor, completedColor)
        XCTAssertNil(button.terminalFlashLayer.shadowPath)

        button.hideTerminalFlash()
        button.showTerminalFlash(.interrupted)
        XCTAssertEqual(button.terminalFlashLayer.shadowColor, completedColor)
    }

    func testTerminalGlowRendersPixelsFromQuotaArcShadow() throws {
        let button = HaloButtonView(
            frame: NSRect(x: 0, y: 0, width: 64, height: 64)
        )
        button.layoutSubtreeIfNeeded()
        button.showTerminalFlash(.completed)
        button.terminalFlashLayer.shadowOpacity = 0
        let withoutGlow = renderedAlphaSum(of: button.terminalFlashLayer)

        button.terminalFlashLayer.shadowOpacity = 0.24
        let withGlow = renderedAlphaSum(of: button.terminalFlashLayer)

        XCTAssertGreaterThan(withoutGlow, 0)
        XCTAssertGreaterThan(withGlow, withoutGlow)
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
        XCTAssertEqual(button.accessibilityValue() as? String, "发送失败")
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

    func testAttentionAddsCyanFireflyGlowAndAccessibleReminder() {
        let button = HaloButtonView(
            frame: NSRect(x: 0, y: 0, width: 64, height: 64)
        )

        button.setAttentionRequired(true)

        XCTAssertTrue(button.attentionRequired)
        XCTAssertEqual(
            button.attentionHaloLayer.opacity,
            FireflyAttentionStyle.haloOpacity
        )
        XCTAssertEqual(
            button.attentionFireflyLayer.opacity,
            FireflyAttentionStyle.fireflyOpacity
        )
        XCTAssertEqual(button.attentionFireflyLayer.strokeStart, 0.08)
        XCTAssertEqual(button.attentionFireflyLayer.strokeEnd, 0.15)
        XCTAssertTrue(
            button.attentionHaloLayer.strokeColor
                == FireflyAttentionStyle.cyan.cgColor
        )
        XCTAssertEqual(button.accessibilityValue() as? String, "Codex 等待你的确认")
        XCTAssertTrue(button.toolTip?.contains("Codex 等待你的确认") == true)

        button.setAttentionRequired(false)
        XCTAssertEqual(button.attentionHaloLayer.opacity, 0)
        XCTAssertEqual(button.attentionFireflyLayer.opacity, 0)
    }

    func testSendingTemporarilySuppressesWaitingGlow() {
        let button = HaloButtonView(
            frame: NSRect(x: 0, y: 0, width: 64, height: 64)
        )
        button.setAttentionRequired(true)

        button.setSending(true)
        XCTAssertEqual(button.attentionHaloLayer.opacity, 0)
        XCTAssertEqual(button.attentionFireflyLayer.opacity, 0)

        button.setSending(false)
        XCTAssertEqual(
            button.attentionHaloLayer.opacity,
            FireflyAttentionStyle.haloOpacity
        )
        XCTAssertEqual(
            button.attentionFireflyLayer.opacity,
            FireflyAttentionStyle.fireflyOpacity
        )
    }

    private func renderedAlphaSum(of layer: CALayer) -> UInt64 {
        let width = 80
        let height = 80
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let pixelCount = pixels.count
        let sum = pixels.withUnsafeMutableBytes { bytes -> UInt64 in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return 0 }
            context.translateBy(x: 8, y: 8)
            layer.render(in: context)
            let buffer = bytes.bindMemory(to: UInt8.self)
            return stride(from: 3, to: pixelCount, by: 4).reduce(0) {
                $0 + UInt64(buffer[$1])
            }
        }
        return sum
    }
}
