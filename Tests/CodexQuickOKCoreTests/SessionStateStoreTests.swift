import XCTest
@testable import CodexQuickOKCore

final class SessionStateStoreTests: XCTestCase {
    func testRoundTripsAndExpiresStaleSessions() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = SessionStateStore(directory: directory)
        let now = Date(timeIntervalSince1970: 10_000)
        try await store.save(SessionState(
            sessionId: "session-1", phase: .waitingForApproval,
            updatedAt: now, waitingSince: now, cwd: "/tmp/project"
        ))

        let activeSessions = try await store.loadAll(now: now, staleAfter: 43_200)
        let staleSessions = try await store.loadAll(
            now: now.addingTimeInterval(43_201), staleAfter: 43_200
        )
        XCTAssertEqual(activeSessions.count, 1)
        XCTAssertEqual(staleSessions, [])
    }
}
