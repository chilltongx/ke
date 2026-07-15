import AppKit

struct StoredPanelPosition: Codable, Equatable {
    let screenIdentifier: String
    let xFraction: Double
    let yFraction: Double
}

@MainActor
final class PanelPositionStore {
    private let defaults: UserDefaults
    private let key = "panelPosition.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func save(frame: NSRect, screen: NSScreen) {
        let visible = screen.visibleFrame
        let xRange = max(1, visible.width - frame.width)
        let yRange = max(1, visible.height - frame.height)
        let value = StoredPanelPosition(
            screenIdentifier: screen.codexQuickOKIdentifier,
            xFraction: min(1, max(0, (frame.minX - visible.minX) / xRange)),
            yFraction: min(1, max(0, (frame.minY - visible.minY) / yRange))
        )
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    func restore(panelSize: NSSize, screens: [NSScreen]) -> NSPoint? {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(StoredPanelPosition.self, from: data),
              let screen = screens.first(where: {
                  $0.codexQuickOKIdentifier == value.screenIdentifier
              }) ?? screens.first
        else {
            return nil
        }

        let visible = screen.visibleFrame
        let xFraction = min(1, max(0, value.xFraction))
        let yFraction = min(1, max(0, value.yFraction))
        return NSPoint(
            x: visible.minX + xFraction * max(1, visible.width - panelSize.width),
            y: visible.minY + yFraction * max(1, visible.height - panelSize.height)
        )
    }
}

private extension NSScreen {
    var codexQuickOKIdentifier: String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? NSNumber)?.stringValue ?? localizedName
    }
}
