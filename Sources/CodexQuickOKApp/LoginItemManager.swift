import ServiceManagement

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
