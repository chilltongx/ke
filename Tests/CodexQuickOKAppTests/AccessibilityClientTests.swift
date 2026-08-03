import AppKit
import ApplicationServices
import Foundation
import XCTest
@testable import CodexQuickOKApp

@MainActor
final class AccessibilityClientTests: XCTestCase {
    func testMergesNavigationOrderChildrenMissingFromRegularTree() {
        let shell = NSObject()
        let webArea = NSObject()

        let children = AccessibilityClient.mergedChildren(
            regular: [shell],
            navigationOrder: [shell, webArea],
            areEqual: { $0 === $1 }
        )

        XCTAssertEqual(children.count, 2)
        XCTAssertTrue(children[0] === shell)
        XCTAssertTrue(children[1] === webArea)
    }

    func testSelectsComposerInsideOnlyDeepestMainRegion() throws {
        let elements = [
            summary(parent: nil, role: "AXWindow"),
            summary(parent: 0, role: "AXTextField", valueSettable: true),
            summary(parent: 0, role: "AXGroup", subrole: "AXLandmarkMain"),
            summary(parent: 2, role: "AXTextArea", value: "", valueSettable: true),
            summary(parent: 2, role: "AXButton", title: "Send", enabled: false),
        ]

        XCTAssertEqual(
            try AccessibilityClient.selectFocusedConversationControls(in: elements),
            .init(composerIndex: 3, sendButtonIndex: 4)
        )
    }

    func testSelectsEnabledQueueActionAsSendControl() throws {
        let controls = try AccessibilityClient.selectControls(in: [
            summary(
                parent: nil,
                role: "AXTextArea",
                enabled: true,
                valueSettable: true
            ),
            .init(
                role: "AXButton",
                title: "",
                description: "加入队列",
                enabled: true,
                valueSettable: false
            ),
        ])

        XCTAssertEqual(controls.composerIndex, 0)
        XCTAssertEqual(controls.sendButtonIndex, 1)
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
        for value: Any? in [nil, NSNumber(value: 0)] {
            XCTAssertThrowsError(
                try AccessibilityClient.validatedComposerValue(
                    attributeReadSucceeded: value != nil,
                    value: value
                )
            ) { error in
                XCTAssertEqual(
                    error as? AccessibilityClient.AXError,
                    .composerValueUnreadable
                )
            }
        }
    }

    func testChildReadFailureAndWrongChildrenTypeFailClosed() async {
        let system = FakeAccessibilitySystem.validConversation(pid: 41)
        system.childrenErrorNode = system.root
        let client = AccessibilityClient(system: system)

        await assertPrepareFails(client, as: .invalidAccessibilityTree)

        XCTAssertThrowsError(
            try AccessibilityClient.validatedChildren(
                AccessibilityClient.AttributeRead.value("not children")
            )
        ) { error in
            XCTAssertEqual(error as? AccessibilityClient.AXError, .invalidAccessibilityTree)
        }
        XCTAssertThrowsError(
            try AccessibilityClient.validatedChildren(
                AccessibilityClient.AttributeRead.value([NSString(string: "not AX")])
            )
        ) { error in
            XCTAssertEqual(error as? AccessibilityClient.AXError, .invalidAccessibilityTree)
        }
    }

    func testUnreadableEnabledAndInvalidRequiredSummaryFailClosed() {
        XCTAssertThrowsError(
            try AccessibilityClient.validatedSummary(
                parentIndex: nil,
                role: .value("AXButton"),
                subrole: .absent,
                title: .value("Send"),
                description: .absent,
                value: .absent,
                enabled: .failure,
                valueSettable: .value(false)
            )
        ) { error in
            XCTAssertEqual(error as? AccessibilityClient.AXError, .invalidAccessibilityTree)
        }
        XCTAssertThrowsError(
            try AccessibilityClient.validatedSummary(
                parentIndex: nil,
                role: .value(7),
                subrole: .absent,
                title: .absent,
                description: .absent,
                value: .absent,
                enabled: .value(true),
                valueSettable: .value(false)
            )
        ) { error in
            XCTAssertEqual(error as? AccessibilityClient.AXError, .invalidAccessibilityTree)
        }
    }

    func testContainerMayOmitEnabledButInteractiveControlMayNot() throws {
        let container = try AccessibilityClient.validatedSummary(
            parentIndex: nil,
            role: .value("AXGroup"),
            subrole: .absent,
            title: .absent,
            description: .absent,
            value: .absent,
            enabled: .absent,
            valueSettable: .value(false)
        )

        XCTAssertEqual(container.role, "AXGroup")
        XCTAssertFalse(container.enabled)

        XCTAssertThrowsError(
            try AccessibilityClient.validatedSummary(
                parentIndex: nil,
                role: .value("AXButton"),
                subrole: .absent,
                title: .value("Send"),
                description: .absent,
                value: .absent,
                enabled: .absent,
                valueSettable: .value(false)
            )
        ) { error in
            XCTAssertEqual(
                error as? AccessibilityClient.AXError,
                .invalidAccessibilityTree
            )
        }
    }

    func testSummaryReadFailureAndNodeLimitFailClosedWithoutPartialSelection() async {
        let invalid = FakeAccessibilitySystem.validConversation(pid: 42)
        invalid.summaryErrorNode = invalid.sendButton
        await assertPrepareFails(
            AccessibilityClient(system: invalid),
            as: .invalidAccessibilityTree
        )

        let truncated = FakeAccessibilitySystem(pid: 43)
        truncated.makeFlatTree(childCount: AccessibilityClient.maximumElementCount)
        await assertPrepareFails(
            AccessibilityClient(system: truncated),
            as: .accessibilityTreeTruncated
        )
    }

    func testActivationWaitsForExactPIDAndUsesItForFocusedWindow() async throws {
        let system = FakeAccessibilitySystem.validConversation(pid: 51)
        system.frontmostPID = 999
        system.frontmostPIDsAfterSleeps = [999, 51]
        let client = AccessibilityClient(system: system, pollInterval: 0.01)

        try await client.prepareFocusedConversation(timeout: 0.05)

        XCTAssertEqual(system.activationRequests, [51])
        XCTAssertEqual(system.focusedWindowPIDs, [51])
        XCTAssertEqual(system.sleepCount, 2)
    }

    func testActivationRejectsNoOrMultipleCodexInstancesAndTimesOut() async {
        let absent = FakeAccessibilitySystem(pid: nil)
        await assertPrepareFails(
            AccessibilityClient(system: absent, pollInterval: 0.01),
            as: .codexNotRunning
        )

        let multiple = FakeAccessibilitySystem(pid: 61)
        multiple.runningPIDs = [61, 62]
        await assertPrepareFails(
            AccessibilityClient(system: multiple, pollInterval: 0.01),
            as: .ambiguousApplication
        )

        let timeout = FakeAccessibilitySystem.validConversation(pid: 63)
        timeout.frontmostPID = 999
        await assertPrepareFails(
            AccessibilityClient(system: timeout, pollInterval: 0.01),
            timeout: 0.02,
            as: .activationTimedOut
        )
        XCTAssertLessThanOrEqual(timeout.sleepCount, 2)
    }

    func testFrontmostSwitchBeforeMutationAndSendFailsClosed() async throws {
        let system = FakeAccessibilitySystem.validConversation(pid: 71)
        let client = AccessibilityClient(system: system)
        try await client.prepareFocusedConversation(timeout: 0.1)

        system.frontmostPID = 999

        XCTAssertThrowsError(try client.setComposerValue("\u{53ef}")) { error in
            XCTAssertEqual(error as? AccessibilityClient.AXError, .targetApplicationChanged)
        }
        XCTAssertThrowsError(try client.pressSend()) { error in
            XCTAssertEqual(error as? AccessibilityClient.AXError, .targetApplicationChanged)
        }
        XCTAssertEqual(system.writtenValues, [])
        XCTAssertEqual(system.pressCount, 0)
    }

    func testDisabledSendBecomesEnabledAfterExactComposerWrite() async throws {
        let system = FakeAccessibilitySystem.validConversation(pid: 72)
        system.setSendEnabled(false)
        system.sendEnabledAfterSleeps = [false, true]
        let client = AccessibilityClient(system: system, pollInterval: 0.01)

        try await client.prepareFocusedConversation(timeout: 0.05)
        try client.setComposerValue("可")
        try await client.waitUntilSendEnabled(timeout: 0.03)
        try client.pressSend()

        XCTAssertEqual(system.writtenValues, ["可"])
        XCTAssertEqual(system.sleepCount, 2)
        XCTAssertEqual(system.pressCount, 1)
    }

    func testSendMayAppearOnlyAfterComposerWrite() async throws {
        let system = FakeAccessibilitySystem.validConversation(pid: 721)
        system.setSendPresent(false)
        let client = AccessibilityClient(system: system, pollInterval: 0.01)

        try await client.prepareFocusedConversation(timeout: 0.02)
        try client.setComposerValue("可")
        system.setSendPresent(true)
        try await client.waitUntilSendEnabled(timeout: 0.02)
        try client.pressSend()

        XCTAssertEqual(system.writtenValues, ["可"])
        XCTAssertEqual(system.pressCount, 1)
    }

    func testPlaceholderArtifactIsEmptyRegardlessOfSendControlAvailability() async throws {
        let system = FakeAccessibilitySystem.validConversation(pid: 722)
        system.storedComposerValue = "\n随心输入"
        system.setComposerDescription("随心输入")
        system.setSendPresent(false)
        let client = AccessibilityClient(system: system)

        try await client.prepareFocusedConversation(timeout: 0.02)
        XCTAssertEqual(try client.composerValue(), "")

        system.setSendPresent(true)
        system.setSendEnabled(false)
        XCTAssertEqual(try client.composerValue(), "")

        system.setSendEnabled(true)
        XCTAssertEqual(try client.composerValue(), "")
    }

    func testNeverEnabledSendTimesOutWithoutPressing() async throws {
        let system = FakeAccessibilitySystem.validConversation(pid: 73)
        system.setSendEnabled(false)
        let client = AccessibilityClient(system: system, pollInterval: 0.01)

        try await client.prepareFocusedConversation(timeout: 0.05)
        try client.setComposerValue("可")
        do {
            try await client.waitUntilSendEnabled(timeout: 0.02)
            XCTFail("Expected send enable timeout")
        } catch {
            XCTAssertEqual(error as? AccessibilityClient.AXError, .sendActionTimedOut)
        }

        XCTAssertLessThanOrEqual(system.sleepCount, 2)
        XCTAssertEqual(system.pressCount, 0)
    }

    func testSamePIDFocusedWindowSwitchFailsEveryCachedControlOperation() async throws {
        let system = FakeAccessibilitySystem.validConversation(pid: 74)
        let client = AccessibilityClient(system: system, pollInterval: 0.01)
        try await client.prepareFocusedConversation(timeout: 0.05)

        system.focusedWindowNode = system.alternateWindow

        XCTAssertThrowsError(try client.composerValue()) { error in
            XCTAssertEqual(error as? AccessibilityClient.AXError, .targetApplicationChanged)
        }
        XCTAssertThrowsError(try client.setComposerValue("可")) { error in
            XCTAssertEqual(error as? AccessibilityClient.AXError, .targetApplicationChanged)
        }
        do {
            try await client.waitUntilSendEnabled(timeout: 0.01)
            XCTFail("Expected focused-window revalidation failure")
        } catch {
            XCTAssertEqual(error as? AccessibilityClient.AXError, .targetApplicationChanged)
        }
        XCTAssertThrowsError(try client.pressSend()) { error in
            XCTAssertEqual(error as? AccessibilityClient.AXError, .targetApplicationChanged)
        }
        XCTAssertEqual(system.writtenValues, [])
        XCTAssertEqual(system.pressCount, 0)
    }

    private func assertPrepareFails(
        _ client: AccessibilityClient,
        timeout: TimeInterval = 0.1,
        as expected: AccessibilityClient.AXError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await client.prepareFocusedConversation(timeout: timeout)
            XCTFail("Expected preparation failure", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AccessibilityClient.AXError, expected, file: file, line: line)
        }
    }

    private func summary(
        parent: Int?,
        role: String,
        subrole: String? = nil,
        title: String? = nil,
        value: String? = nil,
        enabled: Bool = true,
        valueSettable: Bool = false
    ) -> AccessibilityClient.ElementSummary {
        .init(
            parentIndex: parent,
            role: role,
            subrole: subrole,
            title: title,
            description: nil,
            value: value,
            enabled: enabled,
            valueSettable: valueSettable
        )
    }
}

@MainActor
private final class FakeAccessibilitySystem: AccessibilitySystemProviding {
    final class Node: NSObject {}

    var isProcessTrusted = true
    var runningPIDs: [pid_t]
    var frontmostPID: pid_t?
    var frontmostBundleIdentifier: String? = "com.openai.codex"
    var frontmostPIDsAfterSleeps: [pid_t?] = []
    var sendEnabledAfterSleeps: [Bool] = []
    var activationSucceeds = true
    private(set) var activationRequests: [pid_t] = []
    private(set) var focusedWindowPIDs: [pid_t] = []
    private(set) var sleepCount = 0
    private(set) var writtenValues: [String] = []
    private(set) var pressCount = 0
    var storedComposerValue = ""

    let root = Node()
    let alternateWindow = Node()
    let main = Node()
    let composer = Node()
    let sendButton = Node()
    var focusedWindowNode: Node?
    var childrenErrorNode: Node?
    var summaryErrorNode: Node?
    private var childrenByNode: [ObjectIdentifier: [Node]] = [:]
    private var summariesByNode: [ObjectIdentifier: AccessibilityClient.ElementSummary] = [:]

    init(pid: pid_t?) {
        runningPIDs = pid.map { [$0] } ?? []
        frontmostPID = pid
        focusedWindowNode = root
    }

    static func validConversation(pid: pid_t) -> FakeAccessibilitySystem {
        let system = FakeAccessibilitySystem(pid: pid)
        system.childrenByNode[ObjectIdentifier(system.root)] = [system.main]
        system.childrenByNode[ObjectIdentifier(system.main)] = [system.composer, system.sendButton]
        system.childrenByNode[ObjectIdentifier(system.composer)] = []
        system.childrenByNode[ObjectIdentifier(system.sendButton)] = []
        system.summariesByNode[ObjectIdentifier(system.root)] = system.makeSummary(role: "AXWindow")
        system.summariesByNode[ObjectIdentifier(system.main)] = system.makeSummary(
            role: "AXGroup",
            subrole: "AXLandmarkMain"
        )
        system.summariesByNode[ObjectIdentifier(system.composer)] = system.makeSummary(
            role: "AXTextArea",
            value: "",
            valueSettable: true
        )
        system.summariesByNode[ObjectIdentifier(system.sendButton)] = system.makeSummary(
            role: "AXButton",
            title: "Send"
        )
        return system
    }

    func makeFlatTree(childCount: Int) {
        let children = (0..<childCount).map { _ in Node() }
        childrenByNode[ObjectIdentifier(root)] = children
        summariesByNode[ObjectIdentifier(root)] = makeSummary(role: "AXWindow")
        for child in children {
            childrenByNode[ObjectIdentifier(child)] = []
            summariesByNode[ObjectIdentifier(child)] = makeSummary(role: "AXGroup")
        }
    }

    func runningApplications(bundleIdentifier: String) -> [AccessibilityClient.RunningApplication] {
        runningPIDs.map { .init(processIdentifier: $0) }
    }

    func activate(processIdentifier: pid_t) -> Bool {
        activationRequests.append(processIdentifier)
        return activationSucceeds
    }

    func focusedWindow(processIdentifier: pid_t) throws -> AnyObject {
        focusedWindowPIDs.append(processIdentifier)
        return focusedWindowNode ?? root
    }

    func elementsAreEqual(_ lhs: AnyObject, _ rhs: AnyObject) -> Bool {
        lhs === rhs
    }

    func children(of element: AnyObject) throws -> [AnyObject] {
        let node = element as! Node
        if node === childrenErrorNode {
            throw AccessibilityClient.AXError.invalidAccessibilityTree
        }
        return childrenByNode[ObjectIdentifier(node)] ?? []
    }

    func summary(
        of element: AnyObject,
        parentIndex: Int?
    ) throws -> AccessibilityClient.ElementSummary {
        let node = element as! Node
        if node === summaryErrorNode {
            throw AccessibilityClient.AXError.invalidAccessibilityTree
        }
        guard let summary = summariesByNode[ObjectIdentifier(node)] else {
            throw AccessibilityClient.AXError.invalidAccessibilityTree
        }
        return .init(
            parentIndex: parentIndex,
            role: summary.role,
            subrole: summary.subrole,
            title: summary.title,
            description: summary.description,
            value: summary.value,
            enabled: summary.enabled,
            valueSettable: summary.valueSettable
        )
    }

    func composerValue(of element: AnyObject) throws -> String {
        storedComposerValue
    }

    func setComposerValue(_ value: String, on element: AnyObject) throws {
        writtenValues.append(value)
        storedComposerValue = value
    }

    func press(_ element: AnyObject) throws {
        pressCount += 1
    }

    func sleep(for interval: TimeInterval) async throws {
        sleepCount += 1
        if !frontmostPIDsAfterSleeps.isEmpty {
            frontmostPID = frontmostPIDsAfterSleeps.removeFirst()
        }
        if !sendEnabledAfterSleeps.isEmpty {
            setSendEnabled(sendEnabledAfterSleeps.removeFirst())
        }
    }

    func setSendEnabled(_ enabled: Bool) {
        summariesByNode[ObjectIdentifier(sendButton)] = makeSummary(
            role: "AXButton",
            title: "Send",
            enabled: enabled
        )
    }

    func setSendPresent(_ present: Bool) {
        childrenByNode[ObjectIdentifier(main)] = present
            ? [composer, sendButton]
            : [composer]
    }

    func setComposerDescription(_ description: String?) {
        summariesByNode[ObjectIdentifier(composer)] = makeSummary(
            role: "AXTextArea",
            description: description,
            valueSettable: true
        )
    }

    private func makeSummary(
        role: String,
        subrole: String? = nil,
        title: String? = nil,
        description: String? = nil,
        value: String? = nil,
        enabled: Bool = true,
        valueSettable: Bool = false
    ) -> AccessibilityClient.ElementSummary {
        .init(
            role: role,
            subrole: subrole,
            title: title,
            description: description,
            value: value,
            enabled: enabled,
            valueSettable: valueSettable
        )
    }
}
