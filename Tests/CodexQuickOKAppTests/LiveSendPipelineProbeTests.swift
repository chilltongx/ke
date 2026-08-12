import AppKit
import Foundation
import XCTest
@testable import CodexQuickOKApp

final class LiveSendPipelineProbeTests: XCTestCase {
    @MainActor
    func testLiveFocusedTargetClassification() async throws {
        guard ProcessInfo.processInfo.environment["KE_FOCUSED_CHAT_LIVE_TESTS"] == "1"
        else { throw XCTSkip("Set KE_FOCUSED_CHAT_LIVE_TESTS=1") }
        let expected = try XCTUnwrap(
            ProcessInfo.processInfo.environment["KE_EXPECTED_BUNDLE_ID"]
        )
        try await activateExpectedApplication(expected)
        let client = AccessibilityClient()
        try await client.prepareTargetCapture()
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
        let expected = try XCTUnwrap(
            ProcessInfo.processInfo.environment["KE_EXPECTED_BUNDLE_ID"]
        )
        try await activateExpectedApplication(expected)
        let client = AccessibilityClient()
        try await client.prepareTargetCapture()
        let target = try client.captureTarget()
        let match = try ChatTargetClassifier().classify(
            bundleIdentifier: target.bundleIdentifier,
            context: target.context
        )
        XCTAssertEqual(target.bundleIdentifier, expected)
        let initialRawValue = try client.composerValue(in: target)
        let initial = match.normalizedComposerValue(initialRawValue)
        XCTAssertTrue(initial.isEmpty)
        defer {
            try? client.setComposerValue(
                "",
                expectedCurrentValue: "探针",
                in: target
            )
        }

        try client.setComposerValue(
            "探针",
            expectedCurrentValue: initialRawValue,
            in: target
        )
        try await client.waitUntilComposerValue(
            "探针",
            in: target,
            timeout: 0.5
        )
        XCTAssertEqual(try client.composerValue(in: target), "探针")
    }

    @MainActor
    private func activateExpectedApplication(_ bundleIdentifier: String) async throws {
        let application = try XCTUnwrap(
            NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            ).first
        )
        XCTAssertTrue(application.activate(options: [.activateAllWindows]))
        for _ in 0..<30 {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                == bundleIdentifier {
                try await Task.sleep(for: .milliseconds(300))
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Expected application did not become frontmost")
    }
}
