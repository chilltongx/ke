import AppKit
import ApplicationServices
import Foundation

@MainActor
protocol AccessibilityControlling: AnyObject {
    func activateCodex() throws
    func waitForFocusedConversation(timeout: TimeInterval) async throws
    func frontmostBundleIdentifier() -> String?
    func composerValue() throws -> String
    func setComposerValue(_ value: String) throws
    func pressSend() throws
}

@MainActor
final class AccessibilityClient: AccessibilityControlling {
    enum AXError: Error, Equatable, LocalizedError {
        case permissionMissing
        case codexNotRunning
        case taskNotFound
        case ambiguousTask
        case composerMissing
        case composerValueUnreadable
        case nativeApprovalCard
        case sendActionMissing

        var errorDescription: String? {
            switch self {
            case .permissionMissing:
                "请在系统设置的辅助功能中启用 Codex 可"
            case .codexNotRunning:
                "Codex 尚未运行"
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
            }
        }
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

    private static let codexBundleIdentifier = "com.openai.codex"

    private var composer: AXUIElement?
    private var sendButton: AXUIElement?

    private struct ElementTree {
        let elements: [AXUIElement]
        let summaries: [ElementSummary]
    }

    func activateCodex() throws {
        guard AXIsProcessTrusted() else {
            throw AXError.permissionMissing
        }
        guard let app = codexApplication() else {
            throw AXError.codexNotRunning
        }
        guard app.activate(options: [.activateIgnoringOtherApps]) else {
            throw AXError.taskNotFound
        }
    }

    func waitForFocusedConversation(timeout: TimeInterval) async throws {
        composer = nil
        sendButton = nil
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            do {
                let tree = try elementTree()
                let selection = try Self.selectFocusedConversationControls(
                    in: tree.summaries
                )
                composer = tree.elements[selection.composerIndex]
                sendButton = tree.elements[selection.sendButtonIndex]
                return
            } catch let error as AXError {
                switch error {
                case .taskNotFound, .composerMissing, .sendActionMissing:
                    break
                case .permissionMissing, .codexNotRunning, .ambiguousTask,
                     .composerValueUnreadable, .nativeApprovalCard:
                    throw error
                }
            }

            if Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
        } while Date() < deadline

        throw AXError.taskNotFound
    }

    func frontmostBundleIdentifier() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    func composerValue() throws -> String {
        guard let composer else {
            throw AXError.composerMissing
        }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            composer,
            kAXValueAttribute as CFString,
            &value
        )
        return try Self.validatedComposerValue(
            attributeReadSucceeded: result == .success,
            value: value
        )
    }

    func setComposerValue(_ value: String) throws {
        guard let composer, sendButton != nil else {
            throw AXError.composerMissing
        }
        guard AXUIElementSetAttributeValue(
            composer,
            kAXValueAttribute as CFString,
            value as CFString
        ) == .success else {
            throw AXError.composerMissing
        }
    }

    func pressSend() throws {
        guard let sendButton else {
            throw AXError.sendActionMissing
        }
        guard AXUIElementPerformAction(
            sendButton,
            kAXPressAction as CFString
        ) == .success else {
            throw AXError.sendActionMissing
        }
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
            guard element.role == kAXButtonRole as String else {
                return false
            }
            let labels = [element.title, element.description]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            return labels.contains(where: { ["send", "send message", "发送", "发送消息"].contains($0) })
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
                case .permissionMissing, .codexNotRunning, .taskNotFound,
                     .ambiguousTask, .composerValueUnreadable, .nativeApprovalCard:
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

    private static func isNativeApprovalControl(_ element: ElementSummary) -> Bool {
        guard element.role == kAXButtonRole as String else {
            return false
        }
        let labels = [element.title, element.description]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return labels.contains { label in
            label.hasPrefix("approve")
                || label.hasPrefix("allow")
                || label.contains("批准")
                || label.contains("允许")
        }
    }

    private func codexApplication() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.codexBundleIdentifier
        ).first
    }

    private static func hasValidHierarchy(_ elements: [ElementSummary]) -> Bool {
        for index in elements.indices {
            guard let parent = elements[index].parentIndex else {
                continue
            }
            guard elements.indices.contains(parent), parent < index else {
                return false
            }
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
            if parent == ancestor {
                return true
            }
            current = elements[parent].parentIndex
        }
        return false
    }

    private func elementTree() throws -> ElementTree {
        guard let app = codexApplication() else {
            throw AXError.codexNotRunning
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedValue
        ) == .success,
            let focusedValue
        else {
            throw AXError.taskNotFound
        }
        let focusedWindow = focusedValue as! AXUIElement

        var queue: [(element: AXUIElement, parentIndex: Int?)] = [(focusedWindow, nil)]
        var elements: [AXUIElement] = []
        var summaries: [ElementSummary] = []
        while !queue.isEmpty && elements.count < 5_000 {
            let next = queue.removeFirst()
            let index = elements.count
            elements.append(next.element)
            summaries.append(elementSummary(next.element, parentIndex: next.parentIndex))
            queue.append(
                contentsOf: children(next.element).map {
                    (element: $0, parentIndex: Optional(index))
                }
            )
        }
        return ElementTree(elements: elements, summaries: summaries)
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }

    private func elementSummary(
        _ element: AXUIElement,
        parentIndex: Int?
    ) -> ElementSummary {
        var settable = DarwinBoolean(false)
        let settableResult = AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &settable
        )
        return ElementSummary(
            parentIndex: parentIndex,
            role: string(element, kAXRoleAttribute as CFString),
            subrole: string(element, kAXSubroleAttribute as CFString),
            title: string(element, kAXTitleAttribute as CFString),
            description: string(element, kAXDescriptionAttribute as CFString),
            value: string(element, kAXValueAttribute as CFString),
            enabled: boolean(element, kAXEnabledAttribute as CFString) ?? true,
            valueSettable: settableResult == .success && settable.boolValue
        )
    }

    private func string(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func boolean(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? Bool
    }
}
