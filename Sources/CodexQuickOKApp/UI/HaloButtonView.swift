import AppKit
import CodexQuickOKCore
import QuartzCore

enum HaloFeedbackState: Equatable {
    case success
    case failure
}

enum HaloColorToken: Equatable {
    case coal
    case chalk
    case mint
    case amber
    case red
    case unavailable
}

struct HaloDrawingState: Equatable {
    let sealFill: HaloColorToken
    let glyph: HaloColorToken
    let halo: HaloColorToken
}

@MainActor
enum FireflyAttentionStyle {
    static let cyan = NSColor(
        srgbRed: 0x68 / 255,
        green: 0xE8 / 255,
        blue: 0xE1 / 255,
        alpha: 1
    )
    static let haloOpacity: Float = 0.52
    static let fireflyOpacity: Float = 0.62
}

@MainActor
final class HaloButtonView: NSView {
    var onActivate: (() -> Void)?
    var onMoveOrigin: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?
    var reduceMotion: () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    var isActivationEnabled = true {
        didSet {
            setAccessibilityEnabled(isActivationEnabled)
            refreshAccessibilityPresentation()
            needsDisplay = true
        }
    }

    private var gestureTracker: PointerGestureTracker?
    private var grabOffset: NSPoint?
    private(set) var isPointerDown = false
    private var isSending = false
    let attentionHaloLayer = CAShapeLayer()
    let attentionFireflyLayer = CAShapeLayer()
    let terminalFlashLayer = CAShapeLayer()
    private(set) var remainingPercent: Double?
    private(set) var terminalFlashFraction: CGFloat = 1
    private(set) var feedbackState: HaloFeedbackState?
    private(set) var attentionRequired = false
    private(set) var terminalFlashOutcome: CodexTerminalOutcome?
    private(set) var quotaToolTip = "周额度暂不可用"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureAttentionHalo()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureAttentionHalo()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isActivationEnabled, let onActivate else { return false }
        onActivate()
        return true
    }

    var drawingState: HaloDrawingState {
        if feedbackState == .success {
            return HaloDrawingState(
                sealFill: .mint,
                glyph: .coal,
                halo: .chalk
            )
        }
        if feedbackState == .failure {
            return HaloDrawingState(
                sealFill: .red,
                glyph: .chalk,
                halo: .red
            )
        }
        let percent = remainingPercent.map { min(100, max(0, $0)) }
        return HaloDrawingState(
            sealFill: .coal,
            glyph: .chalk,
            halo: CodexQuickOKColor.quotaToken(for: percent)
        )
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 64, height: 64)
    }

    override func layout() {
        super.layout()
        attentionHaloLayer.frame = bounds
        attentionFireflyLayer.frame = bounds
        terminalFlashLayer.frame = bounds
        let haloBounds = bounds.insetBy(dx: 3, dy: 3)
        let path = CGPath(ellipseIn: haloBounds, transform: nil)
        attentionHaloLayer.path = path
        attentionHaloLayer.shadowPath = path
        attentionFireflyLayer.path = path
        attentionFireflyLayer.shadowPath = path
        updateTerminalFlashPath()
    }

    override func mouseDown(with event: NSEvent) {
        gestureTracker = PointerGestureTracker(start: NSEvent.mouseLocation)
        grabOffset = event.locationInWindow
        setPointerDown(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grabOffset, var gestureTracker else { return }
        let mouse = NSEvent.mouseLocation
        gestureTracker.observe(mouse)
        self.gestureTracker = gestureTracker
        if !gestureTracker.isClick(endingAt: mouse) {
            setPointerDown(false)
        }
        onMoveOrigin?(
            NSPoint(x: mouse.x - grabOffset.x, y: mouse.y - grabOffset.y)
        )
    }

    override func mouseUp(with event: NSEvent) {
        guard let gestureTracker else { return }
        let isClick = gestureTracker.isClick(endingAt: NSEvent.mouseLocation)
        setPointerDown(false)

        if isClick {
            if isActivationEnabled {
                onActivate?()
            }
        } else {
            onDragEnded?()
        }

        self.gestureTracker = nil
        grabOffset = nil
    }

    func setSending(_ sending: Bool) {
        isSending = sending
        refreshAttentionGlowVisibility()
        isActivationEnabled = !sending
    }

    func setQuota(_ quota: WeeklyQuota?) {
        remainingPercent = quota?.remainingPercent
        quotaToolTip = quota.map {
            "周额度剩余 \(Int($0.remainingPercent.rounded()))%，重置于 \($0.resetsAt.formatted())"
        } ?? "周额度暂不可用"
        updateTerminalFlashPath()
        if feedbackState == nil { restoreIdlePresentation() }
        needsDisplay = true
    }

    func setAttentionRequired(_ required: Bool) {
        guard attentionRequired != required else { return }
        attentionRequired = required
        refreshAttentionGlowVisibility()
        if feedbackState == nil { restoreIdlePresentation() }
    }

    func showSuccessFeedback() {
        toolTip = quotaToolTip
        feedbackState = .success
        refreshAttentionGlowVisibility()
        setAccessibilityValue("已发送可")
        NSAccessibility.post(element: self, notification: .valueChanged)
        needsDisplay = true
    }

    func showFailureFeedback(_ message: String) {
        feedbackState = .failure
        refreshAttentionGlowVisibility()
        toolTip = message
        setAccessibilityValue(message)
        NSAccessibility.post(element: self, notification: .valueChanged)
        needsDisplay = true
    }

    func endFeedback() {
        guard feedbackState != nil else { return }
        feedbackState = nil
        refreshAttentionGlowVisibility()
        restoreIdlePresentation()
        NSAccessibility.post(element: self, notification: .valueChanged)
        needsDisplay = true
    }

    func showTerminalFlash(_ outcome: CodexTerminalOutcome) {
        let color = CodexQuickOKColor.value(for: drawingState.halo)
        terminalFlashLayer.strokeColor = color.cgColor
        terminalFlashLayer.shadowColor = color.cgColor
        terminalFlashOutcome = outcome
        refreshAttentionGlowVisibility()
        terminalFlashLayer.opacity = 1
        terminalFlashLayer.shadowOpacity = reduceMotion() ? 0.16 : 0
    }

    func hideTerminalFlash() {
        terminalFlashLayer.removeAllAnimations()
        terminalFlashLayer.shadowOpacity = 0
        terminalFlashLayer.opacity = 0
        terminalFlashOutcome = nil
        refreshAttentionGlowVisibility()
    }

    private func updateTerminalFlashPath() {
        let fraction = CGFloat(min(100, max(0, remainingPercent ?? 100))) / 100
        terminalFlashFraction = fraction
        let path = CGMutablePath()
        if fraction > 0 {
            path.addArc(
                center: CGPoint(x: bounds.midX, y: bounds.midY),
                radius: 29,
                startAngle: .pi / 2,
                endAngle: .pi / 2 - 2 * .pi * fraction,
                clockwise: true
            )
        }
        terminalFlashLayer.path = path
        terminalFlashLayer.shadowPath = nil
    }

    private func configureAttentionHalo() {
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("发送可")
        setAccessibilityHelp("向当前空白聊天输入框发送“可”；按住拖动可移动按钮")
        setAccessibilityEnabled(isActivationEnabled)
        attentionHaloLayer.fillColor = NSColor.clear.cgColor
        attentionHaloLayer.strokeColor = FireflyAttentionStyle.cyan.cgColor
        attentionHaloLayer.lineWidth = 1.7
        attentionHaloLayer.shadowColor = FireflyAttentionStyle.cyan.cgColor
        attentionHaloLayer.shadowRadius = 5
        attentionHaloLayer.shadowOpacity = 0.42
        attentionHaloLayer.shadowOffset = .zero
        attentionHaloLayer.opacity = 0
        layer?.addSublayer(attentionHaloLayer)

        attentionFireflyLayer.fillColor = NSColor.clear.cgColor
        attentionFireflyLayer.strokeColor = FireflyAttentionStyle.cyan.cgColor
        attentionFireflyLayer.lineWidth = 2.6
        attentionFireflyLayer.lineCap = .round
        attentionFireflyLayer.strokeStart = 0.08
        attentionFireflyLayer.strokeEnd = 0.15
        attentionFireflyLayer.shadowColor = FireflyAttentionStyle.cyan.cgColor
        attentionFireflyLayer.shadowRadius = 8
        attentionFireflyLayer.shadowOpacity = 0.58
        attentionFireflyLayer.shadowOffset = .zero
        attentionFireflyLayer.opacity = 0
        layer?.addSublayer(attentionFireflyLayer)

        terminalFlashLayer.fillColor = NSColor.clear.cgColor
        terminalFlashLayer.strokeColor = NSColor.white.withAlphaComponent(0.08).cgColor
        terminalFlashLayer.lineWidth = 4
        terminalFlashLayer.lineCap = .round
        terminalFlashLayer.shadowRadius = 3
        terminalFlashLayer.shadowOpacity = 0
        terminalFlashLayer.shadowOffset = .zero
        terminalFlashLayer.opacity = 0
        layer?.addSublayer(terminalFlashLayer)
        restoreIdlePresentation()
    }

    private func refreshAttentionGlowVisibility() {
        let visible = attentionRequired
            && feedbackState == nil
            && terminalFlashOutcome == nil
            && !isSending
        attentionHaloLayer.opacity = visible
            ? FireflyAttentionStyle.haloOpacity
            : 0
        attentionFireflyLayer.opacity = visible
            ? FireflyAttentionStyle.fireflyOpacity
            : 0
    }

    private func restoreIdlePresentation() {
        if attentionRequired {
            toolTip = "Codex 等待你的确认；\(quotaToolTip)"
            setAccessibilityValue("Codex 等待你的确认")
        } else {
            toolTip = quotaToolTip
            setAccessibilityValue(quotaToolTip)
        }
    }

    private func refreshAccessibilityPresentation() {
        if isSending {
            setAccessibilityValue("正在发送可")
        } else if !isActivationEnabled {
            setAccessibilityValue("暂不可用")
        } else if let feedbackState {
            switch feedbackState {
            case .success:
                setAccessibilityValue("已发送可")
            case .failure:
                setAccessibilityValue(toolTip)
            }
        } else {
            restoreIdlePresentation()
        }
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    private func setPointerDown(_ pressed: Bool) {
        guard isPointerDown != pressed else { return }
        isPointerDown = pressed
        let targetScale: CGFloat = pressed && isActivationEnabled ? 0.96 : 1
        if reduceMotion() {
            layer?.setAffineTransform(.identity)
            layer?.opacity = pressed && isActivationEnabled ? 0.72 : 1
            return
        }

        layer?.opacity = 1
        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = layer?.presentation()?.value(forKeyPath: "transform.scale") ?? 1
        animation.toValue = targetScale
        animation.duration = 0.09
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.setAffineTransform(CGAffineTransform(scaleX: targetScale, y: targetScale))
        layer?.add(animation, forKey: "pointer-press")
    }

    override func draw(_ dirtyRect: NSRect) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let ringRadius: CGFloat = 29

        let drawingState = drawingState
        CodexQuickOKColor.value(for: drawingState.sealFill).setFill()
        NSBezierPath(
            ovalIn: NSRect(
                x: center.x - ringRadius,
                y: center.y - ringRadius,
                width: ringRadius * 2,
                height: ringRadius * 2
            )
        ).fill()

        let percent = remainingPercent.map { min(100, max(0, $0)) }
        let ring = NSBezierPath()
        ring.lineWidth = 4
        ring.lineCapStyle = .round
        ring.appendArc(
            withCenter: center,
            radius: ringRadius,
            startAngle: 90,
            endAngle: 90 - 360 * CGFloat((percent ?? 100) / 100),
            clockwise: true
        )
        CodexQuickOKColor.value(for: drawingState.halo).setStroke()
        ring.stroke()

        let text = NSAttributedString(
            string: "可",
            attributes: [
                .font: CodexQuickOKFont.approvalGlyph,
                .foregroundColor: CodexQuickOKColor.value(
                    for: drawingState.glyph
                ),
            ]
        )
        let textSize = text.size()
        text.draw(
            at: NSPoint(
                x: center.x - textSize.width / 2,
                y: center.y - textSize.height / 2
            )
        )
    }
}

@MainActor
private enum CodexQuickOKColor {
    static let coal = NSColor(srgbRed: 0x1E / 255, green: 0x1E / 255, blue: 0x1F / 255, alpha: 1)
    static let chalk = NSColor(srgbRed: 0xF6 / 255, green: 0xF7 / 255, blue: 0xF8 / 255, alpha: 1)
    static let mint = NSColor(srgbRed: 0x55 / 255, green: 0xD6 / 255, blue: 0xBE / 255, alpha: 1)
    static let amber = NSColor(srgbRed: 0xF4 / 255, green: 0xA3 / 255, blue: 0x40 / 255, alpha: 1)
    static let red = NSColor(srgbRed: 0xFF / 255, green: 0x5A / 255, blue: 0x5F / 255, alpha: 1)
    static let unavailable = NSColor(srgbRed: 0x7C / 255, green: 0x80 / 255, blue: 0x87 / 255, alpha: 1)

    static func quotaToken(for remainingPercent: Double?) -> HaloColorToken {
        guard let remainingPercent else { return .unavailable }
        if remainingPercent < 20 { return .red }
        if remainingPercent <= 50 { return .amber }
        return .mint
    }

    static func value(for token: HaloColorToken) -> NSColor {
        switch token {
        case .coal: coal
        case .chalk: chalk
        case .mint: mint
        case .amber: amber
        case .red: red
        case .unavailable: unavailable
        }
    }
}

@MainActor
private enum CodexQuickOKFont {
    static let approvalGlyph: NSFont = {
        let base = NSFont.systemFont(ofSize: 21, weight: .bold)
        guard let rounded = base.fontDescriptor.withDesign(.rounded) else {
            return base
        }
        return NSFont(descriptor: rounded, size: 21) ?? base
    }()
}
