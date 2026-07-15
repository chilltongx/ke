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

        controller.setSending(true)
        XCTAssertNil(controller.button.layer?.animation(forKey: "sending"))

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
        XCTAssertEqual(announcer.messages, ["批准成功"])
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
