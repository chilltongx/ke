import XCTest
@testable import CodexQuickOKCore

final class HookReducerTests: XCTestCase {
    func testClassifiesApprovalRequestsWithoutTreatingOrdinaryQuestionsAsApproval() {
        XCTAssertTrue(ApprovalClassifier.isApprovalRequest("要我继续执行吗？"))
        XCTAssertTrue(ApprovalClassifier.isApprovalRequest("Please confirm, then I will proceed."))
        XCTAssertFalse(ApprovalClassifier.isApprovalRequest("这个函数为什么返回 nil？"))
        XCTAssertFalse(ApprovalClassifier.isApprovalRequest("修改已经完成。"))
    }

    func testReducesPromptAndStopEvents() throws {
        let prompt = try HookEvent.decode(Data("""
        {"session_id":"s1","hook_event_name":"UserPromptSubmit","cwd":"/tmp/p"}
        """.utf8))
        let running = HookReducer.reduce(event: prompt, previous: nil, now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(running?.phase, .running)

        let stop = try HookEvent.decode(Data("""
        {"session_id":"s1","hook_event_name":"Stop","cwd":"/tmp/p","last_assistant_message":"可以继续吗？"}
        """.utf8))
        let waiting = HookReducer.reduce(event: stop, previous: running, now: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(waiting?.phase, .waitingForApproval)
        XCTAssertEqual(waiting?.waitingSince, Date(timeIntervalSince1970: 2))
    }
}
