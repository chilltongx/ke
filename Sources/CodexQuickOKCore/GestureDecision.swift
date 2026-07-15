import CoreGraphics

public enum GestureDecision {
    public static func isClick(
        start: CGPoint,
        end: CGPoint,
        threshold: CGFloat = 5
    ) -> Bool {
        hypot(end.x - start.x, end.y - start.y) <= threshold
    }
}
