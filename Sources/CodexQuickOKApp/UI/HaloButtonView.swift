import AppKit
import CodexQuickOKCore

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
final class HaloButtonView: NSView {
    var onActivate: (() -> Void)?
    var onMoveOrigin: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?
    var isActivationEnabled = true

    private var gestureTracker: PointerGestureTracker?
    private var grabOffset: NSPoint?
    private(set) var remainingPercent: Double?
    private(set) var feedbackState: HaloFeedbackState?
    private(set) var quotaToolTip = "周额度暂不可用"

    var drawingState: HaloDrawingState {
        if feedbackState == .success {
            return HaloDrawingState(
                sealFill: .mint,
                glyph: .coal,
                halo: .chalk
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

    override func mouseDown(with event: NSEvent) {
        gestureTracker = PointerGestureTracker(start: NSEvent.mouseLocation)
        grabOffset = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grabOffset, var gestureTracker else { return }
        let mouse = NSEvent.mouseLocation
        gestureTracker.observe(mouse)
        self.gestureTracker = gestureTracker
        onMoveOrigin?(
            NSPoint(x: mouse.x - grabOffset.x, y: mouse.y - grabOffset.y)
        )
    }

    override func mouseUp(with event: NSEvent) {
        guard let gestureTracker else { return }
        let isClick = gestureTracker.isClick(endingAt: NSEvent.mouseLocation)

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

    func setQuota(_ quota: WeeklyQuota?) {
        remainingPercent = quota?.remainingPercent
        quotaToolTip = quota.map {
            "周额度剩余 \(Int($0.remainingPercent.rounded()))%，重置于 \($0.resetsAt.formatted())"
        } ?? "周额度暂不可用"
        if feedbackState != .failure {
            toolTip = quotaToolTip
        }
        needsDisplay = true
    }

    func showSuccessFeedback() {
        toolTip = quotaToolTip
        feedbackState = .success
        setAccessibilityValue("批准成功")
        needsDisplay = true
    }

    func showFailureFeedback(_ message: String) {
        feedbackState = .failure
        toolTip = message
        setAccessibilityValue(message)
    }

    func endFeedback() {
        guard feedbackState != nil else { return }
        feedbackState = nil
        toolTip = quotaToolTip
        setAccessibilityValue(quotaToolTip)
        needsDisplay = true
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
