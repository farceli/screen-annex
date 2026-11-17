import AppKit

/// 为系统 Dock 提供每台设备自己的应用名称和图标。
enum MirrorDockBundle {
    static func create(in directory: URL, identifier: String, model: String, fallback: String,
                       executable: URL, executableName: String, icon: URL) throws -> URL {
        let files = FileManager.default
        let displayName = model.isEmpty ? fallback : model
        let sanitized = displayName.replacingOccurrences(of: "/", with: "／").replacingOccurrences(of: ":", with: "：")
        let filename = sanitized.utf8.count <= 240 && !sanitized.hasPrefix(".") ? sanitized : fallback
        let bundle = directory.appendingPathComponent(filename + ".app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let executables = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try files.createDirectory(at: executables, withIntermediateDirectories: true)
        let target = executables.appendingPathComponent(executableName)
        try files.copyItem(at: executable, to: target)
        try files.createDirectory(at: resources, withIntermediateDirectories: true)
        try files.copyItem(at: icon, to: resources.appendingPathComponent(icon.lastPathComponent))
        let info = ["CFBundleIdentifier": identifier, "CFBundleName": displayName, "CFBundleDisplayName": displayName,
                    "CFBundleExecutable": executableName, "CFBundlePackageType": "APPL",
                    "CFBundleIconFile": icon.lastPathComponent, "CFBundleVersion": "1"]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        let signer = Process() // 封签设备专属的临时 App，只使用本机 ad-hoc 签名。
        signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signer.arguments = ["--force", "--sign", "-", bundle.path]
        try signer.run()
        signer.waitUntilExit()
        guard signer.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
        return bundle
    }
}

/// Launch Services reads the name from the running bundle. Give each HarmonyOS window
/// a small app entry with the device's own name, forwarding activation to its window.
@MainActor
final class MirrorDockEntry {
    static let identifierPrefix = "com.hosmirror.app.mirror."
    private let directory: URL
    private var commands: SettingsPanelPort?
    private var application: NSRunningApplication?
    private var closed = false
    let model: String

    init(model: String, source: Bundle, reveal: @escaping () -> Void, closeWindow: @escaping () -> Void,
         didLaunch: @escaping (Bool) -> Void) throws {
        self.model = model
        let id = UUID()
        let name = Self.identifierPrefix + id.uuidString.lowercased()
        let files = FileManager.default
        directory = files.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        do {
            guard let executable = source.executableURL,
                  let icon = source.url(forResource: "HarmonyMirror", withExtension: "icns") else {
                throw CocoaError(.fileNoSuchFile)
            }
            let bundle = try MirrorDockBundle.create(in: directory, identifier: name, model: model, fallback: "HarmonyOS",
                                                     executable: executable, executableName: "MirrorDock", icon: icon)
            guard let commands = SettingsPanelPort(name: name, receive: { data in
                switch try? JSONDecoder().decode(String.self, from: data) {
                case "show": reveal()
                case "close": closeWindow()
                default: break
                }
            }) else { throw CocoaError(.executableLoad) }
            self.commands = commands
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false // 打开投屏时焦点留在真实窗口。
            configuration.addsToRecentItems = false
            configuration.arguments = [String(getpid()), name]
            NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { [self] app, error in
                Task { @MainActor in
                    if let app, !closed { application = app; didLaunch(true) }
                    else {
                        app?.terminate()
                        try? FileManager.default.removeItem(at: directory)
                        if let error, !closed { NSLog("无法打开投屏 Dock 入口：%@", error.localizedDescription) }
                        if !closed { didLaunch(false) }
                    }
                }
            }
        } catch {
            try? files.removeItem(at: directory) // 清理这次创建的独立临时目录。
            throw error
        }
    }

    func close() {
        closed = true
        commands = nil // 父进程主动关闭时忽略子进程的退出消息。
        if let application {
            application.terminate()
            try? FileManager.default.removeItem(at: directory)
        } // 启动尚未回调时由完成回调回收。
    }
}

@MainActor
final class MirrorDockLifecycle: NSObject, NSApplicationDelegate {
    private let parent: pid_t
    private let channel: String
    private var parentExit: DispatchSourceProcess?

    init(parent: pid_t, channel: String) {
        self.parent = parent
        self.channel = channel
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard NSRunningApplication(processIdentifier: parent)?.isTerminated == false else { NSApp.terminate(nil); return }
        let watcher = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
        watcher.setEventHandler { NSApp.terminate(nil) } // 主进程退出后不留下独立 Dock 图标。
        watcher.resume()
        parentExit = watcher
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !SettingsPanelPort.send("show", to: channel) { sender.terminate(nil) }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = SettingsPanelPort.send("close", to: channel) // 从 Dock 退出时只关闭对应设备的投屏。
        let directory = Bundle.main.bundleURL.deletingLastPathComponent()
        if directory.lastPathComponent == channel { try? FileManager.default.removeItem(at: directory) }
    }
}
