import XCTest
@testable import CodexQuickOKCore

final class SessionSnapshotTests: XCTestCase {
    func testHidesWithoutCodexAndSelectsNewestWaitingSession() {
        let now = Date(timeIntervalSince1970: 100)
        let states = [
            SessionState(sessionId: "older", phase: .waitingForApproval, updatedAt: now, waitingSince: now.addingTimeInterval(-5)),
            SessionState(sessionId: "newer", phase: .waitingForApproval, updatedAt: now, waitingSince: now.addingTimeInterval(-1)),
        ]
        XCTAssertEqual(SessionSnapshotEvaluator.evaluate(states: states, codexRunning: false, now: now).mode, .hidden)
        let visible = SessionSnapshotEvaluator.evaluate(states: states, codexRunning: true, now: now)
        XCTAssertEqual(visible.mode, .waiting)
        XCTAssertEqual(visible.targetSessionId, "newer")
    }

    func testShowsRunningButHasNoSendTarget() {
        let now = Date()
        let snapshot = SessionSnapshotEvaluator.evaluate(
            states: [SessionState(sessionId: "run", phase: .running, updatedAt: now)],
            codexRunning: true, now: now
        )
        XCTAssertEqual(snapshot.mode, .running)
        XCTAssertNil(snapshot.targetSessionId)
    }
}
