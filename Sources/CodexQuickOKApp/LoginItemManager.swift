import ServiceManagement

@MainActor
protocol LegacyLoginItemMigrationStateStoring: AnyObject {
    var removalPending: Bool { get set }
}

@MainActor
final class UserDefaultsLoginItemMigrationState: LegacyLoginItemMigrationStateStoring {
    private static let key = "legacyMainAppLoginItemRemovalPending.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var removalPending: Bool {
        get { defaults.bool(forKey: Self.key) }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}

@MainActor
protocol LegacyLoginItemManaging: AnyObject {
    var status: SMAppService.Status { get }
    func unregister() async throws
}

@MainActor
final class MainAppLoginItemManager: LegacyLoginItemManaging {
    var status: SMAppService.Status { SMAppService.mainApp.status }

    func unregister() async throws {
        try await SMAppService.mainApp.unregister()
    }
}
