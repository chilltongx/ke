import Foundation

@testable import CodexQuickOKApp

@MainActor
final class FakeCodexAutomation: CodexAutomating {
    enum FakeError: Error {
        case activationFailed
        case composerUnavailable
        case sendUnavailable
    }

    var bundleId: String?
    var matched: Bool
    var value: String
    var activationDelay: Duration?
    var activationGate: (() async throws -> Void)?
    var activationError: Error?
    var composerError: Error?
    var sendError: Error?
    var onPerformSend: (() -> Void)?
    private(set) var activatedSessionIds: [String] = []
    private(set) var writtenValues: [String] = []
    private(set) var sendCount = 0

    init(bundleId: String?, matched: Bool, value: String) {
        self.bundleId = bundleId
        self.matched = matched
        self.value = value
    }

    func activateAndOpen(sessionId: String) async throws {
        activatedSessionIds.append(sessionId)
        try await activationGate?()
        if let activationDelay {
            try await Task.sleep(for: activationDelay)
        }
        if let activationError {
            throw activationError
        }
    }

    func frontmostBundleIdentifier() -> String? {
        bundleId
    }

    func currentSessionMatches(_ sessionId: String) async throws -> Bool {
        matched
    }

    func composerValue() throws -> String {
        if let composerError {
            throw composerError
        }
        return value
    }

    func setComposerValue(_ value: String) throws {
        writtenValues.append(value)
        self.value = value
    }

    func performSend() throws {
        if let sendError {
            throw sendError
        }
        sendCount += 1
        onPerformSend?()
    }
}

@MainActor
final class FakeAccessibilityController: AccessibilityControlling {
    var bundleId: String? = "com.openai.codex"
    var currentTaskMatched = true
    private(set) var activationCount = 0
    private(set) var openedSessionIds: [String] = []
    private(set) var waitedTasks: [(title: String, cwd: String, timeout: TimeInterval)] = []
    var focusError: Error?
    private(set) var focusedConversationTimeouts: [TimeInterval] = []
    private(set) var writtenValues: [String] = []
    private(set) var sendCount = 0

    func activateCodex() throws {
        activationCount += 1
    }

    func openThreadURL(sessionId: String) throws {
        openedSessionIds.append(sessionId)
    }

    func waitForTask(title: String, cwd: String, timeout: TimeInterval) async throws {
        waitedTasks.append((title, cwd, timeout))
    }

    func currentTaskMatches(title: String, cwd: String) throws -> Bool {
        currentTaskMatched
    }

    func waitForFocusedConversation(timeout: TimeInterval) async throws {
        focusedConversationTimeouts.append(timeout)
        if let focusError { throw focusError }
    }

    func frontmostBundleIdentifier() -> String? {
        bundleId
    }

    func composerValue() throws -> String {
        ""
    }

    func setComposerValue(_ value: String) throws {
        writtenValues.append(value)
    }

    func pressSend() throws {
        sendCount += 1
    }
}

actor FakeThreadMetadataReader: ThreadMetadataReading {
    let metadata: CodexAppServerClient.ThreadMetadata
    private(set) var requestedSessionIds: [String] = []

    init(metadata: CodexAppServerClient.ThreadMetadata) {
        self.metadata = metadata
    }

    func readThreadMetadata(sessionId: String) async throws -> CodexAppServerClient.ThreadMetadata {
        requestedSessionIds.append(sessionId)
        return metadata
    }
}
