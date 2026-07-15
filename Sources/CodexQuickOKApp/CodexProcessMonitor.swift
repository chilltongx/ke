import AppKit

@MainActor
final class CodexProcessMonitor: NSObject {
    static let codexBundleIdentifier = "com.openai.codex"

    var onChange: ((Bool) -> Void)?

    private let notificationCenter: NotificationCenter
    private let isCodexRunningProvider: () -> Bool
    private let bundleIdentifierFromNotification: (Notification) -> String?
    private var started = false

    override convenience init() {
        self.init(
            notificationCenter: NSWorkspace.shared.notificationCenter,
            isCodexRunning: {
                !NSRunningApplication.runningApplications(
                    withBundleIdentifier: CodexProcessMonitor.codexBundleIdentifier
                ).isEmpty
            }
        )
    }

    init(
        notificationCenter: NotificationCenter,
        isCodexRunning: @escaping () -> Bool,
        bundleIdentifierFromNotification: @escaping (Notification) -> String? = {
            ($0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .bundleIdentifier
        }
    ) {
        self.notificationCenter = notificationCenter
        self.isCodexRunningProvider = isCodexRunning
        self.bundleIdentifierFromNotification = bundleIdentifierFromNotification
        super.init()
    }

    func start() {
        guard !started else { return }
        started = true
        notificationCenter.addObserver(
            self,
            selector: #selector(applicationChanged(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(applicationChanged(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        onChange?(isCodexRunningProvider())
    }

    func stop() {
        guard started else { return }
        notificationCenter.removeObserver(self)
        started = false
    }

    @objc private func applicationChanged(_ notification: Notification) {
        guard bundleIdentifierFromNotification(notification) == Self.codexBundleIdentifier else {
            return
        }
        onChange?(isCodexRunningProvider())
    }

    deinit {
        notificationCenter.removeObserver(self)
    }
}
