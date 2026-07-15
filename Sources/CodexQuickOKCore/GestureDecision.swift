import CoreGraphics

public enum GestureDecision {
    public static let defaultThreshold: CGFloat = 5

    public static func isClick(
        start: CGPoint,
        end: CGPoint,
        threshold: CGFloat = defaultThreshold
    ) -> Bool {
        hypot(end.x - start.x, end.y - start.y) <= threshold
    }
}

public struct PointerGestureTracker {
    private let start: CGPoint
    private let threshold: CGFloat
    private var exceededThreshold = false

    public init(
        start: CGPoint,
        threshold: CGFloat = GestureDecision.defaultThreshold
    ) {
        self.start = start
        self.threshold = threshold
    }

    public mutating func observe(_ point: CGPoint) {
        if !GestureDecision.isClick(
            start: start,
            end: point,
            threshold: threshold
        ) {
            exceededThreshold = true
        }
    }

    public func isClick(endingAt point: CGPoint) -> Bool {
        !exceededThreshold && GestureDecision.isClick(
            start: start,
            end: point,
            threshold: threshold
        )
    }
}
