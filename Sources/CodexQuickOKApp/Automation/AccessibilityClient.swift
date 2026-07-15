import AppKit
import ApplicationServices
import Foundation

@MainActor
protocol AccessibilityControlling: AnyObject {
    func activateCodex() throws
    func openThreadURL(sessionId: String) throws
    func waitForTask(title: String, cwd: String, timeout: TimeInterval) async throws
    func currentTaskMatches(title: String, cwd: String) throws -> Bool
    func frontmostBundleIdentifier() -> String?
    func composerValue() throws -> String
    func setComposerValue(_ value: String) throws
    func pressSend() throws
}

@MainActor
final class AccessibilityClient: AccessibilityControlling {
    enum AXError: Error, Equatable {
        case permissionMissing
        case codexNotRunning
        case taskNotFound
        case ambiguousTask
        case composerMissing
        case nativeApprovalCard
        case sendActionMissing
    }

    struct ElementSummary: Equatable {
        let role: String?
        let title: String?
        let description: String?
        let enabled: Bool
        let valueSettable: Bool
    }

    struct ControlSelection: Equatable {
        let composerIndex: Int
        let sendButtonIndex: Int
    }

    private static let codexBundleIdentifier = "com.openai.codex"
    private static let pathComponentCharacters = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "-._~"))

    private var composer: AXUIElement?
    private var sendButton: AXUIElement?

    func activateCodex() throws {
        guard AXIsProcessTrusted() else {
            throw AXError.permissionMissing
        }
        guard let app = codexApplication() else {
            throw AXError.codexNotRunning
        }
        app.activate()
    }

    func openThreadURL(sessionId: String) throws {
        let url = try Self.threadURL(sessionId: sessionId)
        guard NSWorkspace.shared.open(url) else {
            throw AXError.taskNotFound
        }
    }

    func waitForTask(title: String, cwd: String, timeout: TimeInterval) async throws {
        composer = nil
        sendButton = nil
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if try currentTaskMatches(title: title, cwd: cwd) {
                let elements = try descendants()
                let selection = try Self.selectControls(
                    in: elements.map(elementSummary)
                )
                composer = elements[selection.composerIndex]
                sendButton = elements[selection.sendButtonIndex]
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline

        throw AXError.taskNotFound
    }

    func currentTaskMatches(title: String, cwd: String) throws -> Bool {
        let strings = try descendants().flatMap { element in
            [
                string(element, kAXValueAttribute as CFString),
                string(element, kAXTitleAttribute as CFString),
                string(element, kAXDescriptionAttribute as CFString),
            ].compactMap { $0 }
        }
        return strings.contains(title) && strings.contains(where: { $0.contains(cwd) })
    }

    func frontmostBundleIdentifier() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    func composerValue() throws -> String {
        guard let composer else {
            throw AXError.composerMissing
        }
        return string(composer, kAXValueAttribute as CFString) ?? ""
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

    static func threadURL(sessionId: String) throws -> URL {
        guard !sessionId.isEmpty,
              let encoded = sessionId.addingPercentEncoding(
                  withAllowedCharacters: pathComponentCharacters
              ),
              let url = URL(string: "codex://threads/\(encoded)")
        else {
            throw AXError.taskNotFound
        }
        return url
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

    private func descendants() throws -> [AXUIElement] {
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

        var queue = [focusedWindow]
        var result: [AXUIElement] = []
        while !queue.isEmpty && result.count < 5_000 {
            let element = queue.removeFirst()
            result.append(element)
            queue.append(contentsOf: children(element))
        }
        return result
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

    private func elementSummary(_ element: AXUIElement) -> ElementSummary {
        var settable = DarwinBoolean(false)
        let settableResult = AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &settable
        )
        return ElementSummary(
            role: string(element, kAXRoleAttribute as CFString),
            title: string(element, kAXTitleAttribute as CFString),
            description: string(element, kAXDescriptionAttribute as CFString),
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
