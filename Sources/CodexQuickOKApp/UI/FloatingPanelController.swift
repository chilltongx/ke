import AppKit
import CodexQuickOKCore
import QuartzCore

@MainActor
protocol FeedbackScheduling: AnyObject {
    func schedule(
        after delay: TimeInterval,
        completion: @escaping @MainActor () -> Void
    )
    func cancel()
}

@MainActor
final class TaskFeedbackScheduler: FeedbackScheduling {
    private var task: Task<Void, Never>?

    func schedule(
        after delay: TimeInterval,
        completion: @escaping @MainActor () -> Void
    ) {
        cancel()
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.task = nil
            completion()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

@MainActor
protocol AccessibilityAnnouncing: AnyObject {
    func announce(_ message: String, for element: Any)
}

@MainActor
final class SystemAccessibilityAnnouncer: AccessibilityAnnouncing {
    func announce(_ message: String, for element: Any) {
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}

@MainActor
private final class FloatingPanelCanvasView: NSView {
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

@MainActor
protocol CompanionPanel: AnyObject {
    var onActivate: (() -> Void)? { get set }
    var onTemporaryHide: (() -> Void)? { get set }
    var onRefreshQuota: (() -> Void)? { get set }

    func show(mode: CompanionMode)
    func hide()
    func setQuota(_ quota: WeeklyQuota?)
    func setSending(_ sending: Bool)
    func showSuccess()
    func showFailure(_ message: String)
    func showTaskTerminal(_ outcome: CodexTerminalOutcome)
}

@MainActor
final class FloatingPanelController: NSObject, CompanionPanel {
    private static let failureDisplayDuration: TimeInterval = 4
    private static let terminalFlashDuration: TimeInterval = 1.6
    private static let buttonDiameter: CGFloat = 64
    private static let glowCanvasPadding: CGFloat = 6
    private static let glowCanvasSize = NSSize(width: 76, height: 76)

    private enum AnimationKey {
        static let presence = "presence"
        static let attention = "attention-glow"
        static let attentionFirefly = "attention-firefly"
        static let attentionDrift = "attention-firefly-drift"
        static let sending = "sending"
        static let success = "success"
        static let failure = "failure"
        static let taskTerminal = "task-terminal"
    }

    private let panel: NSPanel
    private let positionStore: PanelPositionStore
    private let reduceMotion: () -> Bool
    private let feedbackScheduler: any FeedbackScheduling
    private let accessibilityAnnouncer: any AccessibilityAnnouncing
    let button = HaloButtonView(
        frame: NSRect(x: 0, y: 0, width: 64, height: 64)
    )
    private let canvas = FloatingPanelCanvasView(
        frame: NSRect(origin: .zero, size: glowCanvasSize)
    )
    private let quotaDetailItem = NSMenuItem(
        title: "周额度暂不可用",
        action: nil,
        keyEquivalent: ""
    )
    private var mode: CompanionMode = .hidden
    private var isSending = false
    private var isShowingFeedback = false
    private var feedbackGeneration: UInt64 = 0
    private var terminalQueue: [CodexTerminalOutcome] = []
    private var activeTerminalOutcome: CodexTerminalOutcome?
    var onActivate: (() -> Void)? {
        didSet { button.onActivate = onActivate }
    }
    var onRefreshQuota: (() -> Void)?
    var onTemporaryHide: (() -> Void)?

    init(
        positionStore: PanelPositionStore = PanelPositionStore(),
        reduceMotion: @escaping () -> Bool = {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        },
        feedbackScheduler: any FeedbackScheduling = TaskFeedbackScheduler(),
        accessibilityAnnouncer: any AccessibilityAnnouncing = SystemAccessibilityAnnouncer()
    ) {
        self.positionStore = positionStore
        self.reduceMotion = reduceMotion
        self.feedbackScheduler = feedbackScheduler
        self.accessibilityAnnouncer = accessibilityAnnouncer
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.glowCanvasSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        canvas.wantsLayer = true
        canvas.layer?.masksToBounds = false
        button.frame = NSRect(
            x: Self.glowCanvasPadding,
            y: Self.glowCanvasPadding,
            width: Self.buttonDiameter,
            height: Self.buttonDiameter
        )
        canvas.addSubview(button)
        panel.contentView = canvas
        button.reduceMotion = reduceMotion

        button.wantsLayer = true
        button.onMoveOrigin = { [weak self] origin in
            guard let self else { return }
            panel.setFrameOrigin(origin)
        }
        button.onDragEnded = { [weak self] in
            self?.persistPosition()
        }

        if let origin = positionStore.restore(
            panelSize: panel.frame.size,
            screens: NSScreen.screens
        ) {
            panel.setFrameOrigin(origin)
        } else if let visible = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(
                NSPoint(
                    x: visible.maxX - 88 - Self.glowCanvasPadding,
                    y: visible.midY - 32 - Self.glowCanvasPadding
                )
            )
        }

        let menu = NSMenu()
        quotaDetailItem.isEnabled = false
        menu.addItem(quotaDetailItem)
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "刷新周额度",
            action: #selector(refreshQuota),
            keyEquivalent: ""
        )
        menu.addItem(
            withTitle: "隐藏按钮（点 Dock 恢复）",
            action: #selector(hideTemporarily),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "退出 Codex 可",
            action: #selector(quit),
            keyEquivalent: ""
        )
        for item in menu.items where item.action != nil {
            item.target = self
        }
        button.menu = menu
    }

    func show(mode: CompanionMode) {
        self.mode = mode
        button.setAttentionRequired(mode == .waiting)
        guard mode != .hidden else {
            hide()
            return
        }

        panel.orderFrontRegardless()
        if !isShowingFeedback {
            updateContinuousAnimation()
        }
    }

    func hide() {
        mode = .hidden
        button.setAttentionRequired(false)
        cancelFeedback()
        terminalQueue.removeAll()
        activeTerminalOutcome = nil
        button.hideTerminalFlash()
        removeMotionAnimations()
        panel.orderOut(nil)
    }

    func setQuota(_ quota: WeeklyQuota?) {
        button.setQuota(quota)
        quotaDetailItem.title = quota.map {
            "周额度剩余 \(Int($0.remainingPercent.rounded()))%，\($0.resetsAt.formatted()) 重置"
        } ?? "周额度暂不可用"
    }

    func setSending(_ sending: Bool) {
        isSending = sending
        if sending {
            cancelActiveTerminalFlash()
            cancelFeedback()
            button.setSending(true)
            updateContinuousAnimation()
        } else {
            button.setSending(false)
            if !isShowingFeedback {
                if !startNextTerminalFlashIfPossible() {
                    updateContinuousAnimation()
                }
            }
        }
    }

    func showSuccess() {
        cancelActiveTerminalFlash()
        button.layer?.opacity = 1
        button.layer?.setAffineTransform(.identity)
        button.showSuccessFeedback()
        accessibilityAnnouncer.announce("已发送可", for: button)
        let animation = CAKeyframeAnimation(keyPath: "transform.scale")
        animation.values = [1, 1.08, 1]
        animation.duration = 0.28
        showFeedback(
            motionIsAllowed ? animation : nil,
            key: AnimationKey.success,
            duration: animation.duration,
            completion: { [weak button] in
                button?.endFeedback()
            }
        )
    }

    func showFailure(_ message: String) {
        cancelActiveTerminalFlash()
        NSSound.beep()
        button.layer?.opacity = 1
        button.layer?.setAffineTransform(.identity)
        button.showFailureFeedback(message)
        accessibilityAnnouncer.announce(message, for: button)
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [1, 0.45, 1, 0.45, 1]
        animation.duration = 0.55
        showFeedback(
            motionIsAllowed ? animation : nil,
            key: AnimationKey.failure,
            duration: Self.failureDisplayDuration,
            completion: { [weak button] in
                button?.endFeedback()
            }
        )
    }

    func showTaskTerminal(_ outcome: CodexTerminalOutcome) {
        guard mode != .hidden else { return }
        terminalQueue.append(outcome)
        startNextTerminalFlashIfPossible()
    }

    @objc private func refreshQuota() {
        onRefreshQuota?()
    }

    @objc private func hideTemporarily() {
        hide()
        onTemporaryHide?()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private var motionIsAllowed: Bool {
        !reduceMotion()
    }

    private func updateContinuousAnimation() {
        removeMotionAnimations()
        guard mode != .hidden, motionIsAllowed else { return }

        if isSending {
            let animation = CABasicAnimation(keyPath: "transform.rotation.z")
            animation.byValue = Double.pi * 2
            animation.duration = 0.8
            animation.repeatCount = .infinity
            button.layer?.add(animation, forKey: AnimationKey.sending)
            return
        }

        if mode == .waiting {
            button.attentionHaloLayer.add(
                makeAmbientGlowAnimation(),
                forKey: AnimationKey.attention
            )
            button.attentionFireflyLayer.add(
                makeFireflyFlickerAnimation(),
                forKey: AnimationKey.attentionFirefly
            )
            button.attentionFireflyLayer.add(
                makeFireflyDriftAnimation(),
                forKey: AnimationKey.attentionDrift
            )
            return
        }

        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = 0.985
        animation.toValue = 1.015
        animation.duration = 1.8
        animation.autoreverses = true
        animation.repeatCount = .infinity
        button.layer?.add(animation, forKey: AnimationKey.presence)
    }

    private func showFeedback(
        _ animation: CAAnimation?,
        key: String,
        duration: TimeInterval,
        completion: @escaping @MainActor () -> Void = {}
    ) {
        let generation = beginFeedbackSchedule()
        removeMotionAnimations()
        isShowingFeedback = true
        if let animation {
            button.layer?.add(animation, forKey: key)
        }
        feedbackScheduler.schedule(after: duration) { [weak self] in
            guard let self, feedbackGeneration == generation else { return }
            isShowingFeedback = false
            completion()
            if !startNextTerminalFlashIfPossible() {
                updateContinuousAnimation()
            }
        }
    }

    @discardableResult
    private func startNextTerminalFlashIfPossible() -> Bool {
        guard !isShowingFeedback,
              !isSending,
              mode != .hidden,
              !terminalQueue.isEmpty
        else { return false }

        let outcome = terminalQueue.removeFirst()
        let announcement = outcome == .completed ? "任务已完成" : "任务已终止"
        let generation = beginFeedbackSchedule()
        removeMotionAnimations()
        button.showTerminalFlash(outcome)
        activeTerminalOutcome = outcome
        accessibilityAnnouncer.announce(announcement, for: button)
        isShowingFeedback = true

        if motionIsAllowed {
            let animation = CAKeyframeAnimation(keyPath: "shadowOpacity")
            animation.values = [0, 0.24, 0.02, 0.24, 0.02, 0.24, 0]
            animation.keyTimes = [0, 0.13, 0.29, 0.42, 0.58, 0.71, 1]
            animation.timingFunctions = Array(
                repeating: CAMediaTimingFunction(name: .easeInEaseOut),
                count: 6
            )
            animation.duration = Self.terminalFlashDuration
            button.terminalFlashLayer.add(
                animation,
                forKey: AnimationKey.taskTerminal
            )
        }

        feedbackScheduler.schedule(after: Self.terminalFlashDuration) { [weak self] in
            guard let self, feedbackGeneration == generation else { return }
            isShowingFeedback = false
            activeTerminalOutcome = nil
            button.hideTerminalFlash()
            if !startNextTerminalFlashIfPossible() {
                updateContinuousAnimation()
            }
        }
        return true
    }

    private func cancelActiveTerminalFlash() {
        guard activeTerminalOutcome != nil else { return }
        invalidateFeedbackSchedule()
        activeTerminalOutcome = nil
        isShowingFeedback = false
        button.hideTerminalFlash()
    }

    private func cancelFeedback() {
        invalidateFeedbackSchedule()
        isShowingFeedback = false
        activeTerminalOutcome = nil
        button.endFeedback()
        button.hideTerminalFlash()
    }

    private func beginFeedbackSchedule() -> UInt64 {
        feedbackScheduler.cancel()
        feedbackGeneration &+= 1
        return feedbackGeneration
    }

    private func invalidateFeedbackSchedule() {
        feedbackScheduler.cancel()
        feedbackGeneration &+= 1
    }

    private func removeMotionAnimations() {
        button.layer?.removeAnimation(forKey: AnimationKey.presence)
        button.attentionHaloLayer.removeAnimation(forKey: AnimationKey.attention)
        button.attentionFireflyLayer.removeAnimation(
            forKey: AnimationKey.attentionFirefly
        )
        button.attentionFireflyLayer.removeAnimation(
            forKey: AnimationKey.attentionDrift
        )
        button.layer?.removeAnimation(forKey: AnimationKey.sending)
        button.layer?.removeAnimation(forKey: AnimationKey.success)
        button.layer?.removeAnimation(forKey: AnimationKey.failure)
        button.terminalFlashLayer.removeAnimation(forKey: AnimationKey.taskTerminal)
    }

    private func makeAmbientGlowAnimation() -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [0.42, 0.51, 0.46, 0.59, 0.48, 0.55, 0.44]
        animation.keyTimes = [0, 0.16, 0.34, 0.53, 0.69, 0.87, 1]
        animation.timingFunctions = Array(
            repeating: CAMediaTimingFunction(name: .easeInEaseOut),
            count: 6
        )
        animation.duration = 6.4
        animation.repeatCount = .infinity
        return animation
    }

    private func makeFireflyFlickerAnimation() -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [0.20, 0.28, 0.70, 0.31, 0.44, 0.25, 0.76, 0.22]
        animation.keyTimes = [0, 0.13, 0.24, 0.39, 0.57, 0.72, 0.84, 1]
        animation.timingFunctions = Array(
            repeating: CAMediaTimingFunction(name: .easeInEaseOut),
            count: 7
        )
        animation.duration = 7.7
        animation.repeatCount = .infinity
        return animation
    }

    private func makeFireflyDriftAnimation() -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        animation.values = [-0.22, -0.08, 0.11, 0.04, 0.20, -0.03, -0.22]
        animation.keyTimes = [0, 0.17, 0.36, 0.51, 0.70, 0.86, 1]
        animation.timingFunctions = Array(
            repeating: CAMediaTimingFunction(name: .easeInEaseOut),
            count: 6
        )
        animation.duration = 13.6
        animation.repeatCount = .infinity
        return animation
    }

    private func persistPosition() {
        let screens = NSScreen.screens
        let preferredIndex = ScreenRectangleSelector.preferredIndex(
            for: panel.frame,
            among: screens.map(\.frame)
        )
        let screen = preferredIndex.map { screens[$0] } ?? NSScreen.main
        guard let screen else { return }

        let visible = screen.visibleFrame
        var origin = panel.frame.origin
        origin.x = min(
            max(origin.x, visible.minX),
            max(visible.minX, visible.maxX - panel.frame.width)
        )
        origin.y = min(
            max(origin.y, visible.minY),
            max(visible.minY, visible.maxY - panel.frame.height)
        )
        panel.setFrameOrigin(origin)
        positionStore.save(frame: panel.frame, screen: screen)
    }
}
