import CodexQuickOKCore
import Foundation

protocol ThreadMetadataReading: Sendable {
    func readThreadMetadata(
        sessionId: String
    ) async throws -> CodexAppServerClient.ThreadMetadata
}

extension CodexAppServerClient: ThreadMetadataReading {}

@MainActor
final class SystemCodexAutomation: CodexAutomating {
    private let accessibility: any AccessibilityControlling
    private let metadataReader: any ThreadMetadataReading
    private var metadata: CodexAppServerClient.ThreadMetadata?

    init(accessibility: AccessibilityClient, appServer: CodexAppServerClient) {
        self.accessibility = accessibility
        self.metadataReader = appServer
    }

    init(
        accessibility: any AccessibilityControlling,
        metadataReader: any ThreadMetadataReading
    ) {
        self.accessibility = accessibility
        self.metadataReader = metadataReader
    }

    func activateAndOpen(sessionId: String) async throws {
        metadata = nil
        let metadata = try await metadataReader.readThreadMetadata(sessionId: sessionId)
        guard metadata.id == sessionId else {
            throw SendSafetyError.sessionMismatch
        }

        try accessibility.activateCodex()
        try accessibility.openThreadURL(sessionId: sessionId)
        try await accessibility.waitForTask(
            title: metadata.title,
            cwd: metadata.cwd,
            timeout: 1.5
        )
        self.metadata = metadata
    }

    func frontmostBundleIdentifier() -> String? {
        accessibility.frontmostBundleIdentifier()
    }

    func currentSessionMatches(_ sessionId: String) async throws -> Bool {
        guard let metadata, metadata.id == sessionId else {
            return false
        }
        return try accessibility.currentTaskMatches(
            title: metadata.title,
            cwd: metadata.cwd
        )
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
