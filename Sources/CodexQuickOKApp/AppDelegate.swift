import AppKit
@preconcurrency import ApplicationServices
import CodexQuickOKCore
import CoreGraphics
import Darwin
import OSLog
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    struct WindowActivationCandidate {
        let processIdentifier: pid_t
        let layer: Int
        let isRegularApplication: Bool
    }

    static let codexBundleIdentifier = "com.openai.codex"
    static let quotaRefreshInterval: TimeInterval = 300
    private static let activationLogger = Logger(
        subsystem: "com.codexquickok.CodexQuickOK",
        category: "activation"
    )

    private let appServer: any CodexAppServerServing
    private let codexBinaryProvider: () throws -> URL
    private let terminationReply: @MainActor (Bool) -> Void
    private let loginItemManager: any LegacyLoginItemManaging
    private let loginMigrationState: any LegacyLoginItemMigrationStateStoring
    private let reconnectSleep: @MainActor (TimeInterval) async throws -> Void
    private let scheduleActivationRestoration: (
        @escaping @MainActor () -> Void
    ) -> Void
    private let focusRestoreTargetProvider: () -> pid_t?
    private let restoreApplicationActivation: @MainActor (pid_t) -> Void
    private var activationRestoreTargetProcessIdentifier: pid_t?
    private var panel: (any CompanionPanel)?
    private var controller: ManualApprovalController?
    private var quotaTimer: Timer?
    private(set) var isAppServerStarted = false
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var appServerStartTask: Task<Void, Never>?
    private var loginItemRemovalTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var shutdownFinished = false
    private var connectionEpoch: UInt64 = 0
    private var quotaRequestGeneration: UInt64 = 0

    private(set) var isShuttingDown = false

    override convenience init() {
        let focusRestoreTargetProvider = {
            Self.currentFocusRestoreTargetProcessIdentifier()
        }
        let restoreTarget = focusRestoreTargetProvider()
        Self.activationLogger.notice(
            "Captured launch focus target: \(restoreTarget ?? -1, privacy: .public)"
        )
        self.init(
            appServer: CodexAppServerClient(),
            codexBinaryProvider: Self.installedCodexBinaryURL,
            terminationReply: {
                NSApplication.shared.reply(toApplicationShouldTerminate: $0)
            },
            initialActivationRestoreTargetProcessIdentifier:
                restoreTarget,
            focusRestoreTargetProvider: focusRestoreTargetProvider
        )
    }

    init(
        appServer: any CodexAppServerServing,
        codexBinaryProvider: @escaping () throws -> URL,
        terminationReply: @escaping @MainActor (Bool) -> Void,
        loginItemManager: any LegacyLoginItemManaging = MainAppLoginItemManager(),
        loginMigrationState: any LegacyLoginItemMigrationStateStoring =
            UserDefaultsLoginItemMigrationState(),
        reconnectSleep: @escaping @MainActor (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        },
        scheduleActivationRestoration: @escaping (
            @escaping @MainActor () -> Void
        ) -> Void = { operation in
            Task { @MainActor in
                await Task.yield()
                operation()
            }
        },
        initialActivationRestoreTargetProcessIdentifier: pid_t? = nil,
        focusRestoreTargetProvider: @escaping () -> pid_t? = { nil },
        restoreApplicationActivation: @escaping @MainActor (pid_t) -> Void = {
            let restored = NSRunningApplication(processIdentifier: $0)?.activate(
                options: [.activateAllWindows]
            ) ?? false
            AppDelegate.activationLogger.notice(
                "Restored launch focus target \($0, privacy: .public): \(restored, privacy: .public)"
            )
        }
    ) {
        self.appServer = appServer
        self.codexBinaryProvider = codexBinaryProvider
        self.terminationReply = terminationReply
        self.loginItemManager = loginItemManager
        self.loginMigrationState = loginMigrationState
        self.reconnectSleep = reconnectSleep
        self.scheduleActivationRestoration = scheduleActivationRestoration
        self.focusRestoreTargetProvider = focusRestoreTargetProvider
        self.restoreApplicationActivation = restoreApplicationActivation
        self.activationRestoreTargetProcessIdentifier =
            initialActivationRestoreTargetProcessIdentifier
        super.init()
    }

    static func launchFocusTargetProcessIdentifier(
        currentProcessIdentifier: pid_t,
        frontmostProcessIdentifier: pid_t?,
        windowCandidates: [WindowActivationCandidate]
    ) -> pid_t? {
        if let frontmostProcessIdentifier,
           frontmostProcessIdentifier != currentProcessIdentifier {
            return frontmostProcessIdentifier
        }

        return windowCandidates.first {
            $0.processIdentifier != currentProcessIdentifier
                && $0.layer == 0
                && $0.isRegularApplication
        }?.processIdentifier
    }

    private static func currentFocusRestoreTargetProcessIdentifier() -> pid_t? {
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        return launchFocusTargetProcessIdentifier(
            currentProcessIdentifier: getpid(),
            frontmostProcessIdentifier: frontmostApplication?.activationPolicy == .regular
                ? frontmostApplication?.processIdentifier
                : nil,
            windowCandidates: currentWindowActivationCandidates()
        )
    }

    private static func currentWindowActivationCandidates()
        -> [WindowActivationCandidate] {
        let options: CGWindowListOption = [
            .optionOnScreenOnly,
            .excludeDesktopElements,
        ]
        let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] ?? []

        return windows.compactMap { window in
            guard
                let processNumber = window[kCGWindowOwnerPID as String]
                    as? NSNumber,
                let layerNumber = window[kCGWindowLayer as String] as? NSNumber
            else { return nil }

            let processIdentifier = processNumber.int32Value
            let isRegularApplication = NSRunningApplication(
                processIdentifier: processIdentifier
            )?.activationPolicy == .regular
            return WindowActivationCandidate(
                processIdentifier: processIdentifier,
                layer: layerNumber.intValue,
                isRegularApplication: isRegularApplication
            )
        }
    }

    func configureManualRuntime(
        panel: any CompanionPanel,
        sender: any CurrentApprovalSending
    ) {
        let controller = ManualApprovalController(panel: panel, sender: sender)
        self.panel = panel
        self.controller = controller
        panel.onRefreshQuota = { [weak self] in self?.refreshQuota() }
        controller.start()
    }

    func applicationWillBecomeActive(_ notification: Notification) {
        guard let processIdentifier = focusRestoreTargetProvider(),
              processIdentifier != getpid() else { return }
        activationRestoreTargetProcessIdentifier = processIdentifier
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard let processIdentifier = activationRestoreTargetProcessIdentifier else {
            Self.activationLogger.notice("Became active without a focus target")
            return
        }
        Self.activationLogger.notice(
            "Became active; scheduling focus target \(processIdentifier, privacy: .public)"
        )
        activationRestoreTargetProcessIdentifier = nil
        scheduleActivationRestoration { [restoreApplicationActivation] in
            restoreApplicationActivation(processIdentifier)
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        controller?.show()
        return true
    }

    func removeLegacyLoginItemIfNeeded() {
        guard loginItemRemovalTask == nil else { return }
        switch loginItemManager.status {
        case .enabled, .requiresApproval:
            loginMigrationState.removalPending = true
            loginItemRemovalTask = Task { @MainActor [weak self, loginItemManager] in
                do {
                    try await loginItemManager.unregister()
                    self?.loginMigrationState.removalPending = false
                } catch {
                    self?.loginMigrationState.removalPending = true
                }
                self?.loginItemRemovalTask = nil
            }
        case .notRegistered, .notFound:
            loginMigrationState.removalPending = false
        @unknown default:
            loginMigrationState.removalPending = true
        }
    }

    func unregisterLegacyLoginItemForHelper() async -> Int32 {
        switch loginItemManager.status {
        case .notRegistered, .notFound:
            return 0
        case .enabled, .requiresApproval:
            do {
                try await loginItemManager.unregister()
                return 0
            } catch {
                return 1
            }
        @unknown default:
            return 1
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--unregister-login-item") {
            Task { @MainActor [self] in
                let status = await unregisterLegacyLoginItemForHelper()
                Darwin.exit(status)
            }
            return
        }

        showOnboardingIfNeeded()
        requestAccessibilityIfNeeded()
        removeLegacyLoginItemIfNeeded()

        let panel = FloatingPanelController()
        let accessibility = AccessibilityClient()
        let sender = FocusedChatApprovalSender(
            input: accessibility,
            classifier: ChatTargetClassifier()
        )
        configureManualRuntime(panel: panel, sender: sender)

        quotaTimer = Timer.scheduledTimer(
            withTimeInterval: Self.quotaRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshQuota()
            }
        }
        beginAppServerStart()
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        if shutdownFinished { return .terminateNow }
        if isShuttingDown { return .terminateLater }

        isShuttingDown = true
        quotaTimer?.invalidate()
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionEpoch &+= 1
        quotaRequestGeneration &+= 1
        controller?.stop()

        let startTask = appServerStartTask
        let loginItemRemovalTask = loginItemRemovalTask
        startTask?.cancel()
        shutdownTask = Task { @MainActor [self] in
            await appServer.stop()
            await startTask?.value
            await appServer.stop()
            await loginItemRemovalTask?.value
            isAppServerStarted = false
            shutdownFinished = true
            terminationReply(true)
            shutdownTask = nil
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        quotaTimer?.invalidate()
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionEpoch &+= 1
        quotaRequestGeneration &+= 1
        controller?.stop()
    }

    static func reconnectDelay(forAttempt attempt: Int) -> TimeInterval {
        let attempt = max(0, attempt)
        guard attempt < 9 else { return 300 }
        return pow(2, Double(attempt))
    }

    static func codexBinaryURL(
        appURL: URL,
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) throws -> URL {
        let binary = appURL.appendingPathComponent("Contents/Resources/codex")
        guard isExecutable(binary.path) else {
            throw CodexAppServerClient.ClientError.codexBinaryMissing
        }
        return binary
    }

    func beginAppServerStart() {
        guard !isShuttingDown, !isAppServerStarted, appServerStartTask == nil else {
            return
        }
        connectionEpoch &+= 1
        let epoch = connectionEpoch
        appServerStartTask = Task { @MainActor [weak self] in
            await self?.startAppServer(epoch: epoch)
        }
    }

    private func startAppServer(epoch: UInt64) async {
        guard !isShuttingDown, !Task.isCancelled else { return }
        do {
            let binary = try codexBinaryProvider()
            try await appServer.start(codexBinary: binary)
            guard isCurrentConnection(epoch) else { return }
            try await appServer.setRateLimitUpdateHandler { [weak self] in
                Task { @MainActor in
                    self?.rateLimitUpdated(connectionEpoch: epoch)
                }
            }
            guard isCurrentConnection(epoch), !Task.isCancelled else {
                appServerStartTask = nil
                return
            }
            isAppServerStarted = true
            reconnectAttempt = 0
            appServerStartTask = nil
            refreshQuota(connectionEpoch: epoch)
        } catch {
            guard isCurrentConnection(epoch) else { return }
            appServerStartTask = nil
            await handleConnectionFailure(epoch: epoch)
        }
    }

    func refreshQuota() {
        guard !isShuttingDown, isAppServerStarted else {
            panel?.setQuota(nil)
            return
        }
        refreshQuota(connectionEpoch: connectionEpoch)
    }

    private func refreshQuota(connectionEpoch epoch: UInt64) {
        guard isCurrentConnection(epoch), isAppServerStarted else { return }
        quotaRequestGeneration &+= 1
        let requestGeneration = quotaRequestGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await appServer.readRateLimits()
                guard isCurrentQuotaRequest(requestGeneration, epoch: epoch) else {
                    return
                }
                panel?.setQuota(QuotaSelector.weeklyQuota(from: result))
            } catch {
                guard isCurrentQuotaRequest(requestGeneration, epoch: epoch) else {
                    return
                }
                await handleConnectionFailure(epoch: epoch)
            }
        }
    }

    private func handleConnectionFailure(epoch: UInt64) async {
        guard isCurrentConnection(epoch) else { return }
        connectionEpoch &+= 1
        quotaRequestGeneration &+= 1
        let failedEpoch = connectionEpoch
        isAppServerStarted = false
        panel?.setQuota(nil)
        await appServer.stop()
        guard isCurrentConnection(failedEpoch) else { return }
        scheduleReconnect(connectionEpoch: failedEpoch)
    }

    private func rateLimitUpdated(connectionEpoch epoch: UInt64) {
        guard isCurrentConnection(epoch), isAppServerStarted else { return }
        refreshQuota(connectionEpoch: epoch)
    }

    private func scheduleReconnect(connectionEpoch epoch: UInt64) {
        guard isCurrentConnection(epoch), reconnectTask == nil else { return }
        let delay = Self.reconnectDelay(forAttempt: reconnectAttempt)
        reconnectAttempt += 1
        reconnectTask = Task { @MainActor [weak self] in
            do {
                guard let self else { return }
                try await reconnectSleep(delay)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  isCurrentConnection(epoch)
            else { return }
            reconnectTask = nil
            beginAppServerStart()
        }
    }

    private func isCurrentConnection(_ epoch: UInt64) -> Bool {
        !isShuttingDown && connectionEpoch == epoch
    }

    private func isCurrentQuotaRequest(
        _ requestGeneration: UInt64,
        epoch: UInt64
    ) -> Bool {
        isCurrentConnection(epoch)
            && isAppServerStarted
            && quotaRequestGeneration == requestGeneration
    }

    private func showOnboardingIfNeeded() {
        let key = "didShowOnboarding.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "启用 Codex 可"
        alert.informativeText = "请授予辅助功能权限。之后从 Dock 手动启动；点击悬浮的“可”按钮，会向最近使用的 Codex 窗口空输入框发送一次“可”。"
        alert.addButton(withTitle: "继续")
        alert.runModal()
        UserDefaults.standard.set(true, forKey: key)
    }

    private func requestAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private static func installedCodexBinaryURL() throws -> URL {
        guard let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: codexBundleIdentifier
        ) else {
            throw CodexAppServerClient.ClientError.codexBinaryMissing
        }
        return try codexBinaryURL(appURL: appURL)
    }
}
