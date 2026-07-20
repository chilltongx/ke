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
}

@MainActor
final class FloatingPanelController: NSObject, CompanionPanel {
    private enum AnimationKey {
        static let presence = "presence"
        static let sending = "sending"
        static let success = "success"
        static let failure = "failure"
    }

    private let panel: NSPanel
    private let positionStore: PanelPositionStore
    private let reduceMotion: () -> Bool
    private let feedbackScheduler: any FeedbackScheduling
    private let accessibilityAnnouncer: any AccessibilityAnnouncing
    let button = HaloButtonView(
        frame: NSRect(x: 0, y: 0, width: 64, height: 64)
    )
    private let quotaDetailItem = NSMenuItem(
        title: "周额度暂不可用",
        action: nil,
        keyEquivalent: ""
    )
    private var mode: CompanionMode = .hidden
    private var isSending = false
    private var isShowingFeedback = false

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
            contentRect: button.bounds,
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
        panel.contentView = button

        button.wantsLayer = true
        button.onMoveOrigin = { [weak self] origin in
            self?.panel.setFrameOrigin(origin)
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
                NSPoint(x: visible.maxX - 88, y: visible.midY - 32)
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
        cancelFeedback()
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
        button.isActivationEnabled = !sending
        if sending {
            cancelFeedback()
            updateContinuousAnimation()
        } else if !isShowingFeedback {
            updateContinuousAnimation()
        }
    }

    func showSuccess() {
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
        NSSound.beep()
        button.showFailureFeedback(message)
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [1, 0.45, 1, 0.45, 1]
        animation.duration = 0.55
        showFeedback(
            motionIsAllowed ? animation : nil,
            key: AnimationKey.failure,
            duration: animation.duration,
            completion: { [weak button] in
                button?.endFeedback()
            }
        )
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

        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = mode == .waiting ? 0.97 : 0.985
        animation.toValue = mode == .waiting ? 1.03 : 1.015
        animation.duration = mode == .waiting ? 0.9 : 1.8
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
        feedbackScheduler.cancel()
        removeMotionAnimations()
        isShowingFeedback = true
        if let animation {
            button.layer?.add(animation, forKey: key)
        }
        feedbackScheduler.schedule(after: duration) { [weak self] in
            guard let self else { return }
            isShowingFeedback = false
            completion()
            updateContinuousAnimation()
        }
    }

    private func cancelFeedback() {
        feedbackScheduler.cancel()
        isShowingFeedback = false
        button.endFeedback()
    }

    private func removeMotionAnimations() {
        button.layer?.removeAnimation(forKey: AnimationKey.presence)
        button.layer?.removeAnimation(forKey: AnimationKey.sending)
        button.layer?.removeAnimation(forKey: AnimationKey.success)
        button.layer?.removeAnimation(forKey: AnimationKey.failure)
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
