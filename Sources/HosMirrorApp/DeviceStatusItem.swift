import AppKit
import SwiftUI
import HosMirrorCore

/// 保留菜单栏入口，由系统弹出窗口承载可以着色的 SwiftUI 控件。
@MainActor
final class DeviceStatusItem: NSObject, NSPopoverDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let popover = NSPopover()
    let panel: DeviceStatusPanelModel
    private var discoveryTask: Task<Void, Never>?
    private var actionTimer: Timer?

    init(store: SessionStore, openSettings: @escaping () -> Void = {}) {
        panel = DeviceStatusPanelModel(store: store, openSettings: openSettings)
        super.init()
        panel.dismiss = { [weak self] in self?.popover.performClose(nil) }
        panel.screen = { [weak self] in self?.item.button?.window?.screen }
        popover.behavior = .transient // 点击面板外或按 Escape 由系统收起。
        popover.delegate = self
        let host = NSHostingController(rootView: DeviceStatusPanel(model: panel, store: store))
        host.sizingOptions = [.preferredContentSize] // 展开操作时，弹出窗口随内容重新布局。
        popover.contentViewController = host
        item.button?.image = NSImage(systemSymbolName: "iphone.and.arrow.forward", accessibilityDescription: "Screen Annex 设备")
        item.button?.toolTip = "Screen Annex 设备"
        item.button?.target = self
        item.button?.action = #selector(togglePanel(_:))
        discoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5), tolerance: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                if !self.popover.isShown { self.panel.store.refreshDevices() }
            }
        }
    }

    deinit {
        discoveryTask?.cancel()
        actionTimer?.invalidate()
    }

    @objc private func togglePanel(_ button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        panel.heightLimit = min(620, (button.window?.screen?.visibleFrame.height ?? 680) - 36)
        panel.store.refreshDevices()
        panel.refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey() // 面板可接收键盘操作，也采用窗口内的原生开启色。
    }

    func popoverDidShow(_ notification: Notification) {
        item.button?.highlight(true)
        actionTimer?.invalidate()
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel.refresh() }
        }
        actionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func popoverDidClose(_ notification: Notification) {
        item.button?.highlight(false)
        actionTimer?.invalidate()
        actionTimer = nil
    }
}

/// 面板只转发用户动作，设备状态和偏好仍由会话存储管理。
@MainActor
final class DeviceStatusPanelModel: ObservableObject {
    struct Availability: Equatable {
        var connectAll = false
        var systemActions = false
        var pinEnabled = false
        var pinned = false
        var snapping = false
    }

    let store: SessionStore
    @Published private(set) var availability = Availability()
    @Published private(set) var failure: String?
    @Published private(set) var actionRunning = false
    @Published var heightLimit: CGFloat = 620
    var dismiss: () -> Void = {}
    var screen: () -> NSScreen? = { nil }
    private let openSettings: () -> Void

    init(store: SessionStore, openSettings: @escaping () -> Void) {
        self.store = store
        self.openSettings = openSettings
    }

    func refresh() {
        let active = store.activeMirrorControllers
        let available = !actionRunning && !active.isEmpty
        let pinEnabled = available && !store.isApplyingWindowPin
        let pinned = store.isApplyingWindowPin ? availability.pinned : !active.isEmpty && active.allSatisfy(\.isAlwaysOnTop)
        let next = Availability(connectAll: !actionRunning && !store.batchConnectionTargets.isEmpty,
                                systemActions: available, pinEnabled: pinEnabled, pinned: pinned,
                                snapping: MirrorWindowSnap.shared.isEnabled)
        if next != availability { availability = next }
    }

    func connectAll() {
        guard !actionRunning else { return }
        let targets = store.batchConnectionTargets
        guard !targets.isEmpty else { return }
        dismiss()
        for entry in targets { open(entry.device) }
    }

    func setConnection(_ enabled: Bool, id: String) {
        guard let entry = store.currentDevices.first(where: { $0.id == id }) else { return }
        let device = entry.device
        let controller = store.controller(for: device.serial, platform: device.platform, model: device.model)
        guard enabled != connectionIsOn(controller), !enabled || entry.unavailableReason == nil else { return }
        dismiss()
        if enabled { open(device) }
        else { controller.disconnect() }
    }

    func connectionIsOn(_ controller: DeviceController) -> Bool {
        controller.connected || controller.busy || controller.reconnectPending
    }

    func setAutomaticPin(_ enabled: Bool) {
        var settings = store.settings
        settings.alwaysOnTop = enabled
        store.update(settings: settings)
    }

    func setSnapping(_ enabled: Bool) {
        MirrorWindowSnap.shared.setEnabled(enabled, on: screen() ?? NSScreen.main)
        refresh()
    }

    func setPin(_ enabled: Bool, id: String? = nil) {
        guard !actionRunning else { return }
        if let id {
            guard let controller = availableController(id), !controller.busy, !controller.isRestartingForWindowPin else { return }
            store.setAlwaysOnTop(enabled, for: [controller], applyToRunningAndroid: true)
        } else {
            guard !store.isApplyingWindowPin else { return }
            availability.pinned = enabled // Android 应用置顶时可能短暂重启窗口。
            store.setAlwaysOnTop(enabled, for: store.activeMirrorControllers, applyToRunningAndroid: true)
        }
        refresh()
    }

    func perform(_ action: DeviceSystemAction, id: String? = nil) {
        guard !actionRunning else { return }
        let controllers = id.flatMap(availableController).map { [$0] } ?? (id == nil ? store.activeMirrorControllers : [])
        guard !controllers.isEmpty else { return }
        dismiss()
        actionRunning = true
        failure = nil
        refresh()
        let group = DispatchGroup()
        var failures: [String] = []
        for controller in controllers {
            group.enter()
            let name = controller.displayName.isEmpty ? controller.serial : controller.displayName
            controller.performSystemAction(action, requiresMirror: id == nil) { error in
                if let error { failures.append("\(name)：\(error.localizedDescription)") }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.actionRunning = false
            self?.failure = failures.isEmpty ? nil : failures.joined(separator: "\n")
            self?.refresh()
        }
    }

    func showSettings() {
        dismiss()
        DispatchQueue.main.async { [openSettings] in openSettings() }
    }

    func quit() { NSApp.terminate(nil) }

    private func open(_ device: KnownDevice) {
        MirrorWindowManager.shared.open(serial: device.serial, store: store, platform: device.platform, model: device.model)
    }

    private func availableController(_ id: String) -> DeviceController? {
        guard let entry = store.currentDevices.first(where: { $0.id == id && $0.unavailableReason == nil }) else { return nil }
        let device = entry.device
        return store.controller(for: device.serial, platform: device.platform, model: device.model)
    }
}
