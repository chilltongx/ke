import AppKit
import ApplicationServices
import Foundation

@MainActor
protocol AccessibilityControlling: AnyObject {
    func prepareFocusedConversation(timeout: TimeInterval) async throws
    func revalidateFocusedConversation() throws
    func frontmostBundleIdentifier() -> String?
    func composerValue() throws -> String
    func setComposerValue(_ value: String) throws
    func waitUntilSendEnabled(timeout: TimeInterval) async throws
    func pressSend() throws
}

@MainActor
protocol AccessibilitySystemProviding: AnyObject {
    var isProcessTrusted: Bool { get }
    var frontmostPID: pid_t? { get }
    var frontmostBundleIdentifier: String? { get }

    func runningApplications(
        bundleIdentifier: String
    ) -> [AccessibilityClient.RunningApplication]
    func activate(processIdentifier: pid_t) -> Bool
    func focusedWindow(processIdentifier: pid_t) throws -> AnyObject
    func focusedElement(processIdentifier: pid_t) throws -> AnyObject
    func processIdentifier(of element: AnyObject) throws -> pid_t
    func parent(of element: AnyObject) throws -> AnyObject?
    func elementsAreEqual(_ lhs: AnyObject, _ rhs: AnyObject) -> Bool
    func children(of element: AnyObject) throws -> [AnyObject]
    func summary(
        of element: AnyObject,
        parentIndex: Int?
    ) throws -> AccessibilityClient.ElementSummary
    func composerValue(of element: AnyObject) throws -> String
    func setComposerValue(_ value: String, on element: AnyObject) throws
    func press(_ element: AnyObject) throws
    func postReturn(processIdentifier: pid_t) throws
    func sleep(for interval: TimeInterval) async throws
}

@MainActor
final class AccessibilityClient: AccessibilityControlling, FocusedInputControlling {
    enum AXError: Error, Equatable, LocalizedError {
        case permissionMissing
        case codexNotRunning
        case ambiguousApplication
        case activationTimedOut
        case targetApplicationChanged
        case taskNotFound
        case ambiguousTask
        case composerMissing
        case composerValueUnreadable
        case nativeApprovalCard
        case sendActionMissing
        case sendActionTimedOut
        case invalidAccessibilityTree
        case accessibilityTreeTruncated
        case frontmostTargetUnavailable
        case focusedElementUnavailable
        case targetChanged
        case insertedValueMismatch
        case returnDeliveryFailed

        var errorDescription: String? {
            switch self {
            case .permissionMissing:
                "请在系统设置的辅助功能中启用 Codex 可"
            case .codexNotRunning:
                "Codex 尚未运行"
            case .ambiguousApplication:
                "检测到多个正在运行的 Codex，请只保留一个"
            case .activationTimedOut:
                "无法在限定时间内激活 Codex"
            case .targetApplicationChanged:
                "Codex 已不再位于前台"
            case .taskNotFound:
                "找不到当前 Codex 窗口"
            case .ambiguousTask:
                "无法唯一确认当前 Codex 输入框"
            case .composerMissing:
                "找不到当前 Codex 输入框"
            case .composerValueUnreadable:
                "无法读取当前 Codex 输入框"
            case .nativeApprovalCard:
                "不支持此类原生审批"
            case .sendActionMissing:
                "找不到 Codex 发送按钮"
            case .sendActionTimedOut:
                "Codex 发送按钮未能及时启用"
            case .invalidAccessibilityTree, .accessibilityTreeTruncated:
                "无法安全读取完整的 Codex 界面"
            case .frontmostTargetUnavailable:
                "找不到当前前台应用"
            case .focusedElementUnavailable:
                "找不到当前光标输入框"
            case .targetChanged:
                "当前应用、窗口或光标已经变化"
            case .insertedValueMismatch:
                "无法确认“可”已经写入"
            case .returnDeliveryFailed:
                "无法发送 Enter"
            }
        }
    }

    enum AttributeRead {
        case value(Any)
        case absent
        case failure
    }

    struct RunningApplication: Equatable {
        let processIdentifier: pid_t
    }

    struct ElementSummary: Equatable {
        let parentIndex: Int?
        let role: String?
        let subrole: String?
        let title: String?
        let description: String?
        let value: String?
        let enabled: Bool
        let valueSettable: Bool

        init(
            parentIndex: Int? = nil,
            role: String?,
            subrole: String? = nil,
            title: String?,
            description: String?,
            value: String? = nil,
            enabled: Bool,
            valueSettable: Bool
        ) {
            self.parentIndex = parentIndex
            self.role = role
            self.subrole = subrole
            self.title = title
            self.description = description
            self.value = value
            self.enabled = enabled
            self.valueSettable = valueSettable
        }
    }

    struct ControlSelection: Equatable {
        let composerIndex: Int
        let sendButtonIndex: Int
    }

    struct ComposerSelection: Equatable {
        let composerIndex: Int
        let sendButtonIndex: Int?

        init(composerIndex: Int, sendButtonIndex: Int? = nil) {
            self.composerIndex = composerIndex
            self.sendButtonIndex = sendButtonIndex
        }
    }

    static let maximumElementCount = 5_000
    static let maximumAncestorDepth = 12
    static let maximumNearbyAncestorDepth = 4
    static let maximumNearbyTraversalDepth = 3
    static let maximumNearbyElementCount = 128
    private static let codexBundleIdentifier = "com.openai.codex"

    private let system: any AccessibilitySystemProviding
    private let pollInterval: TimeInterval
    private var targetPID: pid_t?
    private var targetWindow: AnyObject?
    private var composer: AnyObject?
    private var sendButton: AnyObject?

    convenience init() {
        self.init(system: SystemAccessibilityProvider())
    }

    init(
        system: any AccessibilitySystemProviding,
        pollInterval: TimeInterval = 0.1
    ) {
        self.system = system
        self.pollInterval = max(0.001, pollInterval)
    }

    func prepareFocusedConversation(timeout: TimeInterval) async throws {
        targetPID = nil
        targetWindow = nil
        composer = nil
        sendButton = nil

        guard system.isProcessTrusted else {
            throw AXError.permissionMissing
        }
        let applications = system.runningApplications(
            bundleIdentifier: Self.codexBundleIdentifier
        )
        guard !applications.isEmpty else {
            throw AXError.codexNotRunning
        }
        guard applications.count == 1, let application = applications.first else {
            throw AXError.ambiguousApplication
        }
        let pid = application.processIdentifier
        guard system.activate(processIdentifier: pid) else {
            throw AXError.activationTimedOut
        }
        try await waitUntilFrontmost(pid: pid, timeout: timeout)
        try await locateFocusedConversation(pid: pid, timeout: timeout)
    }

    func revalidateFocusedConversation() throws {
        guard let targetPID else {
            throw AXError.taskNotFound
        }
        let applications = system.runningApplications(
            bundleIdentifier: Self.codexBundleIdentifier
        )
        guard applications.count == 1,
              applications[0].processIdentifier == targetPID,
              system.frontmostPID == targetPID,
              system.frontmostBundleIdentifier == Self.codexBundleIdentifier
        else {
            throw AXError.targetApplicationChanged
        }
        guard let targetWindow else {
            throw AXError.taskNotFound
        }
        let currentWindow = try system.focusedWindow(processIdentifier: targetPID)
        guard system.elementsAreEqual(currentWindow, targetWindow) else {
            throw AXError.targetApplicationChanged
        }
    }

    func frontmostBundleIdentifier() -> String? {
        system.frontmostBundleIdentifier
    }

    func composerValue() throws -> String {
        let summaries = try refreshFocusedConversationComposer()
        guard let composer else { throw AXError.composerMissing }
        let value = try system.composerValue(of: composer)
        guard let description = summaries.composer.description,
              !description.isEmpty,
              value == "\n\(description)"
        else {
            return value
        }
        return ""
    }

    func setComposerValue(_ value: String) throws {
        try revalidateFocusedConversation()
        guard let composer else {
            throw AXError.composerMissing
        }
        try system.setComposerValue(value, on: composer)
    }

    func waitUntilSendEnabled(timeout: TimeInterval) async throws {
        let maximumSleeps = max(0, Int(ceil(max(0, timeout) / pollInterval)))
        for attempt in 0...maximumSleeps {
            do {
                try refreshFocusedConversationControls()
                guard let sendButton else {
                    throw AXError.sendActionMissing
                }
                let summary = try system.summary(of: sendButton, parentIndex: nil)
                guard Self.isSendButton(summary) else {
                    throw AXError.sendActionMissing
                }
                if summary.enabled { return }
            } catch let error as AXError {
                switch error {
                case .taskNotFound, .composerMissing, .sendActionMissing:
                    break
                default:
                    throw error
                }
            }
            guard attempt < maximumSleeps else { break }
            try await system.sleep(for: pollInterval)
        }
        throw AXError.sendActionTimedOut
    }

    func pressSend() throws {
        try revalidateFocusedConversation()
        guard let sendButton else {
            throw AXError.sendActionMissing
        }
        try system.press(sendButton)
    }

    func captureTarget() throws -> FocusedTargetSnapshot {
        guard system.isProcessTrusted else {
            throw AXError.permissionMissing
        }
        guard let pid = system.frontmostPID,
              pid > 0,
              let bundleIdentifier = system.frontmostBundleIdentifier,
              !bundleIdentifier.isEmpty
        else {
            throw AXError.frontmostTargetUnavailable
        }

        let window = try system.focusedWindow(processIdentifier: pid)
        let element = try system.focusedElement(processIdentifier: pid)
        guard try system.processIdentifier(of: window) == pid,
              try system.processIdentifier(of: element) == pid
        else {
            throw AXError.focusedElementUnavailable
        }
        let context = try makeContext(
            focused: element,
            window: window,
            expectedPID: pid
        )
        return FocusedTargetSnapshot(
            processIdentifier: pid,
            bundleIdentifier: bundleIdentifier,
            window: window,
            element: element,
            context: context
        )
    }

    func revalidate(_ target: FocusedTargetSnapshot) throws {
        guard system.frontmostPID == target.processIdentifier,
              system.frontmostBundleIdentifier == target.bundleIdentifier
        else {
            throw AXError.targetChanged
        }
        let window = try system.focusedWindow(
            processIdentifier: target.processIdentifier
        )
        let element = try system.focusedElement(
            processIdentifier: target.processIdentifier
        )
        guard try system.processIdentifier(of: window) == target.processIdentifier,
              try system.processIdentifier(of: element) == target.processIdentifier,
              system.elementsAreEqual(window, target.window),
              system.elementsAreEqual(element, target.element)
        else {
            throw AXError.targetChanged
        }
    }

    func composerValue(in target: FocusedTargetSnapshot) throws -> String {
        try system.composerValue(of: target.element)
    }

    func setComposerValue(
        _ value: String,
        in target: FocusedTargetSnapshot
    ) throws {
        try revalidate(target)
        try system.setComposerValue(value, on: target.element)
    }

    func waitUntilComposerValue(
        _ expected: String,
        in target: FocusedTargetSnapshot,
        timeout: TimeInterval
    ) async throws {
        let maximumSleeps = max(
            0,
            Int(ceil(max(0, timeout) / pollInterval))
        )
        for attempt in 0...maximumSleeps {
            try revalidate(target)
            if try system.composerValue(of: target.element) == expected {
                return
            }
            guard attempt < maximumSleeps else { break }
            try await system.sleep(for: pollInterval)
        }
        throw AXError.insertedValueMismatch
    }

    func pressReturn(in target: FocusedTargetSnapshot) throws {
        try revalidate(target)
        do {
            try system.postReturn(processIdentifier: target.processIdentifier)
        } catch let error as AXError {
            throw error
        } catch {
            throw AXError.returnDeliveryFailed
        }
    }

    static func validatedChildren(_ read: AttributeRead) throws -> [AnyObject] {
        switch read {
        case .absent:
            return []
        case .failure:
            throw AXError.invalidAccessibilityTree
        case .value(let value):
            guard let children = value as? [AnyObject],
                  children.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() })
            else {
                throw AXError.invalidAccessibilityTree
            }
            return children
        }
    }

    static func mergedChildren(
        regular: [AnyObject],
        navigationOrder: [AnyObject],
        areEqual: (AnyObject, AnyObject) -> Bool
    ) -> [AnyObject] {
        navigationOrder.reduce(into: regular) { result, candidate in
            guard !result.contains(where: { areEqual($0, candidate) }) else {
                return
            }
            result.append(candidate)
        }
    }

    static func validatedSummary(
        parentIndex: Int?,
        role: AttributeRead,
        subrole: AttributeRead,
        title: AttributeRead,
        description: AttributeRead,
        value: AttributeRead,
        enabled: AttributeRead,
        valueSettable: AttributeRead
    ) throws -> ElementSummary {
        guard let role = try requiredString(role),
              let valueSettable = try requiredBool(valueSettable)
        else {
            throw AXError.invalidAccessibilityTree
        }
        let enabled = try optionalBool(enabled)
        let requiresEnabled = [
            kAXTextAreaRole as String,
            kAXTextFieldRole as String,
            kAXButtonRole as String,
        ].contains(role)
        guard !requiresEnabled || enabled != nil else {
            throw AXError.invalidAccessibilityTree
        }
        return ElementSummary(
            parentIndex: parentIndex,
            role: role,
            subrole: try optionalString(subrole),
            title: try optionalString(title),
            description: try optionalString(description),
            value: try optionalString(value),
            enabled: enabled ?? false,
            valueSettable: valueSettable
        )
    }

    static func selectControls(in elements: [ElementSummary]) throws -> ControlSelection {
        let composer = try selectComposer(in: elements)
        guard let sendButtonIndex = composer.sendButtonIndex else {
            throw AXError.sendActionMissing
        }
        return ControlSelection(
            composerIndex: composer.composerIndex,
            sendButtonIndex: sendButtonIndex
        )
    }

    static func selectComposer(in elements: [ElementSummary]) throws -> ComposerSelection {
        if elements.contains(where: isNativeApprovalControl) {
            throw AXError.nativeApprovalCard
        }
        let composerIndices = elements.indices.filter { index in
            let element = elements[index]
            return [kAXTextAreaRole as String, kAXTextFieldRole as String]
                .contains(element.role)
                && element.enabled
                && element.valueSettable
        }
        guard composerIndices.count == 1 else {
            throw composerIndices.isEmpty ? AXError.composerMissing : AXError.ambiguousTask
        }
        let sendButtonIndices = elements.indices.filter { index in
            Self.isSendButton(elements[index])
        }
        guard sendButtonIndices.count <= 1 else {
            throw AXError.ambiguousTask
        }
        return ComposerSelection(
            composerIndex: composerIndices[0],
            sendButtonIndex: sendButtonIndices.first
        )
    }

    static func selectFocusedConversationControls(
        in elements: [ElementSummary]
    ) throws -> ControlSelection {
        guard !elements.isEmpty, hasValidHierarchy(elements) else {
            throw AXError.ambiguousTask
        }
        let mainRoots = elements.indices.filter {
            elements[$0].subrole == kAXLandmarkMainSubrole as String
        }
        var owners: [(root: Int, selection: ControlSelection)] = []
        for root in mainRoots {
            let indices = subtreeIndices(root: root, in: elements)
            do {
                let local = try selectControls(in: indices.map { elements[$0] })
                owners.append((
                    root: root,
                    selection: .init(
                        composerIndex: indices[local.composerIndex],
                        sendButtonIndex: indices[local.sendButtonIndex]
                    )
                ))
            } catch let error as AXError {
                switch error {
                case .composerMissing, .sendActionMissing:
                    continue
                default:
                    throw error
                }
            }
        }
        let deepest = owners.filter { candidate in
            !owners.contains { other in
                other.root != candidate.root
                    && isDescendant(other.root, of: candidate.root, in: elements)
            }
        }
        guard deepest.count == 1, let owner = deepest.first else {
            throw deepest.isEmpty ? AXError.composerMissing : AXError.ambiguousTask
        }
        return owner.selection
    }

    static func selectFocusedConversationComposer(
        in elements: [ElementSummary]
    ) throws -> ComposerSelection {
        guard !elements.isEmpty, hasValidHierarchy(elements) else {
            throw AXError.ambiguousTask
        }
        let mainRoots = elements.indices.filter {
            elements[$0].subrole == kAXLandmarkMainSubrole as String
        }
        var owners: [(root: Int, selection: ComposerSelection)] = []
        for root in mainRoots {
            let indices = subtreeIndices(root: root, in: elements)
            do {
                let local = try selectComposer(in: indices.map { elements[$0] })
                owners.append((
                    root: root,
                    selection: .init(
                        composerIndex: indices[local.composerIndex],
                        sendButtonIndex: local.sendButtonIndex.map { indices[$0] }
                    )
                ))
            } catch let error as AXError {
                switch error {
                case .composerMissing:
                    continue
                default:
                    throw error
                }
            }
        }
        let deepest = owners.filter { candidate in
            !owners.contains { other in
                other.root != candidate.root
                    && isDescendant(other.root, of: candidate.root, in: elements)
            }
        }
        guard deepest.count == 1, let owner = deepest.first else {
            throw deepest.isEmpty ? AXError.composerMissing : AXError.ambiguousTask
        }
        return owner.selection
    }

    static func validatedComposerValue(
        attributeReadSucceeded: Bool,
        value: Any?
    ) throws -> String {
        guard attributeReadSucceeded else {
            throw AXError.composerValueUnreadable
        }
        guard let value else { return "" }
        guard let string = value as? String else {
            throw AXError.composerValueUnreadable
        }
        return string
    }

    private func makeContext(
        focused: AnyObject,
        window: AnyObject,
        expectedPID: pid_t
    ) throws -> FocusedChatContext {
        let focusedSummary = try chatSummary(
            of: focused,
            expectedPID: expectedPID
        )
        var ancestors: [ChatElementSummary] = []
        var nearby: [ChatElementSummary] = []
        var child = focused
        var reachedWindow = system.elementsAreEqual(focused, window)

        for ancestorDepth in 0..<Self.maximumAncestorDepth where !reachedWindow {
            guard let parent = try system.parent(of: child) else { break }
            ancestors.append(
                try chatSummary(of: parent, expectedPID: expectedPID)
            )
            if ancestorDepth < Self.maximumNearbyAncestorDepth {
                for sibling in try system.children(of: parent)
                where !system.elementsAreEqual(sibling, child) {
                    try appendNearbySummaries(
                        startingAt: sibling,
                        expectedPID: expectedPID,
                        to: &nearby
                    )
                }
            }
            reachedWindow = system.elementsAreEqual(parent, window)
            child = parent
        }

        guard reachedWindow else {
            throw AXError.focusedElementUnavailable
        }
        return FocusedChatContext(
            focused: focusedSummary,
            ancestors: ancestors,
            nearby: nearby
        )
    }

    private func appendNearbySummaries(
        startingAt root: AnyObject,
        expectedPID: pid_t,
        to summaries: inout [ChatElementSummary]
    ) throws {
        var queue: [(element: AnyObject, depth: Int)] = [(root, 0)]
        var offset = 0
        var visited: [AnyObject] = []

        while offset < queue.count {
            let item = queue[offset]
            offset += 1
            guard !visited.contains(where: {
                system.elementsAreEqual($0, item.element)
            }) else {
                continue
            }
            visited.append(item.element)
            guard summaries.count < Self.maximumNearbyElementCount else {
                throw AXError.accessibilityTreeTruncated
            }
            summaries.append(
                try chatSummary(of: item.element, expectedPID: expectedPID)
            )
            guard item.depth < Self.maximumNearbyTraversalDepth else {
                continue
            }
            queue.append(contentsOf: try system.children(of: item.element).map {
                ($0, item.depth + 1)
            })
        }
    }

    private func chatSummary(
        of element: AnyObject,
        expectedPID: pid_t
    ) throws -> ChatElementSummary {
        guard try system.processIdentifier(of: element) == expectedPID else {
            throw AXError.focusedElementUnavailable
        }
        let summary = try system.summary(of: element, parentIndex: nil)
        return ChatElementSummary(
            role: summary.role,
            subrole: summary.subrole,
            title: summary.title,
            description: summary.description,
            enabled: summary.enabled,
            valueSettable: summary.valueSettable
        )
    }

    private func waitUntilFrontmost(pid: pid_t, timeout: TimeInterval) async throws {
        let maximumSleeps = max(0, Int(ceil(max(0, timeout) / pollInterval)))
        for attempt in 0...maximumSleeps {
            if system.frontmostPID == pid { return }
            guard attempt < maximumSleeps else { break }
            try await system.sleep(for: pollInterval)
        }
        throw AXError.activationTimedOut
    }

    private func locateFocusedConversation(pid: pid_t, timeout: TimeInterval) async throws {
        let maximumSleeps = max(0, Int(ceil(max(0, timeout) / pollInterval)))
        for attempt in 0...maximumSleeps {
            do {
                try verifyCurrentPID(pid)
                let tree = try elementTree(pid: pid)
                let selection = try Self.selectFocusedConversationComposer(
                    in: tree.summaries
                )
                targetPID = pid
                targetWindow = tree.elements[0]
                composer = tree.elements[selection.composerIndex]
                sendButton = selection.sendButtonIndex.map { tree.elements[$0] }
                return
            } catch let error as AXError {
                switch error {
                case .taskNotFound, .composerMissing, .sendActionMissing:
                    break
                default:
                    throw error
                }
            }
            guard attempt < maximumSleeps else { break }
            try await system.sleep(for: pollInterval)
        }
        throw AXError.taskNotFound
    }

    private func refreshFocusedConversationControls() throws {
        try revalidateFocusedConversation()
        guard let targetPID, let targetWindow else {
            throw AXError.taskNotFound
        }
        let tree = try elementTree(pid: targetPID)
        guard system.elementsAreEqual(tree.elements[0], targetWindow) else {
            throw AXError.targetApplicationChanged
        }
        let selection = try Self.selectFocusedConversationControls(
            in: tree.summaries
        )
        composer = tree.elements[selection.composerIndex]
        sendButton = tree.elements[selection.sendButtonIndex]
    }

    @discardableResult
    private func refreshFocusedConversationComposer() throws -> (
        composer: ElementSummary,
        sendButton: ElementSummary?
    ) {
        try revalidateFocusedConversation()
        guard let targetPID, let targetWindow else {
            throw AXError.taskNotFound
        }
        let tree = try elementTree(pid: targetPID)
        guard system.elementsAreEqual(tree.elements[0], targetWindow) else {
            throw AXError.targetApplicationChanged
        }
        let selection = try Self.selectFocusedConversationComposer(
            in: tree.summaries
        )
        composer = tree.elements[selection.composerIndex]
        sendButton = selection.sendButtonIndex.map { tree.elements[$0] }
        return (
            composer: tree.summaries[selection.composerIndex],
            sendButton: selection.sendButtonIndex.map { tree.summaries[$0] }
        )
    }

    private func verifyCurrentPID(_ pid: pid_t) throws {
        guard system.frontmostPID == pid else {
            throw AXError.targetApplicationChanged
        }
    }

    private func elementTree(
        pid: pid_t
    ) throws -> (elements: [AnyObject], summaries: [ElementSummary]) {
        let focusedWindow = try system.focusedWindow(processIdentifier: pid)
        var queue: [(element: AnyObject, parentIndex: Int?)] = [(focusedWindow, nil)]
        var elements: [AnyObject] = []
        var summaries: [ElementSummary] = []
        var offset = 0
        while offset < queue.count {
            guard elements.count < Self.maximumElementCount else {
                throw AXError.accessibilityTreeTruncated
            }
            let next = queue[offset]
            offset += 1
            let index = elements.count
            let summary = try system.summary(
                of: next.element,
                parentIndex: next.parentIndex
            )
            let children = try system.children(of: next.element)
            elements.append(next.element)
            summaries.append(summary)
            queue.append(
                contentsOf: children.map {
                    (element: $0, parentIndex: Optional(index))
                }
            )
        }
        return (elements, summaries)
    }

    private static func requiredString(_ read: AttributeRead) throws -> String? {
        guard case .value(let value) = read, let string = value as? String else {
            throw AXError.invalidAccessibilityTree
        }
        return string
    }

    private static func requiredBool(_ read: AttributeRead) throws -> Bool? {
        guard case .value(let value) = read, let bool = value as? Bool else {
            throw AXError.invalidAccessibilityTree
        }
        return bool
    }

    private static func optionalBool(_ read: AttributeRead) throws -> Bool? {
        switch read {
        case .absent:
            return nil
        case .failure:
            throw AXError.invalidAccessibilityTree
        case .value(let value):
            guard let bool = value as? Bool else {
                throw AXError.invalidAccessibilityTree
            }
            return bool
        }
    }

    private static func optionalString(_ read: AttributeRead) throws -> String? {
        switch read {
        case .absent:
            return nil
        case .failure:
            throw AXError.invalidAccessibilityTree
        case .value(let value):
            guard let string = value as? String else {
                throw AXError.invalidAccessibilityTree
            }
            return string
        }
    }

    private static func isNativeApprovalControl(_ element: ElementSummary) -> Bool {
        guard element.role == kAXButtonRole as String else { return false }
        let labels = [element.title, element.description]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return labels.contains { label in
            label.hasPrefix("approve")
                || label.hasPrefix("allow")
                || label.contains("批准")
                || label.contains("允许")
        }
    }

    private static func isSendButton(_ element: ElementSummary) -> Bool {
        guard element.role == kAXButtonRole as String else { return false }
        let labels = [element.title, element.description]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return labels.contains(where: {
            ["send", "send message", "发送", "发送消息", "加入队列"].contains($0)
        })
    }

    private static func hasValidHierarchy(_ elements: [ElementSummary]) -> Bool {
        for index in elements.indices {
            guard let parent = elements[index].parentIndex else { continue }
            guard elements.indices.contains(parent), parent < index else { return false }
        }
        return true
    }

    private static func subtreeIndices(
        root: Int,
        in elements: [ElementSummary]
    ) -> [Int] {
        elements.indices.filter { index in
            index == root || isDescendant(index, of: root, in: elements)
        }
    }

    private static func isDescendant(
        _ index: Int,
        of ancestor: Int,
        in elements: [ElementSummary]
    ) -> Bool {
        var current = elements[index].parentIndex
        while let parent = current {
            if parent == ancestor { return true }
            current = elements[parent].parentIndex
        }
        return false
    }
}

@MainActor
private final class SystemAccessibilityProvider: AccessibilitySystemProviding {
    var isProcessTrusted: Bool { AXIsProcessTrusted() }
    var frontmostPID: pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
    var frontmostBundleIdentifier: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    func runningApplications(
        bundleIdentifier: String
    ) -> [AccessibilityClient.RunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .map { .init(processIdentifier: $0.processIdentifier) }
    }

    func activate(processIdentifier: pid_t) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier)
        else { return false }
        return application.activate()
    }

    func focusedWindow(processIdentifier: pid_t) throws -> AnyObject {
        let application = AXUIElementCreateApplication(processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &value
        ) == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            throw AccessibilityClient.AXError.taskNotFound
        }
        return value as AnyObject
    }

    func focusedElement(processIdentifier: pid_t) throws -> AnyObject {
        let application = AXUIElementCreateApplication(processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            throw AccessibilityClient.AXError.focusedElementUnavailable
        }
        return value as AnyObject
    }

    func processIdentifier(of element: AnyObject) throws -> pid_t {
        var pid: pid_t = 0
        guard AXUIElementGetPid(axElement(element), &pid) == .success,
              pid > 0
        else {
            throw AccessibilityClient.AXError.focusedElementUnavailable
        }
        return pid
    }

    func parent(of element: AnyObject) throws -> AnyObject? {
        switch readAttribute(
            axElement(element),
            kAXParentAttribute as CFString
        ) {
        case .absent:
            return nil
        case .failure:
            throw AccessibilityClient.AXError.invalidAccessibilityTree
        case .value(let value):
            guard CFGetTypeID(value as CFTypeRef) == AXUIElementGetTypeID() else {
                throw AccessibilityClient.AXError.invalidAccessibilityTree
            }
            return value as AnyObject
        }
    }

    func elementsAreEqual(_ lhs: AnyObject, _ rhs: AnyObject) -> Bool {
        CFEqual(axElement(lhs), axElement(rhs))
    }

    func children(of element: AnyObject) throws -> [AnyObject] {
        let element = axElement(element)
        let regularRead = readAttribute(element, kAXChildrenAttribute as CFString)
        let navigationRead = readAttribute(
            element,
            "AXChildrenInNavigationOrder" as CFString
        )
        let regular: [AnyObject]
        let navigationOrder: [AnyObject]
        regular = try AccessibilityClient.validatedChildren(regularRead)
        navigationOrder = try AccessibilityClient.validatedChildren(navigationRead)
        return AccessibilityClient.mergedChildren(
            regular: regular,
            navigationOrder: navigationOrder,
            areEqual: { CFEqual(self.axElement($0), self.axElement($1)) }
        )
    }

    func summary(
        of element: AnyObject,
        parentIndex: Int?
    ) throws -> AccessibilityClient.ElementSummary {
        let element = axElement(element)
        var settable = DarwinBoolean(false)
        let settableResult = AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &settable
        )
        let role = readAttribute(element, kAXRoleAttribute as CFString)
        let subrole = readAttribute(element, kAXSubroleAttribute as CFString)
        let title = readAttribute(element, kAXTitleAttribute as CFString)
        let description = readAttribute(element, kAXDescriptionAttribute as CFString)
        let enabled = readAttribute(element, kAXEnabledAttribute as CFString)
        let settableRead = valueSettableRead(
            result: settableResult,
            value: settable.boolValue
        )
        return try AccessibilityClient.validatedSummary(
            parentIndex: parentIndex,
            role: role,
            subrole: subrole,
            title: title,
            description: description,
            // AXValue is heterogeneous across the tree and is not used for
            // control selection. The selected composer is read strictly later.
            value: .absent,
            enabled: enabled,
            valueSettable: settableRead
        )
    }

    func composerValue(of element: AnyObject) throws -> String {
        let element = axElement(element)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &value
        )
        return try AccessibilityClient.validatedComposerValue(
            attributeReadSucceeded: result == .success,
            value: value
        )
    }

    func setComposerValue(_ value: String, on element: AnyObject) throws {
        let element = axElement(element)
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              pid > 0,
              AXUIElementSetAttributeValue(
                  element,
                  kAXFocusedAttribute as CFString,
                  kCFBooleanTrue
              ) == .success,
              let source = CGEventSource(stateID: .hidSystemState),
              let selectAllDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: 0,
                  keyDown: true
              ),
              let selectAllUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: 0,
                  keyDown: false
              )
        else {
            throw AccessibilityClient.AXError.composerMissing
        }
        selectAllDown.flags = .maskCommand
        selectAllUp.flags = .maskCommand
        selectAllDown.postToPid(pid)
        selectAllUp.postToPid(pid)

        if value.isEmpty {
            guard let deleteDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: 51,
                keyDown: true
            ),
                let deleteUp = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: 51,
                    keyDown: false
                )
            else {
                throw AccessibilityClient.AXError.composerMissing
            }
            deleteDown.postToPid(pid)
            deleteUp.postToPid(pid)
            return
        }

        guard let valueDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: 0,
            keyDown: true
        ),
            let valueUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: false
            )
        else {
            throw AccessibilityClient.AXError.composerMissing
        }
        let utf16 = Array(value.utf16)
        utf16.withUnsafeBufferPointer { buffer in
            valueDown.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: buffer.baseAddress
            )
        }
        valueDown.postToPid(pid)
        valueUp.postToPid(pid)
    }

    func press(_ element: AnyObject) throws {
        guard AXUIElementPerformAction(
            axElement(element),
            kAXPressAction as CFString
        ) == .success else {
            throw AccessibilityClient.AXError.sendActionMissing
        }
    }

    func postReturn(processIdentifier: pid_t) throws {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(
                keyboardEventSource: source,
                virtualKey: 36,
                keyDown: true
              ),
              let up = CGEvent(
                keyboardEventSource: source,
                virtualKey: 36,
                keyDown: false
              )
        else {
            throw AccessibilityClient.AXError.returnDeliveryFailed
        }
        down.postToPid(processIdentifier)
        up.postToPid(processIdentifier)
    }

    func sleep(for interval: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(interval))
    }

    private func readAttribute(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> AccessibilityClient.AttributeRead {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        switch result {
        case .success:
            guard let value else { return .failure }
            return .value(value)
        case .attributeUnsupported, .noValue:
            return .absent
        default:
            return .failure
        }
    }

    private func valueSettableRead(
        result: ApplicationServices.AXError,
        value: Bool
    ) -> AccessibilityClient.AttributeRead {
        switch result {
        case .success:
            return .value(value)
        case .attributeUnsupported, .noValue:
            return .value(false)
        default:
            return .failure
        }
    }

    private func axElement(_ value: AnyObject) -> AXUIElement {
        value as! AXUIElement
    }
}
