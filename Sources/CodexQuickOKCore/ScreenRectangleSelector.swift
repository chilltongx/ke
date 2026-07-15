import CoreGraphics

public enum ScreenRectangleSelector {
    public static func preferredIndex(
        for panelFrame: CGRect,
        among screenFrames: [CGRect]
    ) -> Int? {
        let center = CGPoint(x: panelFrame.midX, y: panelFrame.midY)
        if let index = screenFrames.firstIndex(where: {
            contains(center, in: $0)
        }) {
            return index
        }

        var best: (index: Int, area: CGFloat)?
        for (index, screenFrame) in screenFrames.enumerated() {
            let intersection = panelFrame.intersection(screenFrame)
            guard !intersection.isNull, !intersection.isEmpty else { continue }
            let area = intersection.width * intersection.height
            if area > (best?.area ?? -.infinity) {
                best = (index, area)
            }
        }
        return best?.index
    }

    private static func contains(_ point: CGPoint, in rect: CGRect) -> Bool {
        let rect = rect.standardized
        return point.x >= rect.minX && point.x < rect.maxX
            && point.y >= rect.minY && point.y < rect.maxY
    }
}
