import AppKit
@preconcurrency import ApplicationServices
import CodexQuickOKCore
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let codexBundleIdentifier = CodexProcessMonitor.codexBundleIdentifier
    static let quotaRefreshInterval: TimeInterval = 300

    private let appServer = CodexAppServerClient()
    private var panel: FloatingPanelController?
    private var controller: AppController?
    private var sessionMonitor: SessionDirectoryMonitor?
    private var processMonitor: CodexProcessMonitor?
    private var quotaTimer: Timer?
    private var appServerStarted = false
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var appServerStartTask: Task<Void, Never>?

    private(set) var isShuttingDown = false

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
        registerLoginItemIfNeeded()

        guard let directory = try? SessionStateStore.defaultDirectory() else {
            NSApplication.shared.terminate(nil)
            return
        }

        let store = SessionStateStore(directory: directory)
        let panel = FloatingPanelController()
        let automation = SystemCodexAutomation(
            accessibility: AccessibilityClient(),
            appServer: appServer
        )
        let sender = ApprovalSender(automation: automation) { sessionId in
            let states = (try? await store.loadAll(now: Date(), staleAfter: 43_200)) ?? []
            return SessionSnapshotEvaluator.evaluate(
                states: states,
                codexRunning: true,
                now: Date()
            ).targetSessionId == sessionId
        }
        let controller = AppController(store: store, panel: panel, sender: sender)
        let sessionMonitor = SessionDirectoryMonitor(directory: directory)
        let processMonitor = CodexProcessMonitor()

        self.panel = panel
        self.controller = controller
        self.sessionMonitor = sessionMonitor
        self.processMonitor = processMonitor

        panel.hide()
        panel.onRefreshQuota = { [weak self] in
            self?.refreshQuota()
        }
        sessionMonitor.onChange = { [weak controller] in
            Task { @MainActor in
                await controller?.reload()
            }
        }
        processMonitor.onChange = { [weak controller] running in
            Task { @MainActor in
                await controller?.updateCodexRunning(running)
            }
        }

        do {
            try sessionMonitor.start()
        } catch {
            panel.showFailure("无法监控 Codex 会话状态")
        }
        processMonitor.start()

        quotaTimer = Timer.scheduledTimer(
            withTimeInterval: Self.quotaRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshQuota()
            }
        }
        appServerStartTask = Task { @MainActor [weak self] in
            await self?.startAppServer()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        isShuttingDown = true
        quotaTimer?.invalidate()
        reconnectTask?.cancel()
        appServerStartTask?.cancel()
        controller?.stop()
        sessionMonitor?.stop()
        processMonitor?.stop()
        Task {
            await appServer.stop()
        }
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

    private func startAppServer() async {
        guard !isShuttingDown, !Task.isCancelled else { return }
        do {
            let binary = try Self.installedCodexBinaryURL()
            try await appServer.start(codexBinary: binary)
            try await appServer.setRateLimitUpdateHandler { [weak self] in
                Task { @MainActor in
                    self?.refreshQuota()
                }
            }
            guard !isShuttingDown, !Task.isCancelled else {
                await appServer.stop()
                return
            }
            appServerStarted = true
            reconnectAttempt = 0
            appServerStartTask = nil
            refreshQuota()
        } catch {
            appServerStartTask = nil
            appServerStarted = false
            panel?.setQuota(nil)
            guard !isShuttingDown else { return }
            scheduleReconnect()
        }
    }

    private func refreshQuota() {
        guard !isShuttingDown, appServerStarted else {
            panel?.setQuota(nil)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await appServer.readRateLimits()
                panel?.setQuota(QuotaSelector.weeklyQuota(from: result))
            } catch {
                appServerStarted = false
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
            appServerStartTask = Task { @MainActor [weak self] in
                await self?.startAppServer()
            }
        }
    }

    private func showOnboardingIfNeeded() {
        let key = "didShowOnboarding.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "启用 Codex 可"
        alert.informativeText = "接下来只需授予辅助功能权限，并在 Codex 的 /hooks 页面审查并信任 codex-quick-ok。登录项默认开启；没有活动任务时按钮会自动隐藏。"
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

    private func registerLoginItemIfNeeded() {
        guard SMAppService.mainApp.status == .notRegistered else { return }
        try? SMAppService.mainApp.register()
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
