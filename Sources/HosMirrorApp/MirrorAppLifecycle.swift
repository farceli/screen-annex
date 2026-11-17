import AppKit
import HosMirrorCore

@MainActor
final class MirrorAppLifecycle: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let store: SessionStore
    private(set) var deviceStatusItem: DeviceStatusItem?
    private let settingsPanel: SettingsPanelCoordinator
    private let appBundle: Bundle?
    private var terminating = false
    private var lastLockEvent: Bool? // 忽略系统重复投递的同一状态。
    private static let macLocked = Notification.Name("com.apple.screenIsLocked")
    private static let macUnlocked = Notification.Name("com.apple.screenIsUnlocked")

    override convenience init() { self.init(store: SessionStore()) }

    init(store: SessionStore, bundleURL: URL = Bundle.main.bundleURL) {
        self.store = store
        appBundle = Bundle(url: bundleURL)
        let settingsURL = bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent(SettingsPanelCoordinator.bundleName, isDirectory: true)
        settingsPanel = SettingsPanelCoordinator(store: store, bundleURL: settingsURL)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installAppMenu()
        MirrorWindowManager.shared.dockSource = appBundle
        MirrorWindowManager.shared.onWindowPresenceChanged = { [weak self] in self?.updateDockPresence() }
        deviceStatusItem = DeviceStatusItem(store: store) { [weak self] in self?.showSettings() }
        let system = DistributedNotificationCenter.default() // loginwindow 在锁屏状态实际变化时发送。
        for name in [Self.macLocked, Self.macUnlocked] {
            system.addObserver(self, selector: #selector(macLockStateChanged(_:)), name: name,
                               object: nil, suspensionBehavior: .deliverImmediately)
        }
    }

    @objc private func macLockStateChanged(_ notification: Notification) {
        // 新系统在 object 中发送事件所属用户，避免快速切换用户时串用设备。
        if let sender = notification.object as? String, let uid = UInt32(sender), uid != getuid() { return }
        applyMacLockState(notification.name == Self.macLocked)
    }

    func applyMacLockState(_ locked: Bool) {
        guard !terminating, locked != lastLockEvent else { return }
        lastLockEvent = locked
        guard locked ? store.settings.lockPhonesWithMac : store.settings.unlockPhonesWithMac else { return }
        for device in store.screenLinkDevices { // 包括已授权、当前在线但未投屏的设备。
            let controller = store.controller(for: device.serial, platform: device.platform, model: device.model)
            controller.performSystemAction(locked ? .lock : .wake, requiresMirror: false, followMac: true) { _ in }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // 关闭最后一个投屏窗口后，菜单栏仍可用。
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // Dock 普通点击恢复最近使用的鸿蒙窗口，包括已最小化的窗口。
        if !MirrorWindowManager.shared.showMostRecentWindow(), !hasVisibleWindows { showSettings() }
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        // 每个鸿蒙设备保留一个可直接切换的原生 Dock 菜单项。
        let menu = NSMenu()
        for (id, title) in MirrorWindowManager.shared.dockWindows {
            let item = menuItem(title, action: #selector(showMirrorFromDock(_:)))
            item.representedObject = id
            menu.addItem(item)
        }
        return menu.items.isEmpty ? nil : menu
    }

    @objc private func showMirrorFromDock(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        MirrorWindowManager.shared.showWindow(id: id)
    }

    private func updateDockPresence() {
        // 只有鸿蒙窗口决定主应用的 Dock 图标，设置由独立进程负责。
        let policy: NSApplication.ActivationPolicy = MirrorWindowManager.shared.needsFallbackDockEntry ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateLater }
        terminating = true
        DistributedNotificationCenter.default().removeObserver(self)
        settingsPanel.close()
        store.shutdown { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    @objc func showSettings() {
        settingsPanel.show(.showSettings)
    }

    @objc private func showLicenses() {
        settingsPanel.show(.showLicenses)
    }

    private func installAppMenu() {
        let main = NSMenu()
        let appMenu = NSMenu(title: "Screen Annex")
        appMenu.addItem(withTitle: "关于 Screen Annex", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(menuItem("设置…", action: #selector(showSettings), key: ","))
        appMenu.addItem(menuItem("开源许可与源码…", action: #selector(showLicenses)))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Screen Annex", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        addSubmenu(appMenu, to: main)

        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        addSubmenu(edit, to: main)

        let window = NSMenu(title: "窗口")
        window.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(menuItem("刷新设备", action: #selector(refreshDevices), key: "r", modifiers: [.command, .shift]))
        window.addItem(menuItem("切换当前投屏窗口置顶", action: #selector(toggleFocusedWindowPin), key: "t", modifiers: [.command, .shift]))
        addSubmenu(window, to: main)
        NSApp.mainMenu = main
        NSApp.windowsMenu = window
    }

    private func menuItem(_ title: String, action: Selector, key: String = "",
                          modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    private func addSubmenu(_ submenu: NSMenu, to main: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        main.addItem(item)
    }

    @objc private func refreshDevices() { store.refreshDevices() }

    @objc private func toggleFocusedWindowPin() {
        guard let controller = MirrorWindowManager.shared.focusedController else { return }
        store.toggleAlwaysOnTop(for: controller)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action != #selector(toggleFocusedWindowPin) || MirrorWindowManager.shared.focusedController != nil
    }
}
