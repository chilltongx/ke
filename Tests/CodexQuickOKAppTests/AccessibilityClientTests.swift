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

    func testSuccessfulNilComposerValueIsEmptyButUnreadableOrNonStringFails() throws {
        XCTAssertEqual(
            try AccessibilityClient.validatedComposerValue(
                attributeReadSucceeded: true,
                value: nil
            ),
            ""
        )
        for (readSucceeded, value): (Bool, Any?) in [
            (false, nil),
            (true, NSNumber(value: 0)),
        ] {
            XCTAssertThrowsError(
                try AccessibilityClient.validatedComposerValue(
                    attributeReadSucceeded: readSucceeded,
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

    func testInvalidChildrenFailClosed() {
        for read in [
            AccessibilityClient.AttributeRead.failure,
            .value("not children"),
            .value([NSString(string: "not AX")]),
        ] {
            XCTAssertThrowsError(
                try AccessibilityClient.validatedChildren(read)
            ) { error in
                XCTAssertEqual(
                    error as? AccessibilityClient.AXError,
                    .invalidAccessibilityTree
                )
            }
        }
    }

    func testUnreadableInteractiveSummaryFailsClosed() {
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
            XCTAssertEqual(
                error as? AccessibilityClient.AXError,
                .invalidAccessibilityTree
            )
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

        XCTAssertFalse(container.enabled)
        XCTAssertThrowsError(
            try AccessibilityClient.validatedSummary(
                parentIndex: nil,
                role: .value("AXTextArea"),
                subrole: .absent,
                title: .absent,
                description: .absent,
                value: .absent,
                enabled: .absent,
                valueSettable: .value(true)
            )
        )
    }

    func testCapturesFrontmostFocusedElementAndContext() throws {
        let system = FakeAccessibilitySystem.validConversation(pid: 81)
        system.frontmostBundleIdentifier = "com.microsoft.VSCode"
        let client = AccessibilityClient(system: system, pollInterval: 0.01)

        let target = try client.captureTarget()

        XCTAssertEqual(target.processIdentifier, 81)
        XCTAssertEqual(target.bundleIdentifier, "com.microsoft.VSCode")
        XCTAssertTrue(system.elementsAreEqual(target.element, system.composer))
        XCTAssertEqual(target.context.focused.role, "AXTextArea")
        XCTAssertEqual(target.context.ancestors.map(\.role), ["AXGroup", "AXWindow"])
        XCTAssertTrue(target.context.nearby.contains { $0.title == "Send" })
    }

    func testCaptureFallsBackToFocusedDescendantWhenAppOmitsFocusedElement() throws {
        let system = FakeAccessibilitySystem.validConversation(pid: 810)
        system.focusedElementNode = nil
        system.composer.isFocused = true
        let client = AccessibilityClient(system: system)

        let target = try client.captureTarget()

        XCTAssertTrue(system.elementsAreEqual(target.element, system.composer))
    }

    func testRevalidateUsesFocusedDescendantFallback() throws {
        let system = FakeAccessibilitySystem.validConversation(pid: 8101)
        system.focusedElementNode = nil
        system.composer.isFocused = true
        let client = AccessibilityClient(system: system)
        let target = try client.captureTarget()

        XCTAssertNoThrow(try client.revalidate(target))
    }

    func testCaptureAcceptsComposerThirtyAncestorsBelowWindow() throws {
        let system = FakeAccessibilitySystem.validConversation(pid: 8102)
        system.nestComposer(parentDepth: 30)
        let client = AccessibilityClient(system: system)

        let target = try client.captureTarget()

        XCTAssertTrue(system.elementsAreEqual(target.element, system.composer))
        XCTAssertEqual(target.context.ancestors.count, 30)
    }

    func testCaptureReadsBoundedDescendantsFromAdjacentContainer() throws {
        let system = FakeAccessibilitySystem.validConversation(pid: 811)
        system.nestSendButtonBesideComposer()

        let target = try AccessibilityClient(system: system).captureTarget()

        XCTAssertTrue(target.context.nearby.contains { $0.title == "Send" })
    }

    func testCaptureRequiresAccessibilityPermission() {
        let system = FakeAccessibilitySystem.validConversation(pid: 812)
        system.isProcessTrusted = false

        XCTAssertThrowsError(
            try AccessibilityClient(system: system).captureTarget()
        ) { error in
            XCTAssertEqual(error as? AccessibilityClient.AXError, .permissionMissing)
        }
    }

    func testCaptureFailsWhenFocusedElementIsNotInsideFocusedWindow() {
        let system = FakeAccessibilitySystem.validConversation(pid: 82)
        let unrelated = FakeAccessibilitySystem.Node(processIdentifier: 82)
        system.registerDetachedInput(unrelated)
        system.focusedElementNode = unrelated

        XCTAssertThrowsError(
            try AccessibilityClient(system: system).captureTarget()
        ) { error in
            XCTAssertEqual(
                error as? AccessibilityClient.AXError,
                .focusedElementUnavailable
            )
        }
    }

    func testCaptureRejectsElementOwnedByAnotherPID() {
        let system = FakeAccessibilitySystem.validConversation(pid: 821)
        system.composer.processIdentifier = 999

        XCTAssertThrowsError(
            try AccessibilityClient(system: system).captureTarget()
        ) { error in
            XCTAssertEqual(
                error as? AccessibilityClient.AXError,
                .focusedElementUnavailable
            )
        }
    }

    func testChildAndSummaryReadFailuresFailClosed() {
        let childrenFailure = FakeAccessibilitySystem.validConversation(pid: 822)
        childrenFailure.childrenErrorNode = childrenFailure.root
        XCTAssertThrowsError(
            try AccessibilityClient(system: childrenFailure).captureTarget()
        ) { error in
            XCTAssertEqual(
                error as? AccessibilityClient.AXError,
                .invalidAccessibilityTree
            )
        }

        let summaryFailure = FakeAccessibilitySystem.validConversation(pid: 823)
        summaryFailure.summaryErrorNode = summaryFailure.sendButton
        XCTAssertThrowsError(
            try AccessibilityClient(system: summaryFailure).captureTarget()
        ) { error in
            XCTAssertEqual(
                error as? AccessibilityClient.AXError,
                .invalidAccessibilityTree
            )
        }
    }

    func testNearbyContextLimitFailsClosed() {
        let system = FakeAccessibilitySystem.validConversation(pid: 824)
        system.addNearbyNodes(
            count: AccessibilityClient.maximumNearbyElementCount + 1
        )

        XCTAssertThrowsError(
            try AccessibilityClient(system: system).captureTarget()
        ) { error in
            XCTAssertEqual(
                error as? AccessibilityClient.AXError,
                .accessibilityTreeTruncated
            )
        }
    }

    func testRevalidationRejectsPIDWindowAndElementChanges() throws {
        let system = FakeAccessibilitySystem.validConversation(pid: 83)
        let client = AccessibilityClient(system: system)
        let target = try client.captureTarget()

        system.frontmostPID = 84
        assertTargetChanged { try client.revalidate(target) }

        system.frontmostPID = 83
        system.focusedWindowNode = system.alternateWindow
        assertTargetChanged { try client.revalidate(target) }

        system.focusedWindowNode = system.root
        system.focusedElementNode = system.sendButton
        assertTargetChanged { try client.revalidate(target) }
    }

    func testWritesConfirmsAndPostsOneReturnToCapturedPID() async throws {
        let system = FakeAccessibilitySystem.validConversation(pid: 85)
        let client = AccessibilityClient(system: system, pollInterval: 0.01)
        let target = try client.captureTarget()

        try client.setComposerValue("可", in: target)
        try await client.waitUntilComposerValue("可", in: target, timeout: 0.02)
        try client.pressReturn(in: target)

        XCTAssertEqual(system.storedComposerValue, "可")
        XCTAssertEqual(system.returnPIDs, [85])
    }

    func testValueMismatchTimesOutWithoutPostingReturn() async throws {
        let system = FakeAccessibilitySystem.validConversation(pid: 86)
        system.ignoreComposerWrites = true
        let client = AccessibilityClient(system: system, pollInterval: 0.01)
        let target = try client.captureTarget()

        try client.setComposerValue("可", in: target)
        do {
            try await client.waitUntilComposerValue(
                "可",
                in: target,
                timeout: 0.01
            )
            XCTFail("Expected inserted value mismatch")
        } catch {
            XCTAssertEqual(
                error as? AccessibilityClient.AXError,
                .insertedValueMismatch
            )
        }
        XCTAssertEqual(system.returnPIDs, [])
    }

    func testCodexAutoFocusesComposerWhenNoElementIsFocused() throws {
        let system = FakeAccessibilitySystem.validConversation(pid: 870)
        system.focusedElementNode = nil
        system.composer.isFocused = false

        let target = try AccessibilityClient(system: system).captureTarget()

        XCTAssertTrue(system.elementsAreEqual(target.element, system.composer))
        XCTAssertEqual(system.focusAttempts.count, 1)
        XCTAssertTrue(system.focusAttempts[0] === system.composer)
    }

    func testCodexAutoFocusesComposerWhenButtonOwnsFocus() throws {
        let system = FakeAccessibilitySystem.validConversation(pid: 871)
        system.focusedElementNode = system.sendButton

        let target = try AccessibilityClient(system: system).captureTarget()

        XCTAssertTrue(system.elementsAreEqual(target.element, system.composer))
        XCTAssertTrue(system.focusAttempts.first === system.composer)
    }

    func testCodexAutoFocusUsesFirstEditableInputInTraversalOrder() throws {
        let system = FakeAccessibilitySystem.validConversation(pid: 872)
        let firstInput = system.addEditableInputBeforeComposer(
            title: "Unlabeled input"
        )
        system.focusedElementNode = nil

        let target = try AccessibilityClient(system: system).captureTarget()

        XCTAssertTrue(system.elementsAreEqual(target.element, firstInput))
        XCTAssertTrue(system.focusAttempts.first === firstInput)
    }

    func testExistingEditableFocusIsNeverReplaced() throws {
        let system = FakeAccessibilitySystem.validConversation(pid: 873)
        _ = system.addEditableInputBeforeComposer(title: "Earlier input")
        system.focusedElementNode = system.composer

        let target = try AccessibilityClient(system: system).captureTarget()

        XCTAssertTrue(system.elementsAreEqual(target.element, system.composer))
        XCTAssertTrue(system.focusAttempts.isEmpty)
    }

    func testNonCodexAppNeverAutoFocusesAnInput() {
        let system = FakeAccessibilitySystem.validConversation(pid: 874)
        system.frontmostBundleIdentifier = "com.microsoft.VSCode"
        system.focusedElementNode = nil
        system.composer.isFocused = false

        XCTAssertThrowsError(
            try AccessibilityClient(system: system).captureTarget()
        ) { error in
            XCTAssertEqual(
                error as? AccessibilityClient.AXError,
                .focusedElementUnavailable
            )
        }
        XCTAssertTrue(system.focusAttempts.isEmpty)
    }

    func testAutoFocusRequiresAssignmentToTakeEffect() {
        let system = FakeAccessibilitySystem.validConversation(pid: 875)
        system.focusedElementNode = system.sendButton
        system.ignoreFocusAssignment = true

        XCTAssertThrowsError(
            try AccessibilityClient(system: system).captureTarget()
        ) { error in
            XCTAssertEqual(
                error as? AccessibilityClient.AXError,
                .targetChanged
            )
        }
        XCTAssertEqual(system.focusAttempts.count, 1)
    }

    func testAutoFocusPropagatesAssignmentFailure() {
        let system = FakeAccessibilitySystem.validConversation(pid: 876)
        system.focusedElementNode = system.sendButton
        system.focusError = AccessibilityClient.AXError.focusedElementUnavailable

        XCTAssertThrowsError(
            try AccessibilityClient(system: system).captureTarget()
        ) { error in
            XCTAssertEqual(
                error as? AccessibilityClient.AXError,
                .focusedElementUnavailable
            )
        }
        XCTAssertEqual(system.focusAttempts.count, 1)
    }

    func testAutoFocusRejectsWindowChangeDuringAssignment() {
        let system = FakeAccessibilitySystem.validConversation(pid: 877)
        system.focusedElementNode = system.sendButton
        system.afterFocusAttempt = {
            system.focusedWindowNode = system.alternateWindow
        }

        XCTAssertThrowsError(
            try AccessibilityClient(system: system).captureTarget()
        ) { error in
            XCTAssertEqual(
                error as? AccessibilityClient.AXError,
                .targetChanged
            )
        }
    }

    func testAutoFocusScanStopsAtElementLimit() {
        let system = FakeAccessibilitySystem.validConversation(pid: 878)
        system.focusedElementNode = system.root
        system.replaceWindowChildrenWithNonEditableNodes(
            count: AccessibilityClient.maximumFocusedElementScanCount + 1
        )

        XCTAssertThrowsError(
            try AccessibilityClient(system: system).captureTarget()
        ) { error in
            XCTAssertEqual(
                error as? AccessibilityClient.AXError,
                .accessibilityTreeTruncated
            )
        }
        XCTAssertTrue(system.focusAttempts.isEmpty)
    }

    func testAutoFocusedTargetRefreshesOneEquivalentAXReplacement() throws {
        let system = FakeAccessibilitySystem.validConversation(pid: 879)
        system.focusedElementNode = system.sendButton
        let client = AccessibilityClient(system: system)
        let target = try client.captureTarget()
        let replacement = system.replaceComposerWithEquivalentNode()

        XCTAssertNoThrow(try client.revalidate(target))
        XCTAssertTrue(system.elementsAreEqual(target.element, replacement))
    }

    func testAutoFocusedTargetRejectsSecondEquivalentAXReplacement() throws {
        let system = FakeAccessibilitySystem.validConversation(pid: 880)
        system.focusedElementNode = system.sendButton
        let client = AccessibilityClient(system: system)
        let target = try client.captureTarget()
        _ = system.replaceComposerWithEquivalentNode()
        try client.revalidate(target)
        _ = system.replaceComposerWithEquivalentNode()

        assertTargetChanged { try client.revalidate(target) }
    }

    func testAutoFocusedTargetRejectsAXReplacementWithDifferentContext() throws {
        let system = FakeAccessibilitySystem.validConversation(pid: 8801)
        system.focusedElementNode = system.sendButton
        let client = AccessibilityClient(system: system)
        let target = try client.captureTarget()
        _ = system.replaceComposerWithEquivalentNode(title: "Different input")

        assertTargetChanged { try client.revalidate(target) }
    }

    func testAutoFocusedTargetRejectsEquivalentAXReplacementAfterWrite() throws {
        let system = FakeAccessibilitySystem.validConversation(pid: 8802)
        system.focusedElementNode = system.sendButton
        let client = AccessibilityClient(system: system)
        let target = try client.captureTarget()
        try client.setComposerValue("可", in: target)
        _ = system.replaceComposerWithEquivalentNode()

        assertTargetChanged { try client.revalidate(target) }
    }

    func testNormallyFocusedTargetRejectsEquivalentAXReplacement() throws {
        let system = FakeAccessibilitySystem.validConversation(pid: 881)
        let client = AccessibilityClient(system: system)
        let target = try client.captureTarget()
        _ = system.replaceComposerWithEquivalentNode()

        assertTargetChanged { try client.revalidate(target) }
    }

    private func assertTargetChanged(
        _ operation: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(
                error as? AccessibilityClient.AXError,
                .targetChanged,
                file: file,
                line: line
            )
        }
    }
}

@MainActor
private final class FakeAccessibilitySystem: AccessibilitySystemProviding {
    final class Node: NSObject {
        weak var parent: Node?
        var processIdentifier: pid_t?
        var isFocused = false

        init(processIdentifier: pid_t? = nil) {
            self.processIdentifier = processIdentifier
        }
    }

    var isProcessTrusted = true
    var frontmostPID: pid_t?
    var frontmostBundleIdentifier: String? = "com.openai.codex"
    var storedComposerValue = ""
    var focusedElementNode: Node?
    var focusedWindowNode: Node?
    var ignoreComposerWrites = false
    var childrenErrorNode: Node?
    var summaryErrorNode: Node?
    var focusError: Error?
    var ignoreFocusAssignment = false
    var afterFocusAttempt: (() -> Void)?
    private(set) var returnPIDs: [pid_t] = []
    private(set) var sleepCount = 0
    private(set) var focusAttempts: [Node] = []

    let root = Node()
    let alternateWindow = Node()
    let main = Node()
    let composer = Node()
    let sendContainer = Node()
    let sendButton = Node()

    private var childrenByNode: [ObjectIdentifier: [Node]] = [:]
    private var summariesByNode: [
        ObjectIdentifier: AccessibilityClient.ElementSummary
    ] = [:]

    init(pid: pid_t?) {
        frontmostPID = pid
        focusedWindowNode = root
    }

    static func validConversation(pid: pid_t) -> FakeAccessibilitySystem {
        let system = FakeAccessibilitySystem(pid: pid)
        system.childrenByNode[ObjectIdentifier(system.root)] = [system.main]
        system.childrenByNode[ObjectIdentifier(system.main)] = [
            system.composer,
            system.sendButton,
        ]
        system.childrenByNode[ObjectIdentifier(system.composer)] = []
        system.childrenByNode[ObjectIdentifier(system.sendButton)] = []
        system.summariesByNode[ObjectIdentifier(system.root)] = system.makeSummary(
            role: "AXWindow"
        )
        system.summariesByNode[ObjectIdentifier(system.main)] = system.makeSummary(
            role: "AXGroup",
            subrole: "AXLandmarkMain"
        )
        system.summariesByNode[ObjectIdentifier(system.composer)] = system.makeSummary(
            role: "AXTextArea",
            valueSettable: true
        )
        system.summariesByNode[ObjectIdentifier(system.sendButton)] = system.makeSummary(
            role: "AXButton",
            title: "Send"
        )
        system.focusedElementNode = system.composer
        for node in [
            system.root,
            system.alternateWindow,
            system.main,
            system.composer,
            system.sendContainer,
            system.sendButton,
        ] {
            node.processIdentifier = pid
        }
        system.main.parent = system.root
        system.composer.parent = system.main
        system.sendButton.parent = system.main
        return system
    }

    func focusedWindow(processIdentifier: pid_t) throws -> AnyObject {
        focusedWindowNode ?? root
    }

    func focusedElement(processIdentifier: pid_t) throws -> AnyObject {
        guard let focusedElementNode else {
            throw AccessibilityClient.AXError.focusedElementUnavailable
        }
        return focusedElementNode
    }

    func processIdentifier(of element: AnyObject) throws -> pid_t {
        guard let pid = (element as! Node).processIdentifier else {
            throw AccessibilityClient.AXError.focusedElementUnavailable
        }
        return pid
    }

    func parent(of element: AnyObject) throws -> AnyObject? {
        (element as! Node).parent
    }

    func elementsAreEqual(_ lhs: AnyObject, _ rhs: AnyObject) -> Bool {
        lhs === rhs
    }

    func isFocused(_ element: AnyObject) throws -> Bool {
        (element as! Node).isFocused
    }

    func setFocusedElement(_ element: AnyObject) throws {
        let node = element as! Node
        focusAttempts.append(node)
        if let focusError { throw focusError }
        guard !ignoreFocusAssignment else { return }
        focusedElementNode?.isFocused = false
        node.isFocused = true
        focusedElementNode = node
        afterFocusAttempt?()
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
        if !ignoreComposerWrites {
            storedComposerValue = value
        }
    }

    func postReturn(processIdentifier: pid_t) throws {
        returnPIDs.append(processIdentifier)
    }

    func sleep(for interval: TimeInterval) async throws {
        sleepCount += 1
    }

    func nestSendButtonBesideComposer() {
        childrenByNode[ObjectIdentifier(main)] = [composer, sendContainer]
        childrenByNode[ObjectIdentifier(sendContainer)] = [sendButton]
        summariesByNode[ObjectIdentifier(sendContainer)] = makeSummary(
            role: "AXGroup"
        )
        sendContainer.parent = main
        sendButton.parent = sendContainer
    }

    func nestComposer(parentDepth: Int) {
        precondition(parentDepth >= 2)
        let groups = (0..<(parentDepth - 1)).map { _ in
            Node(processIdentifier: frontmostPID)
        }
        childrenByNode[ObjectIdentifier(root)] = [groups[0]]
        groups[0].parent = root
        for index in groups.indices {
            summariesByNode[ObjectIdentifier(groups[index])] = makeSummary(
                role: "AXGroup"
            )
            if index + 1 < groups.count {
                childrenByNode[ObjectIdentifier(groups[index])] = [groups[index + 1]]
                groups[index + 1].parent = groups[index]
            } else {
                childrenByNode[ObjectIdentifier(groups[index])] = [
                    composer,
                    sendButton,
                ]
                composer.parent = groups[index]
                sendButton.parent = groups[index]
            }
        }
    }

    func addNearbyNodes(count: Int) {
        let nodes = (0..<count).map { _ in Node(processIdentifier: frontmostPID) }
        childrenByNode[ObjectIdentifier(main)] = [composer] + nodes
        for node in nodes {
            node.parent = main
            childrenByNode[ObjectIdentifier(node)] = []
            summariesByNode[ObjectIdentifier(node)] = makeSummary(role: "AXGroup")
        }
    }

    func addEditableInputBeforeComposer(title: String) -> Node {
        let input = Node(processIdentifier: frontmostPID)
        input.parent = main
        childrenByNode[ObjectIdentifier(input)] = []
        summariesByNode[ObjectIdentifier(input)] = makeSummary(
            role: "AXTextField",
            title: title,
            valueSettable: true
        )
        childrenByNode[ObjectIdentifier(main)] = [
            input,
            composer,
            sendButton,
        ]
        return input
    }

    func replaceWindowChildrenWithNonEditableNodes(count: Int) {
        let nodes = (0..<count).map { _ in
            Node(processIdentifier: frontmostPID)
        }
        childrenByNode[ObjectIdentifier(root)] = nodes
        for node in nodes {
            node.parent = root
            childrenByNode[ObjectIdentifier(node)] = []
            summariesByNode[ObjectIdentifier(node)] = makeSummary(
                role: "AXGroup"
            )
        }
    }

    func replaceComposerWithEquivalentNode(title: String? = nil) -> Node {
        let replacement = Node(processIdentifier: frontmostPID)
        replacement.parent = main
        replacement.isFocused = true
        childrenByNode[ObjectIdentifier(replacement)] = []
        summariesByNode[ObjectIdentifier(replacement)] = makeSummary(
            role: "AXTextArea",
            title: title,
            valueSettable: true
        )
        if let index = childrenByNode[ObjectIdentifier(main)]?.firstIndex(
            where: { $0 === focusedElementNode }
        ) {
            childrenByNode[ObjectIdentifier(main)]?[index] = replacement
        }
        focusedElementNode?.isFocused = false
        focusedElementNode = replacement
        return replacement
    }

    func registerDetachedInput(_ node: Node) {
        childrenByNode[ObjectIdentifier(node)] = []
        summariesByNode[ObjectIdentifier(node)] = makeSummary(
            role: "AXTextArea",
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
