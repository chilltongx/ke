import CodexQuickOKCore
import XCTest
@testable import CodexQuickOKApp

@MainActor
final class FloatingPanelControllerTests: XCTestCase {
    func testReduceMotionSkipsContinuousAnimations() {
        let controller = FloatingPanelController(
            positionStore: PanelPositionStore(
                defaults: UserDefaults(suiteName: #function)!
            ),
            reduceMotion: { true }
        )

        controller.show(mode: .waiting)
        XCTAssertNil(controller.button.layer?.animation(forKey: "presence"))
        XCTAssertTrue(controller.button.attentionRequired)
        XCTAssertEqual(controller.button.attentionHaloLayer.opacity, 1)
        XCTAssertNil(controller.button.attentionHaloLayer.animation(forKey: "attention-glow"))

        controller.setSending(true)
        XCTAssertNil(controller.button.layer?.animation(forKey: "sending"))

        controller.hide()
    }

    func testWaitingModePulsesOnlyTheAttentionHalo() {
        let controller = FloatingPanelController(
            positionStore: PanelPositionStore(
                defaults: UserDefaults(suiteName: #function)!
            ),
            reduceMotion: { false }
        )

        controller.show(mode: .waiting)

        XCTAssertTrue(controller.button.attentionRequired)
        XCTAssertNotNil(
            controller.button.attentionHaloLayer.animation(forKey: "attention-glow")
        )
        XCTAssertNil(controller.button.layer?.animation(forKey: "presence"))

        controller.show(mode: .running)
        XCTAssertFalse(controller.button.attentionRequired)
        XCTAssertNil(
            controller.button.attentionHaloLayer.animation(forKey: "attention-glow")
        )
        controller.hide()
    }

    func testModeRefreshDoesNotReplaceSuccessFeedback() {
        let controller = FloatingPanelController(
            positionStore: PanelPositionStore(
                defaults: UserDefaults(suiteName: #function)!
            ),
            reduceMotion: { false }
        )

        controller.show(mode: .waiting)
        controller.showSuccess()
        controller.show(mode: .running)

        XCTAssertNotNil(controller.button.layer?.animation(forKey: "success"))
        XCTAssertNil(controller.button.layer?.animation(forKey: "presence"))

        controller.hide()
    }

    func testReduceMotionSuccessUsesStaticHaloAndAccessibilityAnnouncement() {
        let scheduler = ManualFeedbackScheduler()
        let announcer = RecordingAccessibilityAnnouncer()
        let controller = FloatingPanelController(
            positionStore: PanelPositionStore(
                defaults: UserDefaults(suiteName: #function)!
            ),
            reduceMotion: { true },
            feedbackScheduler: scheduler,
            accessibilityAnnouncer: announcer
        )

        controller.show(mode: .waiting)
        controller.showSuccess()

        XCTAssertEqual(controller.button.feedbackState, .success)
        XCTAssertNil(controller.button.layer?.animation(forKey: "success"))
        XCTAssertEqual(announcer.messages, ["已发送可"])
        XCTAssertEqual(scheduler.delay, 0.28, accuracy: 0.001)

        scheduler.fire()
        XCTAssertNil(controller.button.feedbackState)

        controller.hide()
    }

    func testFailureFeedbackRestoresMostRecentQuotaTooltip() throws {
        let scheduler = ManualFeedbackScheduler()
        let controller = FloatingPanelController(
            positionStore: PanelPositionStore(
                defaults: UserDefaults(suiteName: #function)!
            ),
            reduceMotion: { true },
            feedbackScheduler: scheduler
        )

        controller.setQuota(nil)
        let unavailableTooltip = controller.button.toolTip
        controller.showFailure("额度读取失败")
        XCTAssertEqual(controller.button.toolTip, "额度读取失败")
        XCTAssertEqual(scheduler.delay, 0.55, accuracy: 0.001)
        scheduler.fire()
        XCTAssertEqual(controller.button.toolTip, unavailableTooltip)

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
        controller.setQuota(QuotaSelector.weeklyQuota(from: rateLimits))
        let weeklyTooltip = controller.button.toolTip
        controller.showFailure("发送失败")
        XCTAssertEqual(controller.button.toolTip, "发送失败")
        scheduler.fire()
        XCTAssertEqual(controller.button.toolTip, weeklyTooltip)

        controller.hide()
    }

    func testReduceMotionFailureUsesStaticRedDrawingState() {
        let controller = FloatingPanelController(
            positionStore: PanelPositionStore(
                defaults: UserDefaults(suiteName: #function)!
            ),
            reduceMotion: { true }
        )

        controller.setQuota(nil)
        controller.showFailure("发送失败")

        XCTAssertNil(controller.button.layer?.animation(forKey: "failure"))
        XCTAssertEqual(
            controller.button.drawingState,
            HaloDrawingState(sealFill: .red, glyph: .chalk, halo: .red)
        )
        controller.hide()
    }

    func testSuccessReplacingFailureRestoresQuotaTooltipImmediately() {
        let scheduler = ManualFeedbackScheduler()
        let announcer = RecordingAccessibilityAnnouncer()
        let controller = FloatingPanelController(
            positionStore: PanelPositionStore(
                defaults: UserDefaults(suiteName: #function)!
            ),
            reduceMotion: { true },
            feedbackScheduler: scheduler,
            accessibilityAnnouncer: announcer
        )
        controller.setQuota(nil)
        let quotaTooltip = controller.button.toolTip

        controller.showFailure("发送失败")
        XCTAssertEqual(controller.button.toolTip, "发送失败")

        controller.showSuccess()

        XCTAssertEqual(controller.button.feedbackState, .success)
        XCTAssertEqual(controller.button.toolTip, quotaTooltip)
        XCTAssertEqual(scheduler.delay, 0.28, accuracy: 0.001)

        controller.hide()
    }

    func testHideMenuExplainsDockRecovery() {
        let controller = FloatingPanelController(
            positionStore: PanelPositionStore(
                defaults: UserDefaults(suiteName: #function)!
            )
        )
        XCTAssertTrue(
            controller.button.menu?.items.contains {
                $0.title == "隐藏按钮（点 Dock 恢复）"
            } == true
        )
        controller.hide()
    }
}

@MainActor
private final class ManualFeedbackScheduler: FeedbackScheduling {
    private(set) var delay: TimeInterval = 0
    private var completion: (@MainActor () -> Void)?

    func schedule(
        after delay: TimeInterval,
        completion: @escaping @MainActor () -> Void
    ) {
        self.delay = delay
        self.completion = completion
    }

    func cancel() {
        completion = nil
    }

    func fire() {
        let completion = completion
        self.completion = nil
        completion?()
    }
}

@MainActor
private final class RecordingAccessibilityAnnouncer: AccessibilityAnnouncing {
    private(set) var messages: [String] = []

    func announce(_ message: String, for element: Any) {
        messages.append(message)
    }
}
