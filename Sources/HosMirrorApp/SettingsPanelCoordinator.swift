import AppKit

/// 主应用保留设备会话，设置进程仅负责显示窗口。
@MainActor
final class SettingsPanelCoordinator {
    static let bundleName = "Screen Annex Settings.app"
    static let bundleIdentifier = "com.hosmirror.app.settings"

    private let store: SessionStore
    private let bundleURL: URL
    private var app: NSRunningApplication?
    private var channel: SettingsPanelChannel?
    private var commands: SettingsPanelPort?
    private var snapshotTimer: Timer?
    private var lastSnapshot: SettingsPanelSnapshot?
    private var pendingPresentation: SettingsPanelEvent?
    private var launching = false
    private var shuttingDown = false
    private var didAutoOpen = false

    init(store: SessionStore, bundleURL: URL) {
        self.store = store
        self.bundleURL = bundleURL
    }

    deinit { snapshotTimer?.invalidate() }

    func show(_ event: SettingsPanelEvent) {
        guard !shuttingDown else { return }
        pendingPresentation = event
        if launching { return }
        if let app, !app.isTerminated {
            deliverPresentation()
            return
        }
        reset()

        let channel = SettingsPanelChannel(id: UUID())
        guard let commands = SettingsPanelPort(name: channel.commands, receive: { [weak self] data in
            self?.receive(data)
        }) else { showLaunchError(CocoaError(.executableLoad)); return }
        self.commands = commands
        self.channel = channel
        launching = true
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = true // 使用当前安装包和当前主进程的通信端口。
        configuration.arguments = [String(ProcessInfo.processInfo.processIdentifier), channel.id.uuidString]
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { [weak self] app, error in
            Task { @MainActor [weak self] in
                guard let self, !self.shuttingDown else { app?.terminate(); return }
                self.launching = false
                guard let app else {
                    self.reset()
                    self.showLaunchError(error ?? CocoaError(.executableLoad))
                    return
                }
                self.app = app
                self.startUpdates()
            }
        }
    }

    func close() {
        shuttingDown = true
        app?.terminate()
        reset()
    }

    private func showLaunchError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = "无法打开 Screen Annex 设置"
        alert.runModal()
    }

    private func reset() {
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        lastSnapshot = nil
        app = nil
        commands = nil
        channel = nil
    }

    private func startUpdates() {
        updatePanel()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePanel() }
        }
        snapshotTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updatePanel() {
        if app?.isTerminated != false { reset(); return }
        publishSnapshot()
        deliverPresentation() // 设置进程可能还在启动，端口就绪后再展示窗口。
        if pendingPresentation == nil, !didAutoOpen, !store.isDiscovering,
           ProcessInfo.processInfo.environment["HOSMIRROR_AUTO_OPEN"] == "1",
           store.devices.count + store.androidDevices.count == 1,
           let device = store.currentDevices.first, device.unavailableReason == nil {
            didAutoOpen = true
            store.applySettingsPanelCommand(.mirror(device.id)) // 只保留原有显式调试开关。
        }
    }

    private func receive(_ data: Data) {
        guard !shuttingDown, let command = try? JSONDecoder().decode(SettingsPanelCommand.self, from: data) else { return }
        store.applySettingsPanelCommand(command)
        publishSnapshot()
    }

    private func publishSnapshot() {
        guard let channel else { return }
        let snapshot = store.settingsPanelSnapshot
        guard snapshot != lastSnapshot else { return }
        if SettingsPanelPort.send(SettingsPanelEvent.snapshot(snapshot), to: channel.events) {
            lastSnapshot = snapshot // 只有发送成功才记为已同步。
        }
    }

    private func deliverPresentation() {
        guard let event = pendingPresentation, let channel else { return }
        if SettingsPanelPort.send(event, to: channel.events) { pendingPresentation = nil }
    }
}
