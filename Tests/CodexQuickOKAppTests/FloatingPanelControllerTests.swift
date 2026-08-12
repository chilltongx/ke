import AppKit
import CodexQuickOKCore
import XCTest
@testable import CodexQuickOKApp

@MainActor
final class FloatingPanelControllerTests: XCTestCase {
    func testPanelCanvasPreservesGlowPixelsOutsideSixtyFourPointButton() throws {
        let controller = FloatingPanelController(
            positionStore: PanelPositionStore(
                defaults: UserDefaults(suiteName: #function)!
            ),
            reduceMotion: { true }
        )
        controller.show(mode: .running)
        defer { controller.hide() }

        let contentView = try XCTUnwrap(controller.button.window?.contentView)
        contentView.layoutSubtreeIfNeeded()
        XCTAssertEqual(contentView.bounds.size, NSSize(width: 76, height: 76))
        XCTAssertEqual(
            controller.button.frame,
            NSRect(x: 6, y: 6, width: 64, height: 64)
        )
        XCTAssertEqual(controller.button.terminalFlashLayer.lineWidth, 4)
        XCTAssertEqual(
            controller.button.terminalFlashLayer.path?.boundingBoxOfPath,
            NSRect(x: 3, y: 3, width: 58, height: 58)
        )
        XCTAssertTrue(
            contentView.hitTest(NSPoint(x: 38, y: 38)) === controller.button
        )
        XCTAssertNil(contentView.hitTest(NSPoint(x: 2, y: 38)))

        controller.showTaskTerminal(.completed)
        controller.button.terminalFlashLayer.shadowOpacity = 0
        let withoutGlow = try snapshot(of: contentView)
        let withoutGlowMarginAlpha = alphaSum(
            in: withoutGlow,
            outside: controller.button.frame,
            viewBounds: contentView.bounds
        )

        controller.button.terminalFlashLayer.shadowOpacity = 0.24
        let withGlow = try snapshot(of: contentView)
        let withGlowMarginAlpha = alphaSum(
            in: withGlow,
            outside: controller.button.frame,
            viewBounds: contentView.bounds
        )

        XCTAssertGreaterThan(withGlowMarginAlpha, withoutGlowMarginAlpha)
        XCTAssertEqual(perimeterAlphaSum(in: withGlow), 0, accuracy: 0.001)
    }

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
        XCTAssertEqual(
            controller.button.attentionHaloLayer.opacity,
            FireflyAttentionStyle.haloOpacity
        )
        XCTAssertEqual(
            controller.button.attentionFireflyLayer.opacity,
            FireflyAttentionStyle.fireflyOpacity
        )
        XCTAssertNil(controller.button.attentionHaloLayer.animation(forKey: "attention-glow"))
        XCTAssertNil(
            controller.button.attentionFireflyLayer.animation(
                forKey: "attention-firefly"
            )
        )
        XCTAssertNil(
            controller.button.attentionFireflyLayer.animation(
                forKey: "attention-firefly-drift"
            )
        )

        controller.setSending(true)
        XCTAssertNil(controller.button.layer?.animation(forKey: "sending"))

        controller.hide()
    }

    func testWaitingModeUsesIrregularFireflyGlowOnly() throws {
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
        let flicker = try XCTUnwrap(
            controller.button.attentionFireflyLayer.animation(
                forKey: "attention-firefly"
            ) as? CAKeyframeAnimation
        )
        XCTAssertEqual(flicker.duration, 7.7, accuracy: 0.001)
        XCTAssertEqual(flicker.repeatCount, .infinity)
        XCTAssertEqual(flicker.values?.count, 8)
        XCTAssertNotNil(
            controller.button.attentionFireflyLayer.animation(
                forKey: "attention-firefly-drift"
            )
        )
        XCTAssertNil(controller.button.layer?.animation(forKey: "presence"))

        controller.show(mode: .running)
        XCTAssertFalse(controller.button.attentionRequired)
        XCTAssertNil(
            controller.button.attentionHaloLayer.animation(forKey: "attention-glow")
        )
        XCTAssertNil(
            controller.button.attentionFireflyLayer.animation(
                forKey: "attention-firefly"
            )
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
        XCTAssertEqual(scheduler.delay, 4, accuracy: 0.001)
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

    func testFailureIsAnnouncedAndRemainsActiveForFourSeconds() {
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

        controller.show(mode: .running)
        controller.showFailure("发送失败，请检查当前聊天框")

        XCTAssertEqual(announcer.messages, ["发送失败，请检查当前聊天框"])
        XCTAssertEqual(scheduler.delay, 4, accuracy: 0.001)
        XCTAssertEqual(controller.button.feedbackState, .failure)

        scheduler.fire()
        XCTAssertNil(controller.button.feedbackState)
        controller.hide()
    }

    func testFailureTemporarilySuppressesWaitingGlowAndRestoresIt() {
        let scheduler = ManualFeedbackScheduler()
        let controller = FloatingPanelController(
            positionStore: PanelPositionStore(
                defaults: UserDefaults(suiteName: #function)!
            ),
            reduceMotion: { false },
            feedbackScheduler: scheduler
        )

        controller.show(mode: .waiting)
        controller.showFailure("发送失败")

        XCTAssertEqual(controller.button.attentionHaloLayer.opacity, 0)
        XCTAssertEqual(controller.button.attentionFireflyLayer.opacity, 0)
        XCTAssertNil(
            controller.button.attentionHaloLayer.animation(forKey: "attention-glow")
        )
        XCTAssertNil(
            controller.button.attentionFireflyLayer.animation(
                forKey: "attention-firefly"
            )
        )

        scheduler.fire()

        XCTAssertEqual(
            controller.button.attentionHaloLayer.opacity,
            FireflyAttentionStyle.haloOpacity
        )
        XCTAssertEqual(
            controller.button.attentionFireflyLayer.opacity,
            FireflyAttentionStyle.fireflyOpacity
        )
        XCTAssertNotNil(
            controller.button.attentionHaloLayer.animation(forKey: "attention-glow")
        )
        XCTAssertNotNil(
            controller.button.attentionFireflyLayer.animation(
                forKey: "attention-firefly"
            )
        )
        XCTAssertNotNil(
            controller.button.attentionFireflyLayer.animation(
                forKey: "attention-firefly-drift"
            )
        )
        controller.hide()
    }

    func testTaskTerminalFlashesThreeTimesAndRestoresWaitingGlow() throws {
        let scheduler = ManualFeedbackScheduler()
        let announcer = RecordingAccessibilityAnnouncer()
        let controller = FloatingPanelController(
            positionStore: PanelPositionStore(
                defaults: UserDefaults(suiteName: #function)!
            ),
            reduceMotion: { false },
            feedbackScheduler: scheduler,
            accessibilityAnnouncer: announcer
        )

        controller.show(mode: .waiting)
        controller.showTaskTerminal(.completed)

        let animation = try XCTUnwrap(
            controller.button.terminalFlashLayer.animation(
                forKey: "task-terminal"
            ) as? CAKeyframeAnimation
        )
        XCTAssertEqual(
            animation.values?.compactMap { ($0 as? NSNumber)?.doubleValue },
            [0, 0.24, 0.02, 0.24, 0.02, 0.24, 0]
        )
        XCTAssertEqual(animation.keyPath, "shadowOpacity")
        XCTAssertEqual(animation.duration, 1.6, accuracy: 0.001)
        XCTAssertEqual(animation.repeatCount, 0)
        XCTAssertEqual(controller.button.attentionHaloLayer.opacity, 0)
        XCTAssertEqual(announcer.messages, ["任务已完成"])

        scheduler.fire()

        XCTAssertNil(
            controller.button.terminalFlashLayer.animation(
                forKey: "task-terminal"
            )
        )
        XCTAssertEqual(controller.button.terminalFlashLayer.opacity, 0)
        XCTAssertEqual(controller.button.terminalFlashLayer.shadowOpacity, 0)
        XCTAssertNil(controller.button.terminalFlashOutcome)
        XCTAssertEqual(
            controller.button.attentionHaloLayer.opacity,
            FireflyAttentionStyle.haloOpacity
        )
        XCTAssertNotNil(
            controller.button.attentionHaloLayer.animation(forKey: "attention-glow")
        )
        controller.hide()
    }

    func testReduceMotionUsesStaticTerminalRingAndQueuesNextReminder() {
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

        controller.show(mode: .running)
        controller.showTaskTerminal(.completed)
        controller.showTaskTerminal(.interrupted)

        XCTAssertNil(
            controller.button.terminalFlashLayer.animation(
                forKey: "task-terminal"
            )
        )
        XCTAssertEqual(controller.button.terminalFlashLayer.opacity, 1)
        XCTAssertEqual(controller.button.terminalFlashLayer.shadowOpacity, 0.16)
        XCTAssertEqual(controller.button.terminalFlashOutcome, .completed)
        XCTAssertEqual(announcer.messages, ["任务已完成"])

        scheduler.fire()

        XCTAssertEqual(controller.button.terminalFlashOutcome, .interrupted)
        XCTAssertEqual(controller.button.terminalFlashLayer.opacity, 1)
        XCTAssertEqual(controller.button.terminalFlashLayer.shadowOpacity, 0.16)
        XCTAssertEqual(announcer.messages, ["任务已完成", "任务已终止"])

        scheduler.fire()
        XCTAssertNil(controller.button.terminalFlashOutcome)
        XCTAssertEqual(controller.button.terminalFlashLayer.opacity, 0)
        XCTAssertEqual(controller.button.terminalFlashLayer.shadowOpacity, 0)
        controller.hide()
    }

    func testSendingCancelsActiveTerminalReminderWithoutReplayingIt() {
        let scheduler = ManualFeedbackScheduler()
        let announcer = RecordingAccessibilityAnnouncer()
        let controller = FloatingPanelController(
            positionStore: PanelPositionStore(
                defaults: UserDefaults(suiteName: #function)!
            ),
            reduceMotion: { false },
            feedbackScheduler: scheduler,
            accessibilityAnnouncer: announcer
        )

        controller.show(mode: .running)
        controller.showTaskTerminal(.completed)
        XCTAssertNotNil(
            controller.button.terminalFlashLayer.animation(
                forKey: "task-terminal"
            )
        )
        controller.setSending(true)

        XCTAssertNil(controller.button.terminalFlashOutcome)
        XCTAssertEqual(controller.button.terminalFlashLayer.opacity, 0)
        XCTAssertNil(
            controller.button.terminalFlashLayer.animation(
                forKey: "task-terminal"
            )
        )

        controller.setSending(false)

        XCTAssertNil(controller.button.terminalFlashOutcome)
        XCTAssertEqual(announcer.messages, ["任务已完成"])

        scheduler.fireCancelled()
        XCTAssertNil(controller.button.terminalFlashOutcome)
        XCTAssertEqual(controller.button.terminalFlashLayer.opacity, 0)
        XCTAssertEqual(announcer.messages, ["任务已完成"])
        controller.hide()
    }

    func testHideCancelsTerminalReminderAndStaleCompletionCannotRestoreIt() {
        let scheduler = ManualFeedbackScheduler()
        let announcer = RecordingAccessibilityAnnouncer()
        let controller = FloatingPanelController(
            positionStore: PanelPositionStore(
                defaults: UserDefaults(suiteName: #function)!
            ),
            reduceMotion: { false },
            feedbackScheduler: scheduler,
            accessibilityAnnouncer: announcer
        )

        controller.show(mode: .waiting)
        controller.showTaskTerminal(.completed)
        controller.hide()
        scheduler.fireCancelled()
        controller.show(mode: .running)

        XCTAssertNil(controller.button.terminalFlashOutcome)
        XCTAssertEqual(controller.button.terminalFlashLayer.opacity, 0)
        XCTAssertNil(
            controller.button.terminalFlashLayer.animation(
                forKey: "task-terminal"
            )
        )
        XCTAssertEqual(announcer.messages, ["任务已完成"])
        controller.hide()
    }

    func testSendFeedbackCancelsActiveTerminalWithoutReplayingIt() {
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

        controller.show(mode: .running)
        controller.showTaskTerminal(.completed)
        controller.showSuccess()

        XCTAssertNil(controller.button.terminalFlashOutcome)
        XCTAssertEqual(controller.button.feedbackState, .success)
        XCTAssertEqual(announcer.messages, ["任务已完成", "已发送可"])
        scheduler.fireCancelled()
        XCTAssertEqual(controller.button.feedbackState, .success)
        scheduler.fire()
        XCTAssertNil(controller.button.feedbackState)

        controller.showTaskTerminal(.interrupted)
        controller.showFailure("发送失败")

        XCTAssertNil(controller.button.terminalFlashOutcome)
        XCTAssertEqual(controller.button.feedbackState, .failure)
        XCTAssertEqual(
            announcer.messages,
            ["任务已完成", "已发送可", "任务已终止", "发送失败"]
        )
        scheduler.fireCancelled()
        XCTAssertEqual(controller.button.feedbackState, .failure)
        scheduler.fire()
        XCTAssertNil(controller.button.feedbackState)
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

    private func snapshot(of view: NSView) throws -> NSBitmapImageRep {
        let representation = try XCTUnwrap(
            view.bitmapImageRepForCachingDisplay(in: view.bounds)
        )
        view.cacheDisplay(in: view.bounds, to: representation)
        return representation
    }

    private func alphaSum(
        in representation: NSBitmapImageRep,
        outside excludedFrame: NSRect,
        viewBounds: NSRect
    ) -> Double {
        var result = 0.0
        for y in 0..<representation.pixelsHigh {
            for x in 0..<representation.pixelsWide {
                let point = NSPoint(
                    x: viewBounds.minX
                        + (CGFloat(x) + 0.5) * viewBounds.width
                        / CGFloat(representation.pixelsWide),
                    y: viewBounds.minY
                        + (CGFloat(y) + 0.5) * viewBounds.height
                        / CGFloat(representation.pixelsHigh)
                )
                guard !excludedFrame.contains(point) else { continue }
                result += Double(
                    representation.colorAt(x: x, y: y)?.alphaComponent ?? 0
                )
            }
        }
        return result
    }

    private func perimeterAlphaSum(in representation: NSBitmapImageRep) -> Double {
        guard representation.pixelsWide > 1,
              representation.pixelsHigh > 1
        else { return 0 }

        var result = 0.0
        for x in 0..<representation.pixelsWide {
            result += alpha(in: representation, x: x, y: 0)
            result += alpha(
                in: representation,
                x: x,
                y: representation.pixelsHigh - 1
            )
        }
        for y in 1..<(representation.pixelsHigh - 1) {
            result += alpha(in: representation, x: 0, y: y)
            result += alpha(
                in: representation,
                x: representation.pixelsWide - 1,
                y: y
            )
        }
        return result
    }

    private func alpha(
        in representation: NSBitmapImageRep,
        x: Int,
        y: Int
    ) -> Double {
        Double(representation.colorAt(x: x, y: y)?.alphaComponent ?? 0)
    }
}

@MainActor
private final class ManualFeedbackScheduler: FeedbackScheduling {
    private(set) var delay: TimeInterval = 0
    private var completion: (@MainActor () -> Void)?
    private var cancelledCompletions: [@MainActor () -> Void] = []

    func schedule(
        after delay: TimeInterval,
        completion: @escaping @MainActor () -> Void
    ) {
        self.delay = delay
        self.completion = completion
    }

    func cancel() {
        if let completion {
            cancelledCompletions.append(completion)
        }
        completion = nil
    }

    func fire() {
        let completion = completion
        self.completion = nil
        completion?()
    }

    func fireCancelled() {
        guard !cancelledCompletions.isEmpty else { return }
        let completion = cancelledCompletions.removeFirst()
        completion()
    }
}

@MainActor
private final class RecordingAccessibilityAnnouncer: AccessibilityAnnouncing {
    private(set) var messages: [String] = []

    func announce(_ message: String, for element: Any) {
        messages.append(message)
    }
}
