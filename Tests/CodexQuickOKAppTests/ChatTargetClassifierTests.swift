import XCTest

@testable import CodexQuickOKApp

final class ChatTargetClassifierTests: XCTestCase {
    private let classifier = ChatTargetClassifier()

    func testCodexMainComposerIsAcceptedAndPlaceholderIsNormalized() throws {
        let context = makeContext(
            focused: field(description: "Message Codex"),
            ancestors: [node(subrole: "AXLandmarkMain", title: "Conversation")]
        )

        let match = try classifier.classify(
            bundleIdentifier: "com.openai.codex",
            context: context
        )

        XCTAssertEqual(match.kind, .codex)
        XCTAssertEqual(match.normalizedComposerValue("\nMessage Codex"), "")
        XCTAssertEqual(match.normalizedComposerValue("draft"), "draft")
    }

    func testCodexNonConversationInputIsRejected() {
        XCTAssertThrowsError(
            try classifier.classify(
                bundleIdentifier: "com.openai.codex",
                context: makeContext(focused: field(title: "Notes"))
            )
        )
    }

    func testCodexNativeApprovalContextIsRejected() {
        let context = makeContext(
            focused: field(description: "Message Codex"),
            ancestors: [node(subrole: "AXLandmarkMain")],
            nearby: [node(role: "AXButton", title: "Approve")]
        )

        XCTAssertThrowsError(
            try classifier.classify(
                bundleIdentifier: "com.openai.codex",
                context: context
            )
        )
    }

    func testVSCodeChatIsAccepted() throws {
        let match = try classifier.classify(
            bundleIdentifier: "com.microsoft.VSCode",
            context: makeContext(
                focused: field(description: "Chat input"),
                ancestors: [node(title: "Chat")]
            )
        )

        XCTAssertEqual(match.kind, .visualStudioCode)
    }

    func testVSCodeNonChatInputsAreRejected() {
        for label in [
            "Text Editor", "Terminal", "Search", "Source Control", "Command Palette",
        ] {
            XCTAssertThrowsError(
                try classifier.classify(
                    bundleIdentifier: "com.microsoft.VSCode",
                    context: makeContext(focused: field(title: label))
                ),
                "Expected \(label) to be rejected"
            )
        }
    }

    func testWeChatMessageEditorIsAccepted() throws {
        let match = try classifier.classify(
            bundleIdentifier: "com.tencent.xinWeChat",
            context: makeContext(
                focused: field(role: "AXTextArea"),
                nearby: [node(role: "AXButton", title: "发送")]
            )
        )

        XCTAssertEqual(match.kind, .weChat)
    }

    func testWeChatSearchIsRejected() {
        XCTAssertThrowsError(
            try classifier.classify(
                bundleIdentifier: "com.tencent.xinWeChat",
                context: makeContext(
                    focused: field(role: "AXTextField", title: "搜索")
                )
            )
        )
    }

    func testKnownAdapterRejectionDoesNotFallBackToGenericSendEvidence() {
        let editorWithSend = makeContext(
            focused: field(title: "Text Editor"),
            ancestors: [node(title: "Conversation")],
            nearby: [node(role: "AXButton", title: "Send")]
        )

        XCTAssertThrowsError(
            try classifier.classify(
                bundleIdentifier: "com.microsoft.VSCode",
                context: editorWithSend
            )
        )
    }

    func testGenericChatNeedsStrongConversationEvidence() throws {
        let chat = makeContext(
            focused: field(description: "Write a message"),
            ancestors: [node(title: "Conversation")],
            nearby: [node(role: "AXButton", title: "Send")]
        )
        XCTAssertEqual(
            try classifier.classify(
                bundleIdentifier: "example.chat",
                context: chat
            ).kind,
            .generic
        )

        let contactForm = makeContext(
            focused: field(description: "Message"),
            nearby: [node(role: "AXButton", title: "Send")]
        )
        XCTAssertThrowsError(
            try classifier.classify(
                bundleIdentifier: "example.form",
                context: contactForm
            )
        )
    }

    func testDisabledReadonlySecureAndDeniedControlsAreRejected() {
        let contexts = [
            makeContext(focused: field(enabled: false)),
            makeContext(focused: field(valueSettable: false)),
            makeContext(focused: field(subrole: "AXSecureTextField")),
            makeContext(focused: field(title: "Terminal chat message")),
            makeContext(focused: field(title: "Username for chat")),
        ]

        for context in contexts {
            XCTAssertThrowsError(
                try classifier.classify(
                    bundleIdentifier: "example.chat",
                    context: context
                )
            )
        }
    }

    private func makeContext(
        focused: ChatElementSummary,
        ancestors: [ChatElementSummary] = [],
        nearby: [ChatElementSummary] = []
    ) -> FocusedChatContext {
        FocusedChatContext(
            focused: focused,
            ancestors: ancestors,
            nearby: nearby
        )
    }

    private func field(
        role: String = "AXTextArea",
        subrole: String? = nil,
        title: String? = nil,
        description: String? = nil,
        enabled: Bool = true,
        valueSettable: Bool = true
    ) -> ChatElementSummary {
        node(
            role: role,
            subrole: subrole,
            title: title,
            description: description,
            enabled: enabled,
            valueSettable: valueSettable
        )
    }

    private func node(
        role: String = "AXGroup",
        subrole: String? = nil,
        title: String? = nil,
        description: String? = nil,
        enabled: Bool = true,
        valueSettable: Bool = false
    ) -> ChatElementSummary {
        ChatElementSummary(
            role: role,
            subrole: subrole,
            title: title,
            description: description,
            enabled: enabled,
            valueSettable: valueSettable
        )
    }
}
