import AppKit
import ApplicationServices
import XCTest
@testable import CodexQuickOKApp

final class LiveSendPipelineProbeTests: XCTestCase {
    private func postKey(
        _ keyCode: CGKeyCode,
        flags: CGEventFlags = [],
        to pid: pid_t
    ) throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .hidSystemState))
        for isDown in [true, false] {
            let event = try XCTUnwrap(
                CGEvent(
                    keyboardEventSource: source,
                    virtualKey: keyCode,
                    keyDown: isDown
                )
            )
            event.flags = flags
            event.postToPid(pid)
        }
    }

    @MainActor
    func testLiveReadOnlyState() async throws {
        guard ProcessInfo.processInfo.environment["CODEX_QUICK_OK_LIVE_TESTS"] == "1"
        else {
            throw XCTSkip("Set CODEX_QUICK_OK_LIVE_TESTS=1 for the live Codex probe")
        }
        let client = AccessibilityClient()
        try await client.prepareFocusedConversation(timeout: 3)
        print("LIVE_READ_ONLY value=\(String(reflecting: try client.composerValue()))")
    }

    @MainActor
    func testLivePipelineStopsBeforeSend() async throws {
        guard ProcessInfo.processInfo.environment["CODEX_QUICK_OK_LIVE_TESTS"] == "1"
        else {
            throw XCTSkip("Set CODEX_QUICK_OK_LIVE_TESTS=1 for the live Codex probe")
        }
        let apps = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.openai.codex"
        )
        let pid = try XCTUnwrap(apps.only?.processIdentifier)
        let client = AccessibilityClient()
        try await client.prepareFocusedConversation(timeout: 3)
        defer {
            try? postKey(0, flags: .maskCommand, to: pid)
            try? postKey(51, to: pid)
        }

        do {
            let initial = try client.composerValue()
            print("LIVE_PIPELINE initial=\(String(reflecting: initial))")
            XCTAssertEqual(initial, "")

            try client.setComposerValue("探针")
            try await client.waitUntilSendEnabled(timeout: 1.5)
            let written = try client.composerValue()
            print("LIVE_PIPELINE written=\(String(reflecting: written))")
            XCTAssertEqual(written, "探针")

            try postKey(0, flags: .maskCommand, to: pid)
            try postKey(51, to: pid)
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(try client.composerValue(), "")
        } catch {
            let current = (try? client.composerValue()).map(String.init(reflecting:)) ?? "unreadable"
            print(
                "LIVE_PIPELINE_ERROR type=\(String(reflecting: type(of: error))) "
                    + "value=\(String(reflecting: error)) current=\(current)"
            )
            throw error
        }
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
