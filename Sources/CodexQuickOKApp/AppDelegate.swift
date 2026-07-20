import AppKit
@preconcurrency import ApplicationServices
import CodexQuickOKCore
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let codexBundleIdentifier = "com.openai.codex"
    static let quotaRefreshInterval: TimeInterval = 300

    private let appServer: any CodexAppServerServing
    private let codexBinaryProvider: () throws -> URL
    private let terminationReply: @MainActor (Bool) -> Void
    private let loginItemManager: any LegacyLoginItemManaging
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

    private(set) var isShuttingDown = false

    override convenience init() {
        self.init(
            appServer: CodexAppServerClient(),
            codexBinaryProvider: Self.installedCodexBinaryURL,
            terminationReply: { NSApplication.shared.reply(toApplicationShouldTerminate: $0) }
        )
    }

    init(
        appServer: any CodexAppServerServing,
        codexBinaryProvider: @escaping () throws -> URL,
        terminationReply: @escaping @MainActor (Bool) -> Void,
        loginItemManager: any LegacyLoginItemManaging = MainAppLoginItemManager()
    ) {
        self.appServer = appServer
        self.codexBinaryProvider = codexBinaryProvider
        self.terminationReply = terminationReply
        self.loginItemManager = loginItemManager
        super.init()
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
            loginItemRemovalTask = Task { @MainActor [weak self, loginItemManager] in
                try? await loginItemManager.unregister()
                self?.loginItemRemovalTask = nil
            }
        case .notRegistered, .notFound:
            break
        @unknown default:
            break
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--unregister-login-item") {
            Task { @MainActor in
                try? await SMAppService.mainApp.unregister()
                NSApplication.shared.terminate(nil)
            }
            return
        }

        showOnboardingIfNeeded()
        requestAccessibilityIfNeeded()
        removeLegacyLoginItemIfNeeded()

        let panel = FloatingPanelController()
        let automation = CurrentCodexAutomation(accessibility: AccessibilityClient())
        let sender = CurrentWindowApprovalSender(automation: automation)
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
        guard !isShuttingDown, appServerStartTask == nil else { return }
        appServerStartTask = Task { @MainActor [weak self] in
            await self?.startAppServer()
        }
    }

    private func startAppServer() async {
        guard !isShuttingDown, !Task.isCancelled else { return }
        do {
            let binary = try codexBinaryProvider()
            try await appServer.start(codexBinary: binary)
            try await appServer.setRateLimitUpdateHandler { [weak self] in
                Task { @MainActor in
                    self?.refreshQuota()
                }
            }
            guard !isShuttingDown, !Task.isCancelled else {
                appServerStartTask = nil
                return
            }
            isAppServerStarted = true
            reconnectAttempt = 0
            appServerStartTask = nil
            refreshQuota()
        } catch {
            appServerStartTask = nil
            isAppServerStarted = false
            panel?.setQuota(nil)
            guard !isShuttingDown else { return }
            scheduleReconnect()
        }
    }

    private func refreshQuota() {
        guard !isShuttingDown, isAppServerStarted else {
            panel?.setQuota(nil)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await appServer.readRateLimits()
                panel?.setQuota(QuotaSelector.weeklyQuota(from: result))
            } catch {
                isAppServerStarted = false
                panel?.setQuota(nil)
                await appServer.stop()
                scheduleReconnect()
            }
        }
    }

    private func scheduleReconnect() {
        guard !isShuttingDown, reconnectTask == nil else { return }
        let delay = Self.reconnectDelay(forAttempt: reconnectAttempt)
        reconnectAttempt += 1
        reconnectTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            reconnectTask = nil
            beginAppServerStart()
        }
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
