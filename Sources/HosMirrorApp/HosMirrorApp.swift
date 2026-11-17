import AppKit

@main
@MainActor
struct HosMirrorApp {
    static func main() {
        let app = NSApplication.shared
        if let identifier = Bundle.main.bundleIdentifier, identifier.hasPrefix(MirrorDockEntry.identifierPrefix) {
            let arguments = CommandLine.arguments
            guard arguments.count >= 3, let parent = pid_t(arguments[1]), parent > 1,
                  arguments[2] == identifier else { return }
            let lifecycle = MirrorDockLifecycle(parent: parent, channel: identifier)
            app.setActivationPolicy(.regular)
            app.delegate = lifecycle
            withExtendedLifetime(lifecycle) { app.run() }
            return
        }
        if Bundle.main.bundleIdentifier == SettingsPanelCoordinator.bundleIdentifier {
            // 安装包复用同一个构建目标，Launch Services 按嵌套 App 的独立身份启动设置。
            let arguments = CommandLine.arguments
            guard arguments.count >= 3, let parentPID = pid_t(arguments[1]), parentPID > 1,
                  let id = UUID(uuidString: arguments[2]) else { return }
            let contents = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            let lifecycle = SettingsPanelLifecycle(parentPID: parentPID, channel: SettingsPanelChannel(id: id),
                                                  resources: contents.appendingPathComponent("Resources"))
            app.setActivationPolicy(.regular)
            app.delegate = lifecycle
            withExtendedLifetime(lifecycle) { app.run() }
            return
        }
        app.setActivationPolicy(.accessory) // 冷启动只注册菜单栏入口。
        let lifecycle = MirrorAppLifecycle()
        app.delegate = lifecycle
        withExtendedLifetime(lifecycle) { app.run() } // AppKit 的 delegate 是弱引用。
    }
}
