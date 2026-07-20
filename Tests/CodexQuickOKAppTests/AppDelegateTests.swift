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

    func testReopenDuringSuspendedSendKeepsSingleInFlightAttempt() async {
        let panel = RecordingPanel()
        let sender = StubSender(suspended: true)
        let delegate = makeDelegate()
        delegate.configureManualRuntime(panel: panel, sender: sender)
        panel.onActivate?()
        await waitUntil { sender.callCount == 1 }

        panel.hide()
        _ = delegate.applicationShouldHandleReopen(
            NSApplication.shared,
            hasVisibleWindows: false
        )
        panel.onActivate?()
        await Task.yield()

        XCTAssertEqual(panel.lastMode, .running)
        XCTAssertEqual(sender.callCount, 1)

        sender.finish()
        await waitUntil { panel.successCount == 1 }
    }

    func testRemovesEnabledLegacyLoginItem() async {
        let loginItem = FakeLoginItemManager(status: .enabled)
        let delegate = makeDelegate(loginItemManager: loginItem)

        delegate.removeLegacyLoginItemIfNeeded()
        await waitUntil { loginItem.unregisterCount == 1 }

        XCTAssertEqual(loginItem.unregisterCount, 1)
    }

    func testRemovesLegacyLoginItemRequiringApproval() async {
        let loginItem = FakeLoginItemManager(status: .requiresApproval)
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

    func testDoesNothingWhenLegacyLoginItemIsNotFound() async {
        let loginItem = FakeLoginItemManager(status: .notFound)
        let delegate = makeDelegate(loginItemManager: loginItem)

        delegate.removeLegacyLoginItemIfNeeded()
        await Task.yield()

        XCTAssertEqual(loginItem.unregisterCount, 0)
    }

    func testTerminationWaitsForLegacyLoginItemRemoval() async {
        let loginItem = FakeLoginItemManager(status: .enabled, suspended: true)
        var replies: [Bool] = []
        let appServer = ControlledAppServer()
        let delegate = AppDelegate(
            appServer: appServer,
            codexBinaryProvider: { URL(fileURLWithPath: "/tmp/codex") },
            terminationReply: { replies.append($0) },
            loginItemManager: loginItem
        )
        delegate.removeLegacyLoginItemIfNeeded()
        await waitUntil { loginItem.unregisterCount == 1 }

        let termination = delegate.applicationShouldTerminate(NSApplication.shared)
        await waitUntil { await appServer.stopCount == 2 }
        await spinMainActor()

        XCTAssertEqual(termination, .terminateLater)
        XCTAssertTrue(replies.isEmpty)

        loginItem.finishUnregister()
        await waitUntil { replies == [true] }
    }

    func testLoginItemRemovalFailurePersistsAndNextLaunchRetries() async {
        let state = FakeLoginItemMigrationState()
        let failing = FakeLoginItemManager(status: .enabled)
        failing.unregisterError = FakeLoginItemManager.TestError.unregisterFailed
        let first = makeDelegate(loginItemManager: failing, loginMigrationState: state)

        first.removeLegacyLoginItemIfNeeded()
        await waitUntil { state.removalPending && failing.unregisterCount == 1 }

        XCTAssertEqual(failing.unregisterCount, 1)

        let succeeding = FakeLoginItemManager(status: .enabled)
        let second = makeDelegate(loginItemManager: succeeding, loginMigrationState: state)
        second.removeLegacyLoginItemIfNeeded()
        await waitUntil { succeeding.unregisterCount == 1 && !state.removalPending }
    }

    func testLoginItemHelperReturnsNonzeroOnUnregisterFailure() async {
        let loginItem = FakeLoginItemManager(status: .enabled)
        loginItem.unregisterError = FakeLoginItemManager.TestError.unregisterFailed
        let delegate = makeDelegate(loginItemManager: loginItem)

        let status = await delegate.unregisterLegacyLoginItemForHelper()

        XCTAssertNotEqual(status, 0)
        XCTAssertEqual(loginItem.unregisterCount, 1)
    }

    private func makeDelegate(
        loginItemManager: any LegacyLoginItemManaging =
            FakeLoginItemManager(status: .notRegistered),
        loginMigrationState: any LegacyLoginItemMigrationStateStoring =
            FakeLoginItemMigrationState()
    ) -> AppDelegate {
        AppDelegate(
            appServer: ControlledAppServer(),
            codexBinaryProvider: { URL(fileURLWithPath: "/tmp/codex") },
            terminationReply: { _ in },
            loginItemManager: loginItemManager,
            loginMigrationState: loginMigrationState
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

    func testOlderQuotaFailureCannotGrayOrStopNewerSuccessfulRefresh() async throws {
        let server = QuotaControlledAppServer()
        let panel = RecordingPanel()
        let delegate = makeQuotaDelegate(server: server, panel: panel)
        delegate.beginAppServerStart()
        await waitUntil { delegate.isAppServerStarted }
        await waitUntil { await server.readCount == 1 }
        delegate.refreshQuota()
        await waitUntil { await server.readCount == 2 }

        await server.finishRead(1, with: .success(try rateLimits(usedPercent: 25)))
        await waitUntil { panel.quotas.compactMap { $0 }.last?.remainingPercent == 75 }
        await server.finishRead(0, with: .failure(QuotaControlledAppServer.TestError.unavailable))
        await spinMainActor()

        XCTAssertEqual(panel.quotas.compactMap { $0 }.last?.remainingPercent, 75)
        let stopCount = await server.stopCount
        XCTAssertEqual(stopCount, 0)
        XCTAssertTrue(delegate.isAppServerStarted)
    }

    func testStaleConnectionNotificationCannotRefreshAfterReconnect() async {
        let server = QuotaControlledAppServer()
        let panel = RecordingPanel()
        let sleeper = ControlledReconnectSleeper()
        let delegate = makeQuotaDelegate(server: server, panel: panel, sleeper: sleeper)
        delegate.beginAppServerStart()
        await waitUntil { delegate.isAppServerStarted }
        await waitUntil { await server.readCount == 1 }
        await server.finishRead(0, with: .failure(QuotaControlledAppServer.TestError.unavailable))
        await waitUntil { sleeper.callCount == 1 }
        sleeper.release()
        await waitUntil { await server.startCount == 2 }
        await waitUntil { delegate.isAppServerStarted }
        await waitUntil { await server.readCount == 2 }

        await server.notify(handler: 0)
        await spinMainActor()
        let staleReadCount = await server.readCount
        XCTAssertEqual(staleReadCount, 2)

        await server.notify(handler: 1)
        await waitUntil { await server.readCount == 3 }
        await server.finishRead(2, with: .success(try! rateLimits(usedPercent: 40)))
    }

    func testQuotaCompletionAfterShutdownCannotPublishOrStopNewConnection() async {
        let server = QuotaControlledAppServer()
        let panel = RecordingPanel()
        var replies: [Bool] = []
        let delegate = AppDelegate(
            appServer: server,
            codexBinaryProvider: { URL(fileURLWithPath: "/tmp/codex") },
            terminationReply: { replies.append($0) }
        )
        delegate.configureManualRuntime(panel: panel, sender: StubSender())
        delegate.beginAppServerStart()
        await waitUntil { delegate.isAppServerStarted }
        await waitUntil { await server.readCount == 1 }
        let quotaCount = panel.quotas.count

        _ = delegate.applicationShouldTerminate(NSApplication.shared)
        await waitUntil { replies == [true] }
        let stopCount = await server.stopCount
        await server.finishRead(0, with: .success(try! rateLimits(usedPercent: 10)))
        await spinMainActor()

        XCTAssertEqual(panel.quotas.count, quotaCount)
        let finalStopCount = await server.stopCount
        XCTAssertEqual(finalStopCount, stopCount)
    }

    private func makeQuotaDelegate(
        server: QuotaControlledAppServer,
        panel: RecordingPanel,
        sleeper: ControlledReconnectSleeper = ControlledReconnectSleeper(immediate: true)
    ) -> AppDelegate {
        let delegate = AppDelegate(
            appServer: server,
            codexBinaryProvider: { URL(fileURLWithPath: "/tmp/codex") },
            terminationReply: { _ in },
            reconnectSleep: { delay in try await sleeper.sleep(delay) }
        )
        delegate.configureManualRuntime(panel: panel, sender: StubSender())
        return delegate
    }

    private func rateLimits(usedPercent: Double) throws -> RateLimitsReadResult {
        try JSONDecoder().decode(
            RateLimitsReadResult.self,
            from: Data("""
            {"rateLimits":{"primary":{"usedPercent":\(usedPercent),"windowDurationMins":10080,"resetsAt":1800000000}}}
            """.utf8)
        )
    }
}

@MainActor
private final class FakeLoginItemManager: LegacyLoginItemManaging {
    enum TestError: Error { case unregisterFailed }

    var status: SMAppService.Status
    private let suspended: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var unregisterCount = 0
    var unregisterError: Error?

    init(status: SMAppService.Status, suspended: Bool = false) {
        self.status = status
        self.suspended = suspended
    }

    func unregister() async throws {
        unregisterCount += 1
        if let unregisterError { throw unregisterError }
        guard suspended else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func finishUnregister() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class FakeLoginItemMigrationState: LegacyLoginItemMigrationStateStoring {
    var removalPending = false
}

private actor QuotaControlledAppServer: CodexAppServerServing {
    enum TestError: Error { case unavailable }

    private var reads: [CheckedContinuation<RateLimitsReadResult, Error>?] = []
    private var handlers: [(@Sendable () -> Void)] = []
    private(set) var startCount = 0
    private(set) var readCount = 0
    private(set) var stopCount = 0

    func start(codexBinary: URL) async throws {
        startCount += 1
    }

    func readRateLimits() async throws -> RateLimitsReadResult {
        readCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            reads.append(continuation)
        }
    }

    func setRateLimitUpdateHandler(
        _ handler: @escaping @Sendable () -> Void
    ) async throws {
        handlers.append(handler)
    }

    func stop() async {
        stopCount += 1
    }

    func finishRead(
        _ index: Int,
        with result: Result<RateLimitsReadResult, Error>
    ) {
        reads[index]?.resume(with: result)
        reads[index] = nil
    }

    func notify(handler index: Int) {
        handlers[index]()
    }
}

@MainActor
private final class ControlledReconnectSleeper: @unchecked Sendable {
    private let immediate: Bool
    private var continuation: CheckedContinuation<Void, Error>?
    private(set) var callCount = 0

    init(immediate: Bool = false) {
        self.immediate = immediate
    }

    func sleep(_ delay: TimeInterval) async throws {
        callCount += 1
        guard !immediate else { return }
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume(returning: ())
        continuation = nil
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
