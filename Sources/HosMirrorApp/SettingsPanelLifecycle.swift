import AppKit
import SwiftUI

@MainActor
final class SettingsPanelLifecycle: NSObject, NSApplicationDelegate {
    private let parentPID: pid_t
    private let channel: SettingsPanelChannel
    private let resources: URL
    private var events: SettingsPanelPort?
    private var parentExit: DispatchSourceProcess?
    private var settingsWindow: NSWindow?
    private var licensesWindow: NSWindow?
    private weak var mostRecentWindow: NSWindow?
    private lazy var panel: SettingsPanelModel = SettingsPanelModel { [weak self] command in
        self?.send(command)
    }

    init(parentPID: pid_t, channel: SettingsPanelChannel, resources: URL) {
        self.parentPID = parentPID
        self.channel = channel
        self.resources = resources
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard NSRunningApplication(processIdentifier: parentPID)?.isTerminated == false,
              let events = SettingsPanelPort(name: channel.events, receive: { [weak self] data in
                  self?.receive(data)
              }) else {
            NSApp.terminate(nil)
            return
        }
        self.events = events
        let parentExit = DispatchSource.makeProcessSource(identifier: parentPID, eventMask: .exit, queue: .main)
        parentExit.setEventHandler { NSApp.terminate(nil) } // 主进程异常退出时也回收设置窗口。
        parentExit.resume()
        self.parentExit = parentExit
        installMenu()
        if let gear = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: "Screen Annex 设置") {
            let icon = NSImage(size: NSSize(width: 128, height: 128), flipped: false) { bounds in
                NSColor(calibratedWhite: 0.22, alpha: 1).setFill()
                NSBezierPath(roundedRect: bounds.insetBy(dx: 7, dy: 7), xRadius: 24, yRadius: 24).fill()
                let symbol = gear.withSymbolConfiguration(.init(paletteColors: [.white])) ?? gear
                symbol.draw(in: bounds.insetBy(dx: 28, dy: 28))
                return true
            }
            NSApp.applicationIconImage = icon // 使用齿轮区分设置和投屏的两个 Dock 入口。
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true // 只退出设置进程，主应用和设备会话继续运行。
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        let openWindows = [settingsWindow, licensesWindow].compactMap { $0 }.filter { $0.isVisible || $0.isMiniaturized }
        if let window = mostRecentWindow ?? openWindows.first { present(window) } // 恢复自己的窗口，包括最小化的窗口。
        return false
    }

    private func receive(_ data: Data) {
        guard let event = try? JSONDecoder().decode(SettingsPanelEvent.self, from: data) else { return }
        switch event {
        case .snapshot(let snapshot):
            if panel.snapshot != snapshot { panel.snapshot = snapshot }
        case .showSettings:
            showSettings()
        case .showLicenses:
            showLicenses()
        }
    }

    private func send(_ command: SettingsPanelCommand) {
        if !SettingsPanelPort.send(command, to: channel.commands) {
            let alert = NSAlert()
            alert.messageText = "无法连接 Screen Annex"
            alert.informativeText = "请从菜单栏重新打开设置。"
            if let window = settingsWindow { alert.beginSheetModal(for: window) }
        }
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: "Screen Annex 设置", width: 760, height: 520,
                                        content: ContentView(panel: panel).frame(minWidth: 720, minHeight: 480))
        }
        if let settingsWindow { present(settingsWindow) }
    }

    @objc private func showLicenses() {
        if licensesWindow == nil {
            licensesWindow = makeWindow(title: "开源许可", width: 860, height: 560,
                                        content: OpenSourceLicensesView(resources: resources))
        }
        if let licensesWindow { present(licensesWindow) }
    }

    private func makeWindow<Content: View>(title: String, width: CGFloat, height: CGFloat, content: Content) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        window.setContentSize(NSSize(width: width, height: height))
        window.center()
        return window
    }

    private func present(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    private func installMenu() {
        let main = NSMenu()
        let app = NSMenu(title: "Screen Annex 设置")
        let settings = app.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        let licenses = app.addItem(withTitle: "开源许可与源码…", action: #selector(showLicenses), keyEquivalent: "")
        licenses.target = self
        app.addItem(.separator())
        app.addItem(withTitle: "退出 Screen Annex 设置", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let window = NSMenu(title: "窗口")
        window.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        for submenu in [app, edit, window] {
            let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            main.addItem(item)
        }
        NSApp.mainMenu = main
        NSApp.windowsMenu = window
    }
}

extension SettingsPanelLifecycle: NSWindowDelegate {
    func windowDidBecomeKey(_ notification: Notification) {
        mostRecentWindow = notification.object as? NSWindow
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, mostRecentWindow === window else { return }
        mostRecentWindow = window === settingsWindow ? licensesWindow : settingsWindow
        if mostRecentWindow?.isVisible != true, mostRecentWindow?.isMiniaturized != true { mostRecentWindow = nil }
    }
}
