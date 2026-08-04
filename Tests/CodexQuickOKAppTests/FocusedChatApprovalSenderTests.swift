import XCTest

@testable import CodexQuickOKApp

@MainActor
final class FocusedChatApprovalSenderTests: XCTestCase {
    func testSendsOneApprovalToStableEmptyFocusedChat() async throws {
        let input = FakeFocusedInput(value: "")
        let sender = FocusedChatApprovalSender(
            input: input,
            classifier: StubChatClassifier(
                match: .init(kind: .visualStudioCode)
            )
        )

        try await sender.sendOK()

        XCTAssertEqual(input.events, [
            "capture",
            "read",
            "revalidate",
            "write:可",
            "wait:可:0.5",
            "revalidate",
            "return",
        ])
        XCTAssertEqual(input.returnCount, 1)
    }

    func testWhitespaceOnlyComposerIsAccepted() async throws {
        for value in [" ", "\n\t"] {
            let input = FakeFocusedInput(value: value)
            let sender = FocusedChatApprovalSender(
                input: input,
                classifier: StubChatClassifier(match: .init(kind: .generic))
            )

            try await sender.sendOK()

            XCTAssertEqual(input.returnCount, 1)
        }
    }

    func testDraftIsRejectedBeforeWrite() async {
        for value in ["draft", " 可 "] {
            let input = FakeFocusedInput(value: value)
            let sender = FocusedChatApprovalSender(
                input: input,
                classifier: StubChatClassifier(match: .init(kind: .weChat))
            )

            do {
                try await sender.sendOK()
                XCTFail("Expected draft rejection")
            } catch {
                XCTAssertEqual(error as? FocusedChatSendError, .existingDraft)
            }

            XCTAssertFalse(input.events.contains { $0.hasPrefix("write:") })
            XCTAssertEqual(input.returnCount, 0)
        }
    }

    func testCodexPlaceholderArtifactIsAcceptedAsEmpty() async throws {
        let input = FakeFocusedInput(value: "\nMessage Codex")
        let sender = FocusedChatApprovalSender(
            input: input,
            classifier: StubChatClassifier(
                match: .init(
                    kind: .codex,
                    placeholderDescription: "Message Codex"
                )
            )
        )

        try await sender.sendOK()

        XCTAssertEqual(input.returnCount, 1)
    }

    func testClassificationFailureNeverReadsWritesOrReturns() async {
        let input = FakeFocusedInput(value: "")
        let sender = FocusedChatApprovalSender(
            input: input,
            classifier: StubChatClassifier(error: .unsupportedInputContext)
        )

        do {
            try await sender.sendOK()
            XCTFail("Expected classification rejection")
        } catch {}

        XCTAssertEqual(input.events, ["capture"])
        XCTAssertEqual(input.returnCount, 0)
    }

    func testTargetChangeBeforeWriteAndBeforeReturnNeverReturns() async {
        for failingRevalidation in [1, 2] {
            let input = FakeFocusedInput(value: "")
            input.failRevalidation = failingRevalidation
            let sender = FocusedChatApprovalSender(
                input: input,
                classifier: StubChatClassifier(match: .init(kind: .generic))
            )

            do {
                try await sender.sendOK()
                XCTFail("Expected target change")
            } catch {}

            XCTAssertEqual(input.returnCount, 0)
        }
    }

    func testWriteMismatchDoesNotReturn() async {
        let input = FakeFocusedInput(value: "")
        input.waitError = AccessibilityClient.AXError.insertedValueMismatch
        let sender = FocusedChatApprovalSender(
            input: input,
            classifier: StubChatClassifier(match: .init(kind: .generic))
        )

        do {
            try await sender.sendOK()
            XCTFail("Expected inserted value mismatch")
        } catch {}

        XCTAssertEqual(input.returnAttempts, 0)
    }

    func testReturnFailureDoesNotRetry() async {
        let input = FakeFocusedInput(value: "")
        input.returnError = AccessibilityClient.AXError.returnDeliveryFailed
        let sender = FocusedChatApprovalSender(
            input: input,
            classifier: StubChatClassifier(match: .init(kind: .generic))
        )

        do {
            try await sender.sendOK()
            XCTFail("Expected Return failure")
        } catch {}

        XCTAssertEqual(input.returnAttempts, 1)
        XCTAssertEqual(input.returnCount, 0)
    }

    func testDuplicateInFlightCallAllowsOnlyFirstSend() async throws {
        let input = FakeFocusedInput(value: "")
        let gate = FocusedSenderGate()
        input.waitGate = { await gate.wait() }
        let sender = FocusedChatApprovalSender(
            input: input,
            classifier: StubChatClassifier(match: .init(kind: .generic))
        )
        let first = Task { try await sender.sendOK() }
        await waitUntilFocusedSender {
            input.events.contains("wait:可:0.5")
        }

        do {
            try await sender.sendOK()
            XCTFail("Expected in-progress rejection")
        } catch {
            XCTAssertEqual(error as? FocusedChatSendError, .inProgress)
        }

        gate.release()
        try await first.value
        XCTAssertEqual(input.returnCount, 1)
    }
}

private final class StubChatClassifier: ChatTargetClassifying {
    private let result: Result<ChatTargetMatch, ChatTargetClassificationError>

    init(match: ChatTargetMatch) {
        result = .success(match)
    }

    init(error: ChatTargetClassificationError) {
        result = .failure(error)
    }

    func classify(
        bundleIdentifier: String,
        context: FocusedChatContext
    ) throws -> ChatTargetMatch {
        try result.get()
    }
}

@MainActor
private final class FakeFocusedInput: FocusedInputControlling {
    let window = NSObject()
    let element = NSObject()
    var value: String
    var events: [String] = []
    var failRevalidation: Int?
    var waitError: Error?
    var returnError: Error?
    var waitGate: (() async throws -> Void)?
    private(set) var returnAttempts = 0
    private(set) var returnCount = 0
    private var revalidationCount = 0

    init(value: String) {
        self.value = value
    }

    func captureTarget() throws -> FocusedTargetSnapshot {
        events.append("capture")
        return FocusedTargetSnapshot(
            processIdentifier: 91,
            bundleIdentifier: "example.chat",
            window: window,
            element: element,
            context: FocusedChatContext(
                focused: ChatElementSummary(
                    role: "AXTextArea",
                    subrole: nil,
                    title: nil,
                    description: "Write a message",
                    enabled: true,
                    valueSettable: true
                ),
                ancestors: [],
                nearby: []
            )
        )
    }

    func revalidate(_ target: FocusedTargetSnapshot) throws {
        revalidationCount += 1
        events.append("revalidate")
        if failRevalidation == revalidationCount {
            throw AccessibilityClient.AXError.targetChanged
        }
    }

    func composerValue(in target: FocusedTargetSnapshot) throws -> String {
        events.append("read")
        return value
    }

    func setComposerValue(
        _ value: String,
        in target: FocusedTargetSnapshot
    ) throws {
        events.append("write:\(value)")
        self.value = value
    }

    func waitUntilComposerValue(
        _ expected: String,
        in target: FocusedTargetSnapshot,
        timeout: TimeInterval
    ) async throws {
        events.append("wait:\(expected):\(timeout)")
        try await waitGate?()
        if let waitError { throw waitError }
        guard value == expected else {
            throw AccessibilityClient.AXError.insertedValueMismatch
        }
    }

    func pressReturn(in target: FocusedTargetSnapshot) throws {
        events.append("return")
        returnAttempts += 1
        if let returnError { throw returnError }
        returnCount += 1
    }
}

@MainActor
private final class FocusedSenderGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private func waitUntilFocusedSender(
    _ condition: @escaping @MainActor () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    for _ in 0..<1_000 {
        if condition() { return }
        await Task.yield()
    }
    XCTFail("Condition was not met", file: file, line: line)
}
