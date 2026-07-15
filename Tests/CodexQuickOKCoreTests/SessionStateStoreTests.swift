import XCTest
@testable import CodexQuickOKCore

final class SessionStateStoreTests: XCTestCase {
    func testLoadsLegacyISO8601DateFixture() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let fixture = #"{"sessionId":"legacy","state":"running","updatedAt":"1970-01-01T02:46:40Z","waitingSince":null,"cwd":"/tmp/legacy"}"#
        try Data(fixture.utf8).write(to: directory.appendingPathComponent("legacy.json"))
        let store = SessionStateStore(directory: directory)

        let states = try await store.loadAll(
            now: Date(timeIntervalSince1970: 10_000),
            staleAfter: 43_200
        )

        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states[0].sessionId, "legacy")
        XCTAssertEqual(states[0].phase, .running)
        XCTAssertEqual(states[0].updatedAt, Date(timeIntervalSince1970: 10_000))
        XCTAssertEqual(states[0].cwd, "/tmp/legacy")
    }

    func testFilteredRemovalPreservesStatesNewerThanCutoff() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStateStore(directory: directory)
        let cutoff = Date(timeIntervalSince1970: 10_000)
        try await store.save(
            SessionState(sessionId: "old", phase: .running, updatedAt: cutoff)
        )
        try await store.save(
            SessionState(
                sessionId: "new",
                phase: .waitingForApproval,
                updatedAt: cutoff.addingTimeInterval(0.001)
            )
        )

        try await store.removeAll(updatedAtOrBefore: cutoff)
        let states = try await store.loadAll(
            now: cutoff.addingTimeInterval(1),
            staleAfter: 43_200
        )

        XCTAssertEqual(states.map(\.sessionId), ["new"])
    }

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

    func testRoundTripPreservesSubsecondHookTimestamp() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStateStore(directory: directory)
        let timestamp = Date(timeIntervalSince1970: 10_000.123_456)
        try await store.save(
            SessionState(
                sessionId: "subsecond",
                phase: .running,
                updatedAt: timestamp,
                waitingSince: timestamp
            )
        )

        let states = try await store.loadAll(now: timestamp, staleAfter: 43_200)

        XCTAssertEqual(states.first?.updatedAt, timestamp)
        XCTAssertEqual(states.first?.waitingSince, timestamp)
    }

    func testRejectsSessionIdsThatEscapeDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = root.appendingPathComponent("sessions", isDirectory: true)
        let outsideURL = root.appendingPathComponent("outside.json")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("sentinel".utf8).write(to: outsideURL)
        let store = SessionStateStore(directory: directory)
        let hostileSessionId = "../outside"
        let state = SessionState(
            sessionId: hostileSessionId,
            phase: .waitingForApproval,
            updatedAt: Date(timeIntervalSince1970: 10_000)
        )

        do {
            try await store.save(state)
            XCTFail("Expected save to reject a path-traversing session ID")
        } catch {
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteInvalidFileName)
        }
        XCTAssertEqual(try Data(contentsOf: outsideURL), Data("sentinel".utf8))

        do {
            try await store.remove(sessionId: hostileSessionId)
            XCTFail("Expected remove to reject a path-traversing session ID")
        } catch {
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteInvalidFileName)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideURL.path))
    }

    func testRejectsInvalidSessionIdsForSaveAndRemove() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStateStore(directory: directory)

        for sessionId in ["", ".", "..", "nested/id", "nul\0id"] {
            let state = SessionState(
                sessionId: sessionId,
                phase: .waitingForApproval,
                updatedAt: Date(timeIntervalSince1970: 10_000)
            )

            do {
                try await store.save(state)
                XCTFail("Expected save to reject session ID: \(sessionId.debugDescription)")
            } catch {
                XCTAssertEqual((error as? CocoaError)?.code, .fileWriteInvalidFileName)
            }

            do {
                try await store.remove(sessionId: sessionId)
                XCTFail("Expected remove to reject session ID: \(sessionId.debugDescription)")
            } catch {
                XCTAssertEqual((error as? CocoaError)?.code, .fileWriteInvalidFileName)
            }
        }
    }
}
