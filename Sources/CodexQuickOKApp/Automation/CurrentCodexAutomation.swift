import Foundation

@MainActor
protocol CurrentCodexAutomating: AnyObject {
    func activateCurrentWindow() async throws
    func revalidateTarget() throws
    func frontmostBundleIdentifier() -> String?
    func composerValue() throws -> String
    func setComposerValue(_ value: String) throws
    func performSend() throws
}

@MainActor
final class CurrentCodexAutomation: CurrentCodexAutomating {
    private let accessibility: any AccessibilityControlling

    init(accessibility: any AccessibilityControlling) {
        self.accessibility = accessibility
    }

    func activateCurrentWindow() async throws {
        try await accessibility.prepareFocusedConversation(timeout: 1.5)
    }

    func revalidateTarget() throws {
        try accessibility.revalidateFocusedConversation()
    }

    func frontmostBundleIdentifier() -> String? {
        accessibility.frontmostBundleIdentifier()
    }

    func composerValue() throws -> String {
        try accessibility.composerValue()
    }

    func setComposerValue(_ value: String) throws {
        try accessibility.setComposerValue(value)
    }

    func performSend() throws {
        try accessibility.pressSend()
    }
}
