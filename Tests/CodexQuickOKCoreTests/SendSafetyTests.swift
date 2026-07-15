import XCTest

@testable import CodexQuickOKCore

final class SendSafetyTests: XCTestCase {
    func testRejectsWrongApplication() {
        XCTAssertThrowsError(
            try SendSafety.validate(
                bundleId: "com.apple.TextEdit",
                sessionMatched: true,
                composerValue: ""
            )
        ) { error in
            XCTAssertEqual(error as? SendSafetyError, .wrongApplication)
        }
    }

    func testRejectsSessionMismatch() {
        XCTAssertThrowsError(
            try SendSafety.validate(
                bundleId: "com.openai.codex",
                sessionMatched: false,
                composerValue: ""
            )
        ) { error in
            XCTAssertEqual(error as? SendSafetyError, .sessionMismatch)
        }
    }

    func testRejectsExistingDraft() {
        XCTAssertThrowsError(
            try SendSafety.validate(
                bundleId: "com.openai.codex",
                sessionMatched: true,
                composerValue: "draft"
            )
        ) { error in
            XCTAssertEqual(error as? SendSafetyError, .existingDraft)
        }
    }

    func testAcceptsVerifiedCodexSessionWithEmptyComposer() {
        XCTAssertNoThrow(
            try SendSafety.validate(
                bundleId: "com.openai.codex",
                sessionMatched: true,
                composerValue: ""
            )
        )
    }
}
