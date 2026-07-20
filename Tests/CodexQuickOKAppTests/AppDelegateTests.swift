import AppKit
import CodexQuickOKCore
import Foundation
import ServiceManagement
import XCTest
@testable import CodexQuickOKApp

@MainActor
final class AppDelegateManualModeTests: XCTestCase {
    func testManualRuntimeShowsImmediatelyAndReopenRestoresIt() {
        let panel = RecordingPanel()
        let delegate = makeDelegate()
        delegate.configureManualRuntime(panel: panel, sender: StubSender())

        XCTAssertEqual(panel.lastMode, .running)
        panel.hide()
        XCTAssertTrue(
            delegate.applicationShouldHandleReopen(
                NSApplication.shared,
                hasVisibleWindows: false
            )
        )
        XCTAssertEqual(panel.lastMode, .running)
    }

    func testRemovesEnabledLegacyLoginItem() async {
        let loginItem = FakeLoginItemManager(status: .enabled)
        let delegate = makeDelegate(loginItemManager: loginItem)

        delegate.removeLegacyLoginItemIfNeeded()
        await waitUntil { loginItem.unregisterCount == 1 }

        XCTAssertEqual(loginItem.unregisterCount, 1)
    }

    func testDoesNothingWhenLegacyLoginItemIsAbsent() async {
        let loginItem = FakeLoginItemManager(status: .notRegistered)
        let delegate = makeDelegate(loginItemManager: loginItem)

        delegate.removeLegacyLoginItemIfNeeded()
        await Task.yield()

        XCTAssertEqual(loginItem.unregisterCount, 0)
    }

    private func makeDelegate(
        loginItemManager: any LegacyLoginItemManaging =
            FakeLoginItemManager(status: .notRegistered)
    ) -> AppDelegate {
        AppDelegate(
            appServer: ControlledAppServer(),
            codexBinaryProvider: { URL(fileURLWithPath: "/tmp/codex") },
            terminationReply: { _ in },
            loginItemManager: loginItemManager
        )
    }
}

@MainActor
final class AppDelegateConfigurationTests: XCTestCase {
    func testTerminationWaitsForInFlightStartThenStopsBeforeReplying() async {
        let appServer = ControlledAppServer()
        var replies: [Bool] = []
        let delegate = AppDelegate(
            appServer: appServer,
            codexBinaryProvider: { URL(fileURLWithPath: "/tmp/codex") },
            terminationReply: { replies.append($0) }
        )
        delegate.beginAppServerStart()
        await waitUntil { await appServer.startCount == 1 }

        let termination = delegate.applicationShouldTerminate(NSApplication.shared)
        await spinMainActor()

        XCTAssertEqual(termination, NSApplication.TerminateReply.terminateLater)
        XCTAssertTrue(delegate.isShuttingDown)

        await waitUntil { !replies.isEmpty }

        XCTAssertEqual(replies, [true])
        let events = await appServer.events
        XCTAssertEqual(events, ["start", "stop", "start-finished", "stop"])
        XCTAssertFalse(delegate.isAppServerStarted)
    }

    func testTerminationPhaseRetainsLifecycleOwnerUntilStopReplies() async {
        let appServer = ControlledAppServer()
        var replies: [Bool] = []
        var delegate: AppDelegate? = AppDelegate(
            appServer: appServer,
            codexBinaryProvider: { URL(fileURLWithPath: "/tmp/codex") },
            terminationReply: { replies.append($0) }
        )
        delegate?.beginAppServerStart()
        await waitUntil { await appServer.startCount == 1 }

        _ = delegate?.applicationShouldTerminate(NSApplication.shared)
        delegate = nil

        await waitUntil { !replies.isEmpty }
        XCTAssertEqual(replies, [true])
        let stopCount = await appServer.stopCount
        XCTAssertEqual(stopCount, 2)
    }

    func testQuotaRefreshUsesFiveMinuteInterval() {
        XCTAssertEqual(AppDelegate.quotaRefreshInterval, 300)
    }

    func testReconnectBackoffCapsAtFiveMinutes() {
        XCTAssertEqual(AppDelegate.reconnectDelay(forAttempt: 0), 1)
        XCTAssertEqual(AppDelegate.reconnectDelay(forAttempt: 1), 2)
        XCTAssertEqual(AppDelegate.reconnectDelay(forAttempt: 8), 256)
        XCTAssertEqual(AppDelegate.reconnectDelay(forAttempt: 9), 300)
        XCTAssertEqual(AppDelegate.reconnectDelay(forAttempt: 40), 300)
    }

    func testCodexBinaryMustBeExecutableInsideExactAppBundle() throws {
        let appURL = URL(fileURLWithPath: "/Applications/Codex.app")

        let binary = try AppDelegate.codexBinaryURL(
            appURL: appURL,
            isExecutable: { $0 == "/Applications/Codex.app/Contents/Resources/codex" }
        )

        XCTAssertEqual(binary.path, "/Applications/Codex.app/Contents/Resources/codex")
        XCTAssertThrowsError(
            try AppDelegate.codexBinaryURL(appURL: appURL, isExecutable: { _ in false })
        )
        XCTAssertEqual(AppDelegate.codexBundleIdentifier, "com.openai.codex")
    }
}

@MainActor
private final class FakeLoginItemManager: LegacyLoginItemManaging {
    let status: SMAppService.Status
    private(set) var unregisterCount = 0

    init(status: SMAppService.Status) {
        self.status = status
    }

    func unregister() async throws {
        unregisterCount += 1
    }
}

private actor ControlledAppServer: CodexAppServerServing {
    enum TestError: Error {
        case unavailable
    }

    private var startContinuation: CheckedContinuation<Void, Never>?
    private(set) var events: [String] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(codexBinary: URL) async throws {
        startCount += 1
        events.append("start")
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
        events.append("start-finished")
    }

    func readRateLimits() async throws -> RateLimitsReadResult {
        throw TestError.unavailable
    }

    func setRateLimitUpdateHandler(
        _ handler: @escaping @Sendable () -> Void
    ) async throws {}

    func stop() async {
        stopCount += 1
        events.append("stop")
        if stopCount == 1 {
            startContinuation?.resume()
            startContinuation = nil
        }
    }
}

@MainActor
private func spinMainActor(iterations: Int = 10) async {
    for _ in 0..<iterations {
        await Task.yield()
    }
}

@MainActor
private func waitUntil(
    _ condition: @escaping @MainActor () async -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    for _ in 0..<1_000 {
        if await condition() { return }
        await Task.yield()
    }
    XCTFail("Condition was not met", file: file, line: line)
}
