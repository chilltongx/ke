import Foundation
import XCTest
@testable import CodexQuickOKApp

final class CodexTaskAttentionParserTests: XCTestCase {
    func testParsesRecentThreadSummariesInServerOrder() throws {
        let response = try decode(#"{"data":[{"id":"new","updatedAt":20},{"id":"old","updatedAt":10}]}"#)

        XCTAssertEqual(
            CodexTaskAttentionParser.threadSummaries(from: response),
            [
                CodexThreadSummary(threadID: "new", updatedAt: 20),
                CodexThreadSummary(threadID: "old", updatedAt: 10),
            ]
        )
    }

    func testDetectsCompletedFinalAnswerThatNeedsConfirmation() throws {
        let response = try decode(#"{"thread":{"turns":[{"id":"turn-1","status":"completed","items":[{"type":"agentMessage","phase":"commentary","text":"我先检查一下。"},{"type":"agentMessage","phase":"final_answer","text":"阶段完成，需要你确认后继续执行。"}]}]}}"#)
        let summary = CodexThreadSummary(threadID: "thread-1", updatedAt: 30)

        XCTAssertEqual(
            CodexTaskAttentionParser.attention(from: response, summary: summary),
            CodexTaskAttention(threadID: "thread-1", turnID: "turn-1", updatedAt: 30)
        )
    }

    func testIgnoresOrdinaryFinalAnswerAndOlderWaitingTurn() throws {
        let ordinary = try decode(#"{"thread":{"turns":[{"id":"turn-1","status":"completed","items":[{"type":"agentMessage","phase":"final_answer","text":"修改已经完成。"}]}]}}"#)
        let superseded = try decode(#"{"thread":{"turns":[{"id":"turn-1","status":"completed","items":[{"type":"agentMessage","phase":"final_answer","text":"请确认后继续。"}]},{"id":"turn-2","status":"inProgress","items":[]}]}}"#)
        let summary = CodexThreadSummary(threadID: "thread-1", updatedAt: 30)

        XCTAssertNil(CodexTaskAttentionParser.attention(from: ordinary, summary: summary))
        XCTAssertNil(CodexTaskAttentionParser.attention(from: superseded, summary: summary))
    }

    func testCollectsCompletedAndInterruptedTurnsOnly() throws {
        let response = try decode(#"{"thread":{"turns":[{"id":"done","status":"completed","completedAt":10,"items":[]},{"id":"stopped","status":"interrupted","completedAt":20,"items":[]},{"id":"failed","status":"failed","completedAt":30,"items":[]},{"id":"active","status":"inProgress","items":[]}]}}"#)
        let summary = CodexThreadSummary(threadID: "thread-1", updatedAt: 40)

        XCTAssertEqual(
            CodexTaskAttentionParser.terminalTurns(from: response, summary: summary),
            [
                CodexTerminalTurn(
                    threadID: "thread-1",
                    turnID: "done",
                    outcome: .completed,
                    completedAt: 10
                ),
                CodexTerminalTurn(
                    threadID: "thread-1",
                    turnID: "stopped",
                    outcome: .interrupted,
                    completedAt: 20
                ),
            ]
        )
    }

    private func decode(_ source: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8))
    }
}
