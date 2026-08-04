import Foundation
import XCTest
@testable import CodexQuickOKApp

final class LiveSendPipelineProbeTests: XCTestCase {
    @MainActor
    func testLiveFocusedTargetClassification() async throws {
        guard ProcessInfo.processInfo.environment["KE_FOCUSED_CHAT_LIVE_TESTS"] == "1"
        else { throw XCTSkip("Set KE_FOCUSED_CHAT_LIVE_TESTS=1") }
        try await Task.sleep(for: .seconds(3))
        let expected = try XCTUnwrap(
            ProcessInfo.processInfo.environment["KE_EXPECTED_BUNDLE_ID"]
        )
        let client = AccessibilityClient()
        let target = try client.captureTarget()
        let match = try ChatTargetClassifier().classify(
            bundleIdentifier: target.bundleIdentifier,
            context: target.context
        )

        XCTAssertEqual(target.bundleIdentifier, expected)
        print(
            "LIVE_FOCUSED_TARGET bundle=\(target.bundleIdentifier) "
                + "kind=\(match.kind)"
        )
    }

    @MainActor
    func testLiveTextPipelineStopsBeforeReturn() async throws {
        guard ProcessInfo.processInfo.environment["KE_FOCUSED_CHAT_LIVE_TESTS"] == "1"
        else { throw XCTSkip("Set KE_FOCUSED_CHAT_LIVE_TESTS=1") }
        try await Task.sleep(for: .seconds(3))
        let expected = try XCTUnwrap(
            ProcessInfo.processInfo.environment["KE_EXPECTED_BUNDLE_ID"]
        )
        let client = AccessibilityClient()
        let target = try client.captureTarget()
        let match = try ChatTargetClassifier().classify(
            bundleIdentifier: target.bundleIdentifier,
            context: target.context
        )
        XCTAssertEqual(target.bundleIdentifier, expected)
        let initial = match.normalizedComposerValue(
            try client.composerValue(in: target)
        )
        XCTAssertTrue(
            initial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        defer { try? client.setComposerValue("", in: target) }

        try client.setComposerValue("探针", in: target)
        try await client.waitUntilComposerValue(
            "探针",
            in: target,
            timeout: 0.5
        )
        XCTAssertEqual(try client.composerValue(in: target), "探针")
    }
}
