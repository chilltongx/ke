import AppKit
import CodexQuickOKCore

@MainActor
final class HaloButtonView: NSView {
    var onActivate: (() -> Void)?
    var onMoveOrigin: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?
    var isActivationEnabled = true

    private var startScreen: NSPoint?
    private var grabOffset: NSPoint?
    private(set) var remainingPercent: Double?

    override var intrinsicContentSize: NSSize {
        NSSize(width: 64, height: 64)
    }

    override func mouseDown(with event: NSEvent) {
        startScreen = NSEvent.mouseLocation
        grabOffset = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grabOffset else { return }
        let mouse = NSEvent.mouseLocation
        onMoveOrigin?(
            NSPoint(x: mouse.x - grabOffset.x, y: mouse.y - grabOffset.y)
        )
    }

    override func mouseUp(with event: NSEvent) {
        guard let startScreen else { return }
        let isClick = GestureDecision.isClick(
            start: startScreen,
            end: NSEvent.mouseLocation
        )

        if isClick {
            if isActivationEnabled {
                onActivate?()
            }
        } else {
            onDragEnded?()
        }

        self.startScreen = nil
        grabOffset = nil
    }

    func setQuota(_ quota: WeeklyQuota?) {
        remainingPercent = quota?.remainingPercent
        toolTip = quota.map {
            "周额度剩余 \(Int($0.remainingPercent.rounded()))%，重置于 \($0.resetsAt.formatted())"
        } ?? "周额度暂不可用"
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let ringRadius: CGFloat = 29

        CodexQuickOKColor.coal.setFill()
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
        CodexQuickOKColor.quota(for: percent).setStroke()
        ring.stroke()

        let text = NSAttributedString(
            string: "可",
            attributes: [
                .font: CodexQuickOKFont.approvalGlyph,
                .foregroundColor: CodexQuickOKColor.chalk,
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

    static func quota(for remainingPercent: Double?) -> NSColor {
        guard let remainingPercent else { return unavailable }
        if remainingPercent < 20 { return red }
        if remainingPercent <= 50 { return amber }
        return mint
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
