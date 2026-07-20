import XCTest
@testable import CodexQuickOKCore

final class SendSafetyTests: XCTestCase {
    func testRejectsWrongApplication() {
        XCTAssertThrowsError(
            try SendSafety.validate(
                bundleId: "com.apple.TextEdit",
                composerValue: ""
            )
        ) { error in
            XCTAssertEqual(error as? SendSafetyError, .wrongApplication)
        }
    }

    func testRejectsExistingDraft() {
        XCTAssertThrowsError(
            try SendSafety.validate(
                bundleId: "com.openai.codex",
                composerValue: "draft"
            )
        ) { error in
            XCTAssertEqual(error as? SendSafetyError, .existingDraft)
        }
    }

    func testAcceptsEmptyOrWhitespaceOnlyComposer() {
        XCTAssertNoThrow(
            try SendSafety.validate(
                bundleId: "com.openai.codex",
                composerValue: ""
            )
        )
        XCTAssertNoThrow(
            try SendSafety.validate(
                bundleId: "com.openai.codex",
                composerValue: " \n\t"
            )
        )
    }

    func testProvidesUserFacingFailureMessages() {
        XCTAssertEqual(
            SendSafetyError.wrongApplication.errorDescription,
            "无法确认当前窗口属于 Codex"
        )
        XCTAssertEqual(
            SendSafetyError.existingDraft.errorDescription,
            "检测到未发送草稿"
        )
    }
}
