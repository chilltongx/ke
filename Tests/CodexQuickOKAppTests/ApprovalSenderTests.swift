import XCTest

@testable import CodexQuickOKApp

@MainActor
final class ApprovalSenderTests: XCTestCase {
    func testSendsOneChineseApprovalAfterEveryCheckPasses() async throws {
        let automation = FakeCodexAutomation(
            bundleId: "com.openai.codex",
            matched: true,
            value: ""
        )

        try await ApprovalSender(automation: automation).sendOK(sessionId: "s1")

        XCTAssertEqual(automation.activatedSessionIds, ["s1"])
        XCTAssertEqual(automation.writtenValues, ["可"])
        XCTAssertEqual(automation.sendCount, 1)
    }

    func testRejectsWrongApplicationWithoutWriting() async {
        await assertRejectedWithoutWriting(
            FakeCodexAutomation(
                bundleId: "com.apple.TextEdit",
                matched: true,
                value: ""
            )
        )
    }

    func testRejectsSessionMismatchWithoutWriting() async {
        await assertRejectedWithoutWriting(
            FakeCodexAutomation(
                bundleId: "com.openai.codex",
                matched: false,
                value: ""
            )
        )
    }

    func testRejectsExistingDraftWithoutWriting() async {
        await assertRejectedWithoutWriting(
            FakeCodexAutomation(
                bundleId: "com.openai.codex",
                matched: true,
                value: "draft"
            )
        )
    }

    func testRejectsStaleTargetAfterNavigationWithoutWriting() async {
        let automation = FakeCodexAutomation(
            bundleId: "com.openai.codex",
            matched: true,
            value: ""
        )
        let sender = ApprovalSender(
            automation: automation,
            isStillTarget: { _ in false }
        )

        do {
            try await sender.sendOK(sessionId: "s1")
            XCTFail("Expected latest-target rejection")
        } catch {}

        XCTAssertEqual(automation.activatedSessionIds, ["s1"])
        XCTAssertEqual(automation.writtenValues, [])
        XCTAssertEqual(automation.sendCount, 0)
    }

    func testDuplicateInFlightSendWritesAndPressesOnlyOnce() async throws {
        let automation = FakeCodexAutomation(
            bundleId: "com.openai.codex",
            matched: true,
            value: ""
        )
        automation.activationDelay = .milliseconds(100)
        let sender = ApprovalSender(automation: automation)

        async let first: Void = sender.sendOK(sessionId: "s1")
        async let second: Void = sender.sendOK(sessionId: "s1")
        _ = try await (first, second)

        XCTAssertEqual(automation.writtenValues, ["可"])
        XCTAssertEqual(automation.sendCount, 1)
    }

    func testActivationFailureNeverWrites() async {
        let automation = FakeCodexAutomation(
            bundleId: "com.openai.codex",
            matched: true,
            value: ""
        )
        automation.activationError = FakeCodexAutomation.FakeError.activationFailed

        await assertRejectedWithoutWriting(automation)
    }

    func testMissingComposerNeverWrites() async {
        let automation = FakeCodexAutomation(
            bundleId: "com.openai.codex",
            matched: true,
            value: ""
        )
        automation.composerError = FakeCodexAutomation.FakeError.composerUnavailable

        await assertRejectedWithoutWriting(automation)
    }

    private func assertRejectedWithoutWriting(
        _ automation: FakeCodexAutomation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await ApprovalSender(automation: automation).sendOK(sessionId: "s1")
            XCTFail("Expected safety rejection", file: file, line: line)
        } catch {}

        XCTAssertEqual(automation.writtenValues, [], file: file, line: line)
        XCTAssertEqual(automation.sendCount, 0, file: file, line: line)
    }
}

@MainActor
final class AccessibilityClientSafetyTests: XCTestCase {
    func testThreadURLPercentEncodesSessionAsOnePathComponent() throws {
        let url = try AccessibilityClient.threadURL(sessionId: "a/b?c#d%")

        XCTAssertEqual(url.absoluteString, "codex://threads/a%2Fb%3Fc%23d%25")
    }

    func testSelectsOneEditableComposerAndOneSendButton() throws {
        let elements = [
            AccessibilityClient.ElementSummary(
                role: "AXTextArea",
                title: nil,
                description: "Message",
                enabled: true,
                valueSettable: true
            ),
            AccessibilityClient.ElementSummary(
                role: "AXButton",
                title: "Send",
                description: nil,
                enabled: true,
                valueSettable: false
            ),
        ]

        XCTAssertEqual(
            try AccessibilityClient.selectControls(in: elements),
            .init(composerIndex: 0, sendButtonIndex: 1)
        )
    }

    func testRejectsNativeApprovalCardBeforeSelectingComposer() {
        let elements = [
            AccessibilityClient.ElementSummary(
                role: "AXTextArea",
                title: nil,
                description: "Message",
                enabled: true,
                valueSettable: true
            ),
            AccessibilityClient.ElementSummary(
                role: "AXButton",
                title: "Approve once",
                description: nil,
                enabled: true,
                valueSettable: false
            ),
            AccessibilityClient.ElementSummary(
                role: "AXButton",
                title: "Send",
                description: nil,
                enabled: true,
                valueSettable: false
            ),
        ]

        XCTAssertThrowsError(try AccessibilityClient.selectControls(in: elements)) { error in
            XCTAssertEqual(error as? AccessibilityClient.AXError, .nativeApprovalCard)
        }
    }

    func testRejectsAmbiguousComposerAndMissingSendButton() {
        let composer = AccessibilityClient.ElementSummary(
            role: "AXTextArea",
            title: nil,
            description: "Message",
            enabled: true,
            valueSettable: true
        )
        let send = AccessibilityClient.ElementSummary(
            role: "AXButton",
            title: "Send",
            description: nil,
            enabled: true,
            valueSettable: false
        )

        XCTAssertThrowsError(
            try AccessibilityClient.selectControls(in: [composer, composer, send])
        ) { error in
            XCTAssertEqual(error as? AccessibilityClient.AXError, .ambiguousTask)
        }
        XCTAssertThrowsError(
            try AccessibilityClient.selectControls(in: [composer])
        ) { error in
            XCTAssertEqual(error as? AccessibilityClient.AXError, .sendActionMissing)
        }
    }
}

@MainActor
final class SystemCodexAutomationTests: XCTestCase {
    func testReadsMetadataThenNavigatesAndWaitsForVisibleTask() async throws {
        let metadata = CodexAppServerClient.ThreadMetadata(
            id: "s1",
            title: "Task title",
            cwd: "/tmp/project",
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let accessibility = FakeAccessibilityController()
        let reader = FakeThreadMetadataReader(metadata: metadata)
        let automation = SystemCodexAutomation(
            accessibility: accessibility,
            metadataReader: reader
        )

        try await automation.activateAndOpen(sessionId: "s1")

        let requestedSessionIds = await reader.requestedSessionIds
        XCTAssertEqual(requestedSessionIds, ["s1"])
        XCTAssertEqual(accessibility.activationCount, 1)
        XCTAssertEqual(accessibility.openedSessionIds, ["s1"])
        XCTAssertEqual(accessibility.waitedTasks.count, 1)
        XCTAssertEqual(accessibility.waitedTasks[0].title, "Task title")
        XCTAssertEqual(accessibility.waitedTasks[0].cwd, "/tmp/project")
        XCTAssertEqual(accessibility.waitedTasks[0].timeout, 1.5)
        let currentSessionMatches = try await automation.currentSessionMatches("s1")
        XCTAssertTrue(currentSessionMatches)
    }

    func testRejectsMetadataForDifferentSessionBeforeActivatingCodex() async {
        let metadata = CodexAppServerClient.ThreadMetadata(
            id: "other",
            title: "Task title",
            cwd: "/tmp/project",
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let accessibility = FakeAccessibilityController()
        let automation = SystemCodexAutomation(
            accessibility: accessibility,
            metadataReader: FakeThreadMetadataReader(metadata: metadata)
        )

        do {
            try await automation.activateAndOpen(sessionId: "s1")
            XCTFail("Expected mismatched metadata rejection")
        } catch {}

        XCTAssertEqual(accessibility.activationCount, 0)
        XCTAssertEqual(accessibility.openedSessionIds, [])
    }
}
