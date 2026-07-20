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
    func children(of element: AnyObject) throws -> [AnyObject]
    func summary(
        of element: AnyObject,
        parentIndex: Int?
    ) throws -> AccessibilityClient.ElementSummary
    func composerValue(of element: AnyObject) throws -> String
    func setComposerValue(_ value: String, on element: AnyObject) throws
    func press(_ element: AnyObject) throws
    func sleep(for interval: TimeInterval) async throws
}

@MainActor
final class AccessibilityClient: AccessibilityControlling {
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
        case invalidAccessibilityTree
        case accessibilityTreeTruncated

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
            case .invalidAccessibilityTree, .accessibilityTreeTruncated:
                "无法安全读取完整的 Codex 界面"
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

    static let maximumElementCount = 5_000
    private static let codexBundleIdentifier = "com.openai.codex"

    private let system: any AccessibilitySystemProviding
    private let pollInterval: TimeInterval
    private var targetPID: pid_t?
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
    }

    func frontmostBundleIdentifier() -> String? {
        system.frontmostBundleIdentifier
    }

    func composerValue() throws -> String {
        try revalidateFocusedConversation()
        guard let composer else {
            throw AXError.composerMissing
        }
        return try system.composerValue(of: composer)
    }

    func setComposerValue(_ value: String) throws {
        try revalidateFocusedConversation()
        guard let composer, sendButton != nil else {
            throw AXError.composerMissing
        }
        try system.setComposerValue(value, on: composer)
    }

    func pressSend() throws {
        try revalidateFocusedConversation()
        guard let sendButton else {
            throw AXError.sendActionMissing
        }
        try system.press(sendButton)
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
              let enabled = try requiredBool(enabled),
              let valueSettable = try requiredBool(valueSettable)
        else {
            throw AXError.invalidAccessibilityTree
        }
        return ElementSummary(
            parentIndex: parentIndex,
            role: role,
            subrole: try optionalString(subrole),
            title: try optionalString(title),
            description: try optionalString(description),
            value: try optionalString(value),
            enabled: enabled,
            valueSettable: valueSettable
        )
    }

    static func selectControls(in elements: [ElementSummary]) throws -> ControlSelection {
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
            let element = elements[index]
            guard element.role == kAXButtonRole as String, element.enabled else {
                return false
            }
            let labels = [element.title, element.description]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            return labels.contains(where: {
                ["send", "send message", "发送", "发送消息"].contains($0)
            })
        }
        guard sendButtonIndices.count == 1 else {
            throw AXError.sendActionMissing
        }
        return ControlSelection(
            composerIndex: composerIndices[0],
            sendButtonIndex: sendButtonIndices[0]
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

    static func validatedComposerValue(
        attributeReadSucceeded: Bool,
        value: Any?
    ) throws -> String {
        guard attributeReadSucceeded, let value = value as? String else {
            throw AXError.composerValueUnreadable
        }
        return value
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
                let selection = try Self.selectFocusedConversationControls(
                    in: tree.summaries
                )
                targetPID = pid
                composer = tree.elements[selection.composerIndex]
                sendButton = tree.elements[selection.sendButtonIndex]
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

    func children(of element: AnyObject) throws -> [AnyObject] {
        try AccessibilityClient.validatedChildren(
            readAttribute(axElement(element), kAXChildrenAttribute as CFString)
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
        return try AccessibilityClient.validatedSummary(
            parentIndex: parentIndex,
            role: readAttribute(element, kAXRoleAttribute as CFString),
            subrole: readAttribute(element, kAXSubroleAttribute as CFString),
            title: readAttribute(element, kAXTitleAttribute as CFString),
            description: readAttribute(element, kAXDescriptionAttribute as CFString),
            // AXValue is heterogeneous across the tree and is not used for
            // control selection. The selected composer is read strictly later.
            value: .absent,
            enabled: readAttribute(element, kAXEnabledAttribute as CFString),
            valueSettable: valueSettableRead(
                result: settableResult,
                value: settable.boolValue
            )
        )
    }

    func composerValue(of element: AnyObject) throws -> String {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            axElement(element),
            kAXValueAttribute as CFString,
            &value
        )
        return try AccessibilityClient.validatedComposerValue(
            attributeReadSucceeded: result == .success,
            value: value
        )
    }

    func setComposerValue(_ value: String, on element: AnyObject) throws {
        guard AXUIElementSetAttributeValue(
            axElement(element),
            kAXValueAttribute as CFString,
            value as CFString
        ) == .success else {
            throw AccessibilityClient.AXError.composerMissing
        }
    }

    func press(_ element: AnyObject) throws {
        guard AXUIElementPerformAction(
            axElement(element),
            kAXPressAction as CFString
        ) == .success else {
            throw AccessibilityClient.AXError.sendActionMissing
        }
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
