import AppKit
import ApplicationServices
import Foundation

@MainActor
protocol AccessibilitySystemProviding: AnyObject {
    var isProcessTrusted: Bool { get }
    var frontmostPID: pid_t? { get }
    var frontmostBundleIdentifier: String? { get }

    func enableEnhancedAccessibility(processIdentifier: pid_t) throws
    func focusedWindow(processIdentifier: pid_t) throws -> AnyObject
    func focusedElement(processIdentifier: pid_t) throws -> AnyObject
    func processIdentifier(of element: AnyObject) throws -> pid_t
    func parent(of element: AnyObject) throws -> AnyObject?
    func elementsAreEqual(_ lhs: AnyObject, _ rhs: AnyObject) -> Bool
    func isFocused(_ element: AnyObject) throws -> Bool
    func setFocusedElement(_ element: AnyObject) throws
    func children(of element: AnyObject) throws -> [AnyObject]
    func summary(
        of element: AnyObject,
        parentIndex: Int?
    ) throws -> AccessibilityClient.ElementSummary
    func composerValue(of element: AnyObject) throws -> String
    func setComposerValue(
        _ value: String,
        expectedCurrentValue: String,
        on element: AnyObject
    ) throws
    func postReturn(processIdentifier: pid_t) throws
    func sleep(for interval: TimeInterval) async throws
}

extension AccessibilitySystemProviding {
    func enableEnhancedAccessibility(processIdentifier: pid_t) throws {}
}

@MainActor
final class AccessibilityClient: FocusedInputControlling {
    enum AXError: Error, Equatable, LocalizedError {
        case permissionMissing
        case composerValueUnreadable
        case invalidAccessibilityTree
        case accessibilityTreeTruncated
        case frontmostTargetUnavailable
        case focusedElementUnavailable
        case ambiguousChatInput
        case targetChanged
        case composerValueChanged
        case textInsertionFailed
        case insertedValueMismatch
        case returnDeliveryFailed

        var errorDescription: String? {
            switch self {
            case .permissionMissing:
                "请在系统设置的辅助功能中启用可"
            case .composerValueUnreadable:
                "无法读取当前聊天输入框"
            case .invalidAccessibilityTree, .accessibilityTreeTruncated:
                "无法安全读取当前应用界面"
            case .frontmostTargetUnavailable:
                "找不到当前前台应用"
            case .focusedElementUnavailable:
                "找不到当前光标输入框"
            case .ambiguousChatInput:
                "当前窗口有多个可能的聊天输入框"
            case .targetChanged:
                "当前应用、窗口或光标已经变化"
            case .composerValueChanged:
                "聊天输入框内容刚刚发生变化"
            case .textInsertionFailed:
                "无法在当前聊天输入框写入文字"
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

    static let maximumAncestorDepth = 64
    static let maximumFocusedElementScanCount = 2_048
    static let maximumNearbyAncestorDepth = 4
    static let maximumNearbyTraversalDepth = 3
    static let maximumNearbyElementCount = 128
    static let enhancedAccessibilityPollInterval: TimeInterval = 0.1
    static let enhancedAccessibilityTimeout: TimeInterval = 2
    static let codexBundleIdentifier = "com.openai.codex"
    static let editableInputRoles = Set([
        kAXTextAreaRole as String,
        kAXTextFieldRole as String,
    ])

    private let system: any AccessibilitySystemProviding
    private let pollInterval: TimeInterval
    private var preparedCaptureLock: PreparedCaptureLock?

    private struct PreparedCaptureLock {
        let processIdentifier: pid_t
        let bundleIdentifier: String
        let window: AnyObject
    }

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

    func prepareTargetCapture() async throws {
        preparedCaptureLock = nil
        guard system.isProcessTrusted else {
            throw AXError.permissionMissing
        }
        guard let pid = system.frontmostPID,
              pid > 0,
              system.frontmostBundleIdentifier == Self.codexBundleIdentifier
        else {
            return
        }

        let lockedWindow = try system.focusedWindow(processIdentifier: pid)
        guard try system.processIdentifier(of: lockedWindow) == pid else {
            throw AXError.targetChanged
        }
        let captureLock = PreparedCaptureLock(
            processIdentifier: pid,
            bundleIdentifier: Self.codexBundleIdentifier,
            window: lockedWindow
        )
        var prepared = false
        defer {
            if !prepared {
                preparedCaptureLock = nil
            }
        }
        try system.enableEnhancedAccessibility(processIdentifier: pid)
        let maximumSleeps = Int(
            ceil(
                Self.enhancedAccessibilityTimeout
                    / Self.enhancedAccessibilityPollInterval
            )
        )
        for attempt in 0...maximumSleeps {
            guard system.frontmostPID == pid,
                  system.frontmostBundleIdentifier == Self.codexBundleIdentifier
            else {
                throw AXError.targetChanged
            }
            let currentWindow = try system.focusedWindow(processIdentifier: pid)
            guard system.elementsAreEqual(currentWindow, lockedWindow) else {
                throw AXError.targetChanged
            }
            if try accessibilityTreeContainsCodexChatInput(
                processIdentifier: pid,
                window: lockedWindow
            ) {
                preparedCaptureLock = captureLock
                prepared = true
                return
            }
            guard attempt < maximumSleeps else {
                preparedCaptureLock = captureLock
                prepared = true
                return
            }
            try await system.sleep(
                for: Self.enhancedAccessibilityPollInterval
            )
        }
    }

    func captureTarget() throws -> FocusedTargetSnapshot {
        let captureLock = preparedCaptureLock
        defer { preparedCaptureLock = nil }
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
        if let captureLock {
            guard pid == captureLock.processIdentifier,
                  bundleIdentifier == captureLock.bundleIdentifier,
                  system.elementsAreEqual(window, captureLock.window)
            else {
                throw AXError.targetChanged
            }
        }
        let captured = try captureElement(
            processIdentifier: pid,
            bundleIdentifier: bundleIdentifier,
            window: window
        )
        guard try system.processIdentifier(of: window) == pid,
              try system.processIdentifier(of: captured.element) == pid
        else {
            throw AXError.focusedElementUnavailable
        }
        let context = try makeContext(
            focused: captured.element,
            window: window,
            expectedPID: pid
        )
        return FocusedTargetSnapshot(
            processIdentifier: pid,
            bundleIdentifier: bundleIdentifier,
            window: window,
            element: captured.element,
            context: context,
            allowsEquivalentFocusReplacement: captured.wasAutoFocused
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
        let element = try resolveFocusedElement(
            processIdentifier: target.processIdentifier,
            window: window
        )
        guard try system.processIdentifier(of: window) == target.processIdentifier,
              try system.processIdentifier(of: element) == target.processIdentifier,
              system.elementsAreEqual(window, target.window)
        else {
            throw AXError.targetChanged
        }
        guard !system.elementsAreEqual(element, target.element) else { return }
        guard target.allowsEquivalentFocusReplacement else {
            throw AXError.targetChanged
        }

        let latestContext: FocusedChatContext
        do {
            guard try isEditableInput(
                element,
                expectedProcessIdentifier: target.processIdentifier
            ) else {
                throw AXError.targetChanged
            }
            latestContext = try makeContext(
                focused: element,
                window: window,
                expectedPID: target.processIdentifier
            )
        } catch {
            throw AXError.targetChanged
        }
        guard latestContext == target.context else {
            throw AXError.targetChanged
        }
        target.replaceAutoFocusedElement(element)
    }

    func composerValue(in target: FocusedTargetSnapshot) throws -> String {
        try system.composerValue(of: target.element)
    }

    func setComposerValue(
        _ value: String,
        expectedCurrentValue: String,
        in target: FocusedTargetSnapshot
    ) throws {
        try revalidate(target)
        try system.setComposerValue(
            value,
            expectedCurrentValue: expectedCurrentValue,
            on: target.element
        )
        target.consumeEquivalentFocusReplacementAllowance()
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
                  children.allSatisfy({
                      CFGetTypeID($0) == AXUIElementGetTypeID()
                  })
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

    private func captureElement(
        processIdentifier: pid_t,
        bundleIdentifier: String,
        window: AnyObject
    ) throws -> (element: AnyObject, wasAutoFocused: Bool) {
        let current: AnyObject?
        do {
            current = try resolveFocusedElement(
                processIdentifier: processIdentifier,
                window: window
            )
        } catch AXError.focusedElementUnavailable {
            current = nil
        }

        if let current {
            if try isEditableInput(
                current,
                expectedProcessIdentifier: processIdentifier
            ) {
                return (current, false)
            }
            guard bundleIdentifier == Self.codexBundleIdentifier else {
                return (current, false)
            }
        } else if bundleIdentifier != Self.codexBundleIdentifier {
            throw AXError.focusedElementUnavailable
        }

        return (
            try focusUniqueCodexChatInput(
                processIdentifier: processIdentifier,
                bundleIdentifier: bundleIdentifier,
                window: window
            ),
            true
        )
    }

    private func isEditableInput(
        _ element: AnyObject,
        expectedProcessIdentifier: pid_t
    ) throws -> Bool {
        guard try system.processIdentifier(of: element)
            == expectedProcessIdentifier else {
            throw AXError.focusedElementUnavailable
        }
        let summary = try system.summary(of: element, parentIndex: nil)
        return summary.enabled
            && summary.valueSettable
            && Self.editableInputRoles.contains(summary.role ?? "")
    }

    private func focusUniqueCodexChatInput(
        processIdentifier: pid_t,
        bundleIdentifier: String,
        window: AnyObject
    ) throws -> AnyObject {
        let candidates = try codexChatInputCandidates(
            processIdentifier: processIdentifier,
            window: window,
            stopAfter: 2
        )
        guard candidates.count == 1, let candidate = candidates.first else {
            if candidates.count > 1 {
                throw AXError.ambiguousChatInput
            }
            throw AXError.focusedElementUnavailable
        }
        try system.setFocusedElement(candidate)
        return try confirmAutoFocusedElement(
            candidate,
            processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier,
            window: window
        )
    }

    private func accessibilityTreeContainsCodexChatInput(
        processIdentifier: pid_t,
        window: AnyObject
    ) throws -> Bool {
        try !codexChatInputCandidates(
            processIdentifier: processIdentifier,
            window: window,
            stopAfter: 1
        ).isEmpty
    }

    private func codexChatInputCandidates(
        processIdentifier: pid_t,
        window: AnyObject,
        stopAfter: Int
    ) throws -> [AnyObject] {
        var queue = try system.children(of: window)
        var offset = 0
        var matches: [AnyObject] = []
        while offset < queue.count {
            guard offset < Self.maximumFocusedElementScanCount else {
                throw AXError.accessibilityTreeTruncated
            }
            let candidate = queue[offset]
            offset += 1
            if try isEditableInput(
                candidate,
                expectedProcessIdentifier: processIdentifier
            ) {
                let context = try makeContext(
                    focused: candidate,
                    window: window,
                    expectedPID: processIdentifier
                )
                let isolatedContext = FocusedChatContext(
                    focused: context.focused,
                    ancestors: context.ancestors,
                    nearby: context.nearby.filter {
                        !($0.enabled
                            && $0.valueSettable
                            && Self.editableInputRoles.contains($0.role ?? ""))
                    }
                )
                do {
                    _ = try ChatTargetClassifier().classify(
                        bundleIdentifier: Self.codexBundleIdentifier,
                        context: isolatedContext
                    )
                    matches.append(candidate)
                    if matches.count >= stopAfter { return matches }
                } catch is ChatTargetClassificationError {
                    // Continue scanning; this editable element is not a chat composer.
                }
            }
            queue.append(contentsOf: try system.children(of: candidate))
        }
        return matches
    }

    private func confirmAutoFocusedElement(
        _ candidate: AnyObject,
        processIdentifier: pid_t,
        bundleIdentifier: String,
        window: AnyObject
    ) throws -> AnyObject {
        guard system.frontmostPID == processIdentifier,
              system.frontmostBundleIdentifier == bundleIdentifier
        else {
            throw AXError.targetChanged
        }

        let latestWindow: AnyObject
        let latestElement: AnyObject
        do {
            latestWindow = try system.focusedWindow(
                processIdentifier: processIdentifier
            )
            latestElement = try resolveFocusedElement(
                processIdentifier: processIdentifier,
                window: latestWindow
            )
        } catch {
            throw AXError.targetChanged
        }

        guard system.elementsAreEqual(latestWindow, window),
              system.elementsAreEqual(latestElement, candidate),
              try system.processIdentifier(of: latestElement)
                == processIdentifier
        else {
            throw AXError.targetChanged
        }
        return candidate
    }

    private func resolveFocusedElement(
        processIdentifier: pid_t,
        window: AnyObject
    ) throws -> AnyObject {
        do {
            return try system.focusedElement(processIdentifier: processIdentifier)
        } catch AXError.focusedElementUnavailable {
            var queue = try system.children(of: window)
            var offset = 0
            while offset < queue.count {
                guard offset < Self.maximumFocusedElementScanCount else {
                    throw AXError.accessibilityTreeTruncated
                }
                let candidate = queue[offset]
                offset += 1
                if try system.isFocused(candidate) {
                    return candidate
                }
                queue.append(contentsOf: try system.children(of: candidate))
            }
            throw AXError.focusedElementUnavailable
        }
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

    func enableEnhancedAccessibility(processIdentifier: pid_t) throws {
        let application = AXUIElementCreateApplication(processIdentifier)
        let attribute = "AXEnhancedUserInterface" as CFString
        var current: CFTypeRef?
        let readResult = AXUIElementCopyAttributeValue(
            application,
            attribute,
            &current
        )
        if readResult == .success, current as? Bool == true {
            return
        }
        let setResult = AXUIElementSetAttributeValue(
            application,
            attribute,
            kCFBooleanTrue
        )
        guard setResult == .success || setResult == .cannotComplete else {
            throw AccessibilityClient.AXError.focusedElementUnavailable
        }
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
            throw AccessibilityClient.AXError.focusedElementUnavailable
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
        switch readAttribute(axElement(element), kAXParentAttribute as CFString) {
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

    func isFocused(_ element: AnyObject) throws -> Bool {
        switch readAttribute(
            axElement(element),
            kAXFocusedAttribute as CFString
        ) {
        case .absent:
            return false
        case .failure:
            throw AccessibilityClient.AXError.invalidAccessibilityTree
        case .value(let value):
            guard let focused = value as? Bool else {
                throw AccessibilityClient.AXError.invalidAccessibilityTree
            }
            return focused
        }
    }

    func setFocusedElement(_ element: AnyObject) throws {
        guard AXUIElementSetAttributeValue(
            axElement(element),
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        ) == .success else {
            throw AccessibilityClient.AXError.focusedElementUnavailable
        }
    }

    func children(of element: AnyObject) throws -> [AnyObject] {
        let element = axElement(element)
        let regular = try AccessibilityClient.validatedChildren(
            readAttribute(element, kAXChildrenAttribute as CFString)
        )
        let navigationOrder = try AccessibilityClient.validatedChildren(
            readAttribute(element, "AXChildrenInNavigationOrder" as CFString)
        )
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
        return try AccessibilityClient.validatedSummary(
            parentIndex: parentIndex,
            role: readAttribute(element, kAXRoleAttribute as CFString),
            subrole: readAttribute(element, kAXSubroleAttribute as CFString),
            title: readAttribute(element, kAXTitleAttribute as CFString),
            description: readAttribute(
                element,
                kAXDescriptionAttribute as CFString
            ),
            value: .absent,
            enabled: readAttribute(element, kAXEnabledAttribute as CFString),
            valueSettable: valueSettableRead(
                result: settableResult,
                value: settable.boolValue
            )
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

    func setComposerValue(
        _ value: String,
        expectedCurrentValue: String,
        on element: AnyObject
    ) throws {
        let element = axElement(element)
        guard try composerValue(of: element) == expectedCurrentValue else {
            throw AccessibilityClient.AXError.composerValueChanged
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              pid > 0,
              AXUIElementSetAttributeValue(
                  element,
                  kAXFocusedAttribute as CFString,
                  kCFBooleanTrue
              ) == .success,
              let source = CGEventSource(stateID: .hidSystemState)
        else {
            throw AccessibilityClient.AXError.textInsertionFailed
        }
        guard try composerValue(of: element) == expectedCurrentValue else {
            throw AccessibilityClient.AXError.composerValueChanged
        }

        if value.isEmpty {
            guard let selectAllDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: true
            ),
                let selectAllUp = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: 0,
                    keyDown: false
                ),
                let deleteDown = CGEvent(
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
                throw AccessibilityClient.AXError.textInsertionFailed
            }
            selectAllDown.flags = .maskCommand
            selectAllUp.flags = .maskCommand
            selectAllDown.postToPid(pid)
            selectAllUp.postToPid(pid)
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
            throw AccessibilityClient.AXError.textInsertionFailed
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
