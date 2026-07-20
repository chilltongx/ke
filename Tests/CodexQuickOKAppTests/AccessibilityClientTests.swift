import AppKit
import XCTest
@testable import CodexQuickOKApp

@MainActor
final class AccessibilityClientTests: XCTestCase {
    func testSelectsComposerInsideOnlyDeepestMainRegion() throws {
        let elements = [
            summary(parent: nil, role: "AXWindow"),
            summary(parent: 0, role: "AXTextField", valueSettable: true),
            summary(parent: 0, role: "AXGroup", subrole: "AXLandmarkMain"),
            summary(parent: 2, role: "AXTextArea", value: "", valueSettable: true),
            summary(parent: 2, role: "AXButton", title: "Send"),
        ]

        XCTAssertEqual(
            try AccessibilityClient.selectFocusedConversationControls(in: elements),
            .init(composerIndex: 3, sendButtonIndex: 4)
        )
    }

    func testRejectsTwoMainRegionsWithComposers() {
        let elements = [
            summary(parent: nil, role: "AXWindow"),
            summary(parent: 0, role: "AXGroup", subrole: "AXLandmarkMain"),
            summary(parent: 1, role: "AXTextArea", value: "", valueSettable: true),
            summary(parent: 1, role: "AXButton", title: "Send"),
            summary(parent: 0, role: "AXGroup", subrole: "AXLandmarkMain"),
            summary(parent: 4, role: "AXTextArea", value: "", valueSettable: true),
            summary(parent: 4, role: "AXButton", title: "Send"),
        ]

        XCTAssertThrowsError(
            try AccessibilityClient.selectFocusedConversationControls(in: elements)
        ) { error in
            XCTAssertEqual(error as? AccessibilityClient.AXError, .ambiguousTask)
        }
    }

    func testRejectsNativeApprovalCardInCurrentConversation() {
        let elements = [
            summary(parent: nil, role: "AXWindow"),
            summary(parent: 0, role: "AXGroup", subrole: "AXLandmarkMain"),
            summary(parent: 1, role: "AXTextArea", value: "", valueSettable: true),
            summary(parent: 1, role: "AXButton", title: "Approve once"),
            summary(parent: 1, role: "AXButton", title: "Send"),
        ]

        XCTAssertThrowsError(
            try AccessibilityClient.selectFocusedConversationControls(in: elements)
        ) { error in
            XCTAssertEqual(error as? AccessibilityClient.AXError, .nativeApprovalCard)
        }
    }

    func testUnreadableOrNonStringComposerValueFailsClosed() {
        XCTAssertThrowsError(
            try AccessibilityClient.validatedComposerValue(
                attributeReadSucceeded: false,
                value: nil
            )
        ) { error in
            XCTAssertEqual(
                error as? AccessibilityClient.AXError,
                .composerValueUnreadable
            )
        }
        XCTAssertThrowsError(
            try AccessibilityClient.validatedComposerValue(
                attributeReadSucceeded: true,
                value: nil
            )
        ) { error in
            XCTAssertEqual(
                error as? AccessibilityClient.AXError,
                .composerValueUnreadable
            )
        }
        XCTAssertThrowsError(
            try AccessibilityClient.validatedComposerValue(
                attributeReadSucceeded: true,
                value: NSNumber(value: 0)
            )
        ) { error in
            XCTAssertEqual(
                error as? AccessibilityClient.AXError,
                .composerValueUnreadable
            )
        }
    }

    private func summary(
        parent: Int?,
        role: String,
        subrole: String? = nil,
        title: String? = nil,
        value: String? = nil,
        valueSettable: Bool = false
    ) -> AccessibilityClient.ElementSummary {
        .init(
            parentIndex: parent,
            role: role,
            subrole: subrole,
            title: title,
            description: nil,
            value: value,
            enabled: true,
            valueSettable: valueSettable
        )
    }
}
