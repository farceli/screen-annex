import AppKit // 使用真实生产窗口和原生事件，不访问手机。
import SwiftUI // 渲染真实标题栏与连接视图。
import CoreMedia // 检查生产渲染器交付给显示层的时间戳与帧标记。
import HosMirrorCore // 直接采用平台身份和共用窗口几何模型。

@main
@MainActor
struct MacAndroidIntegration {
    static func require(_ value: Bool, _ message: String) { if !value { fatalError(message) } } // 验证失败必须非零退出。
    static func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.12)) } // 仅等待 AppKit 布局与 Combine 已排队的更新。
    static func near(_ left: CGFloat, _ right: CGFloat) -> Bool { abs(left - right) < 2 } // 允许 AppKit 取整到屏幕像素。
    static func main() throws {
        checkSavedQualitySettings() // 升级时保留用户调整的鸿蒙画质，旧默认档迁移到平衡档。
        _ = NSApplication.shared // 仅初始化测试进程自己的原生窗口环境。
        try checkVideoTiming() // 回放现有 H.264 夹具，验证共用渲染器的 Android 分支。
        if CommandLine.arguments.contains("--video-only") { return } // 只检查送显时无需打开窗口或写截图。
        if CommandLine.arguments.contains("--settings-dock") {
            checkSettingsDock()
            return
        }
        if CommandLine.arguments.contains("--screen-link") {
            checkScreenLink()
            return
        }
        let suite = "HosMirror.WindowTest." + UUID().uuidString // 独立保存测试设备的置顶偏好。
        guard let defaults = UserDefaults(suiteName: suite) else { fatalError("无法创建窗口测试偏好域") }
        defer { defaults.removePersistentDomain(forName: suite) } // 清理本次测试写入的置顶数据。
        let store = SessionStore(discoverDevices: false, defaults: defaults) // 不运行真实 hdc 或 ADB。
        if CommandLine.arguments.contains("--initial-frame-only") {
            checkInitialMirrorFrame(store: store)
            print("通过：首次显示直接采用视频方向和最终窗口尺寸。")
            return
        }
        if !CommandLine.arguments.contains("--windows-only") { checkStatusItem() } // 窗口测试可独立于菜单动画运行。
        checkInitialMirrorFrame(store: store)
        store.settings.alwaysOnTop = false // 固定测试初始值，不依赖用户设置。
        let serial = "same-fixture-serial" // 刻意制造两个系统的同序列号。
        let portrait = CGSize(width: 1080, height: 1920) // 两个设备具有相同物理比例，便于比较实际窗口。
        var fixtures: [(DevicePlatform, DeviceController, MirrorDeviceWindow)] = [] // 每台设备保存独立控制器和窗口。
        let android = store.controller(for: serial, platform: .android, model: "测试手机")
        MirrorWindowManager.shared.open(serial: serial, store: store, platform: .android, connectImmediately: false)
        require(!NSApp.windows.contains { $0.identifier?.rawValue == android.id }, "Android 又创建了自研投屏窗口") // 桌面客户端拥有自己的窗口。
        for route in [serial, "second-fixture-serial"] { // 保留对两台鸿蒙设备的窗口独立性检查。
            let platform = DevicePlatform.harmony
            MirrorWindowManager.shared.open(serial: route, store: store, platform: platform, model: "测试手机", connectImmediately: false)
            let key = platform.identifier(serial: route)
            guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == key }) as? MirrorDeviceWindow else { fatalError("平台未使用共用原生窗口") } // 两者必须是同一窗口类。
            let controller = store.controller(for: route, platform: platform) // 取生产窗口使用的真实控制器。
            let visible = window.availableScreenFrame // 使用实际显示器的可用区域。
            window.setFrameTopLeftPoint(CGPoint(x: visible.minX + 20, y: visible.maxY - 12)) // 两个平台从同一位置对比，避免屏幕差异。
            controller.physicalSize = portrait // 模拟两台设备都完成真实屏幕尺寸探测。
            controller.connected = true // 触发生产观察者的首次连接最大化。
            settle() // 不直接调用最大化掩盖观察者错误。
            require(window.title == platform.title(model: "测试手机"), "窗口系统标题与显示标题不一致") // 上游独立窗口后缀不得残留。
            require(window.titleControls != nil, "缺少标题右侧功能区")
            let sdlStyle: NSWindow.StyleMask = [.titled, .resizable, .closable, .miniaturizable] // SDL 的 Cocoa 窗口样式。
            let reference = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 360, height: 600),
                                     styleMask: sdlStyle, backing: .buffered, defer: false)
            let referenceContent = reference.contentView!
            let referenceTop = referenceContent.convert(referenceContent.bounds, to: nil).maxY
            let scrcpyChrome = reference.frame.height - referenceTop
            let mirrorContent = window.contentView!
            let mirrorTop = mirrorContent.convert(mirrorContent.bounds, to: nil).maxY
            require(window.chromeHeight == scrcpyChrome && window.frame.height - mirrorTop == scrcpyChrome
                    && !window.titlebarAppearsTransparent, "鸿蒙标题栏外框或实际画面起点与 SDL 窗口不一致")
            require(near(window.frame.width, window.maximumDeviceFrame.width) && near(window.frame.height, window.maximumDeviceFrame.height), "首次连接未按屏幕可用尺寸最大化") // 验证实际外框而非理论公式。
            fixtures.append((platform, controller, window)) // 继续检验缩放、旋转和同步设置。
        }
        require(fixtures[0].2 !== fixtures[1].2, "两台设备的窗口发生串用")
        require(near(fixtures[0].2.frame.width, fixtures[1].2.frame.width), "同尺寸首次出图窗口宽度不同") // 真正比较结果。
        let (_, harmony, harmonyWindow) = fixtures[0]
        require(harmonyWindow.title == "「HarmonyOS」 测试手机" && android.windowTitle == "「Android」 测试手机", "系统标题没有使用直角引号")
        store.setCustomName("  工作手机  ", for: harmony)
        harmony.deviceModel = "新上报的型号" // 设备重新探测后仍应使用别名。
        settle()
        require(harmonyWindow.title == "「HarmonyOS」 工作手机" && android.windowTitle == "「Android」 测试手机", "别名没有即时更新或串用了另一平台")
        store.updateHarmonyDevices([DeviceInfo(serial: serial)])
        let hardwareKey = DevicePlatform.harmony.identifier(serial: "hardware:fixture")
        store.adoptHardwareKey(hardwareKey, for: KnownDevice(platform: .harmony, serial: serial))
        let restarted = SessionStore(discoverDevices: false, defaults: defaults) // 新存储必须从磁盘恢复名称与历史。
        require(restarted.historicalDevices.map(\.customName) == ["工作手机"], "重启后丢失设备历史或名称")
        require(restarted.controller(for: serial).customName == "工作手机", "读取不到硬件身份时未恢复已验证 USB 设备的名称")
        let wirelessSerial = "192.0.2.10:8710" // 同一物理设备通过另一种调试地址接入。
        restarted.updateHarmonyDevices([DeviceInfo(serial: wirelessSerial)])
        restarted.adoptHardwareKey(hardwareKey, for: KnownDevice(platform: .harmony, serial: wirelessSerial))
        let wireless = restarted.controller(for: wirelessSerial)
        require(wireless.customName == "工作手机" && restarted.historicalDevices.isEmpty, "新调试地址没有沿用同一设备的别名")
        restarted.updateAndroidDevices([AndroidDevice(serial: serial, state: "unauthorized", model: "Android 夹具")])
        require(restarted.currentDevices.last?.unavailableReason != nil, "未授权设备被显示为可连接")
        restarted.updateHarmonyDevices([DeviceInfo(serial: wirelessSerial, state: "offline")])
        require(restarted.historicalDevices.map(\.customName) == ["工作手机"], "断开设备没有进入折叠历史")
        harmony.deviceModel = "新上报的型号" // 模拟最新探测结果覆盖缓存。
        store.setCustomName(" ", for: harmony)
        settle()
        require(harmonyWindow.title == "「HarmonyOS」 新上报的型号", "清空别名未恢复默认名称")
        for (platform, controller, window) in fixtures {
            let maximum = window.maximumDeviceFrame // 双击前保存预期最大框。
            let small = window.constrainedFrameSize(CGSize(width: maximum.width - 65, height: maximum.height - 100)) // 使用真实拖动约束计算较小窗口。
            window.setFrame(CGRect(x: maximum.minX, y: maximum.maxY - small.height, width: small.width, height: small.height), display: true) // 模拟手动缩小后的位置。
            require(window.frame.height < maximum.height - 2, "夹具未成功模拟手动缩小") // 不允许原本就最大化而误通过。
            let point = CGPoint(x: window.frame.width / 2, y: window.frame.height - 8) // 只点击测试窗口自己的标题空白区。
            let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 2, pressure: 1)! // 由生产 sendEvent 路径处理双击。
            window.sendEvent(event) // 不调用内部几何函数替代真实交互。
            require(near(window.frame.width, maximum.width) && near(window.frame.height, maximum.height), "\(platform.rawValue) 双击标题未放大") // 两个平台共享行为。
            require(near(window.frame.minX, maximum.minX) && near(window.frame.maxY, maximum.maxY), "双击放大移动了标题栏左上角") // 既有固定锚点语义。
            let before = window.frame // 最大化窗口旋转后仍保持当前锚点。
            controller.physicalSize = CGSize(width: portrait.height, height: portrait.width) // 模拟设备旋转触发真实观察者。
            settle() // 等待比例和最大尺寸更新。
            let content = window.contentRect(forFrameRect: window.frame).size // 标题栏不能计入屏幕比例。
            require(abs(content.width / content.height - portrait.height / portrait.width) < 0.02, "设备旋转后内容比例错误") // 不允许拉伸。
            require(near(window.frame.minX, before.minX) && near(window.frame.maxY, before.maxY), "旋转时标题锚点发生跳变") // 与鸿蒙原有逻辑一致。
            controller.physicalSize = portrait // 截图恢复常见竖屏。
            settle() // 等待真实视图调整。
            let count = NSApp.windows.filter { $0.identifier == window.identifier }.count // 重复打开不能创建第二个窗口。
            MirrorWindowManager.shared.open(serial: controller.serial, store: store, platform: platform, model: "测试手机", connectImmediately: false) // 验证真实入口复用原生窗口。
            require(NSApp.windows.filter { $0.identifier == window.identifier }.count == count, "重复打开生成了第二个窗口") // 仍是同一个设备窗口。
        }
        let (_, first, firstWindow) = fixtures[0]
        let (_, second, secondWindow) = fixtures[1]
        let snap = MirrorWindowSnap.shared
        snap.setEnabled(true)
        settle()
        let ordered = [firstWindow, secondWindow].sorted { $0.frame.minX < $1.frame.minX }
        require(near(ordered[0].frame.maxX, ordered[1].frame.minX) && near(firstWindow.frame.maxY, secondWindow.frame.maxY), "磁吸窗口没有贴合或顶部未对齐")
        let locked = firstWindow.frame
        firstWindow.setFrameOrigin(CGPoint(x: locked.minX + 50, y: locked.minY + 30))
        settle()
        require(firstWindow.frame == locked && !firstWindow.isMovable, "磁吸窗口脱离了队列")
        let moving = ordered[0]
        func mouse(_ type: NSEvent.EventType, at screen: CGPoint, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) {
            let point = moving.convertPoint(fromScreen: screen) // 事件位置随窗口移动更新，屏幕指针坐标保持一致。
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: 0,
                                           windowNumber: moving.windowNumber, context: nil, eventNumber: 2, clickCount: clicks, pressure: 1)!
            moving.sendEvent(event) // 和真实标题拖动、视频区点击走相同事件入口。
        }
        let start = CGPoint(x: moving.frame.midX, y: moving.frame.maxY - 9)
        let end = CGPoint(x: start.x + 42, y: start.y - 37)
        let beforeDrag = ordered.map(\.frame)
        mouse(.leftMouseDown, at: start)
        mouse(.leftMouseDragged, at: end)
        mouse(.leftMouseUp, at: end)
        for (window, previous) in zip(ordered, beforeDrag) {
            require(near(window.frame.minX, previous.minX + 42) && near(window.frame.minY, previous.minY - 37)
                    && window.frame.size == previous.size, "整组拖动没有同步保留各窗口外框")
        }
        let swap = CGPoint(x: ordered[1].frame.maxX + 20, y: end.y)
        mouse(.leftMouseDown, at: end, flags: .option)
        mouse(.leftMouseDragged, at: swap, flags: .option)
        mouse(.leftMouseUp, at: swap, flags: .option)
        require(near(ordered[1].frame.maxX, moving.frame.minX), "磁吸换序后没有保持贴合")
        require(near(ordered[1].frame.minX, beforeDrag[0].minX + 42), "换序改变了整组位置")
        ordered[1].orderOut(nil)
        require(!ordered[1].isVisible, "无法隐藏同组夹具")
        mouse(.leftMouseDown, at: CGPoint(x: moving.frame.midX, y: moving.frame.midY))
        require(ordered[1].isVisible, "点击视频区没有唤回同组窗口")
        let doubleClick = CGPoint(x: moving.frame.midX, y: moving.frame.maxY - 9)
        mouse(.leftMouseDown, at: doubleClick, clicks: 2)
        mouse(.leftMouseUp, at: doubleClick, clicks: 2)
        require(near(ordered[1].frame.minX, beforeDrag[0].minX)
                && near(moving.frame.maxX, beforeDrag[1].maxX)
                && near(ordered[1].frame.maxX, moving.frame.minX)
                && near(ordered[1].frame.maxY, beforeDrag[0].maxY)
                && near(moving.frame.maxY, beforeDrag[1].maxY), "双击标题后整组没有按可见区域最大化或换序被重置")
        snap.setEnabled(false)
        let free = firstWindow.frame.origin
        firstWindow.setFrameOrigin(CGPoint(x: free.x + 15, y: free.y - 20))
        require(firstWindow.isMovable && !near(firstWindow.frame.minX, free.x), "关闭磁吸后未恢复独立移动")
        require(firstWindow.level == .normal && secondWindow.level == .normal, "新窗口未读取默认层级")
        store.toggleAlwaysOnTop(for: first) // 与第一个窗口标题栏按钮走同一入口。
        require(firstWindow.level == .floating && secondWindow.level == .normal, "开启一个窗口时另一个窗口也置顶")
        let manager = MirrorWindowManager.shared
        manager.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: firstWindow)) // 在测试进程中模拟 AppKit 委托通知。
        manager.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: secondWindow))
        manager.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: firstWindow)) // 旧窗口的通知不能清空新目标。
        guard let focused = manager.focusedController, focused === second else { fatalError("快捷键未定位到当前投屏窗口") }
        store.toggleAlwaysOnTop(for: focused)
        manager.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: secondWindow))
        require(manager.focusedController == nil, "失去投屏窗口焦点后快捷键仍有目标")
        store.toggleAlwaysOnTop(for: first) // 显式取消第一个窗口的置顶，测试另一个窗口继续置顶。
        require(firstWindow.level == .normal && secondWindow.level == .floating, "取消置顶时影响了其他窗口")
        var settings = store.settings // 仅修改测试存储，避免写入用户偏好。
        settings.alwaysOnTop = true; settings.mirrorAppearance = .dark // 改变未来窗口的默认值，同时保留当前窗口的层级。
        store.settings = settings // 使用生产订阅路径。
        settle() // 等待 AppKit 属性更新。
        require(firstWindow.level == .normal && secondWindow.level == .floating, "默认设置覆盖了现有窗口的独立选择")
        for (platform, controller, window) in fixtures {
            require(window.appearance?.name == .darkAqua, "深色外观没有同步") // 两个平台同一设置。
            settings.mirrorAppearance = .light; store.settings = settings; settle() // 用一致浅色背景记录对比截图。
            if !CommandLine.arguments.contains("--no-screenshots") {
                try snapshot(window, name: platform.rawValue + "-" + controller.serial + "-投屏窗口.png") // 只截取测试窗口视图树，不捕获桌面。
            }
            settings.mirrorAppearance = .dark; store.settings = settings; settle() // 继续核查下一个窗口的深色状态。
        }
        for (_, _, window) in fixtures { window.close() } // 关闭测试窗口触发生产清理。
        let reopenedStore = SessionStore(discoverDevices: false, defaults: defaults) // 新存储实例必须能读取设备各自的选择。
        reopenedStore.settings.alwaysOnTop = false // 全局自动置顶会优先，单设备偏好在关闭全局开关时生效。
        MirrorWindowManager.shared.open(serial: serial, store: reopenedStore, platform: first.platform, connectImmediately: false)
        guard let reopened = NSApp.windows.first(where: { $0 !== firstWindow && $0.identifier?.rawValue == first.id }) else {
            fatalError("窗口未重新打开")
        }
        require(reopened.level == .normal, "重开窗口时没有恢复已保存的取消置顶")
        reopened.close()
        print("通过：英文标题、即时改名、设备身份与历史持久化、最大尺寸、双击、旋转、独立置顶与深色外观。")
    }

    static func checkInitialMirrorFrame(store: SessionStore) {
        let manager = MirrorWindowManager.shared
        let serial = "initial-frame-fixture"
        let controller = store.controller(for: serial)
        controller.busy = true // 保持真实连接入口，跳过发起 HDC 的步骤。
        manager.open(serial: serial, store: store)
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == controller.id }) as? MirrorDeviceWindow else {
            fatalError("初始布局测试未创建投屏窗口")
        }
        defer { controller.disconnect() }
        require(!window.isVisible && !manager.showWindow(id: controller.id), "探测阶段显示了临时尺寸")
        controller.physicalSize = CGSize(width: 1080, height: 2340)
        controller.busy = false
        controller.connected = true
        settle()
        require(!window.isVisible, "控制通道接通时提前显示了竖屏窗口")
        controller.renderer.onSize?(CGSize(width: 2340, height: 1080)) // 首个编码格式确认设备实际处于横屏。
        settle()
        let first = window.frame
        let content = window.contentRect(forFrameRect: first)
        let target = window.maximumDeviceFrame
        let fitsScreen = NSScreen.screens.isEmpty || (near(first.width, target.width) && near(first.height, target.height))
        require(window.isVisible && content.width > content.height && fitsScreen,
                "首次显示时没有直接采用横屏最大尺寸：visible=\(window.isVisible)，frame=\(first)，target=\(target)")
        controller.renderer.onFirstFrame?()
        settle()
        require(first == window.frame, "首帧显示时窗口再次变了尺寸")
    }

    static func checkStatusItem() {
        let suite = "HosMirror.StatusPanelTest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionStore(discoverDevices: false, defaults: defaults) // 测试面板使用合成列表。
        let status = DeviceStatusItem(store: store)
        defer { NSStatusBar.system.removeStatusItem(status.item) }
        let panel = status.panel
        require(status.item.button?.action != nil && status.popover.contentViewController != nil,
                "菜单栏没有绑定设备面板")
        panel.refresh()
        require(!panel.availability.connectAll && !panel.availability.systemActions, "空设备列表仍允许批量操作")

        let serial = "shared-panel-fixture"
        store.updateHarmonyDevices([DeviceInfo(serial: serial, transport: .usb)])
        store.updateAndroidDevices([
            AndroidDevice(serial: serial, state: "device", model: "Android 测试机"),
            AndroidDevice(serial: "unauthorized-panel-fixture", state: "unauthorized", model: "未授权测试机"),
        ])
        panel.refresh()
        require(panel.availability.connectAll && !panel.availability.systemActions, "连接和投屏状态混淆")
        let harmony = store.controller(for: serial)
        let android = store.controller(for: serial, platform: .android)
        panel.setPin(true, id: android.id)
        require(store.isAlwaysOnTopAtLaunch(for: android) && !store.isAlwaysOnTopAtLaunch(for: harmony), "同调试标识的设备置顶设置串用")
        panel.setAutomaticPin(true)
        require(MirrorSettings.load(from: defaults).alwaysOnTop, "自动置顶没有写入隔离设置")
        android.connected = true
        panel.setConnection(false, id: android.id)
        settle()
        require(!panel.connectionIsOn(android) && harmony.status == "未连接", "断开没有定位到正确设备")
        print("通过：菜单栏面板、批量状态、单设备置顶与断开。")
    }

    static func checkSettingsDock() {
        let directory = ProcessInfo.processInfo.environment["HOSMIRROR_DIST_DIR"] ?? "dist"
        let bundle = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("Screen Annex.app").standardizedFileURL
        let helper = bundle.appendingPathComponent("Contents/Helpers/Screen Annex Settings.app", isDirectory: true)
        require(FileManager.default.fileExists(atPath: helper.path), "请先构建带有独立设置应用的安装包")
        let suite = "HosMirror.SettingsDockTest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionStore(discoverDevices: false, defaults: defaults)
        let lifecycle = MirrorAppLifecycle(store: store, bundleURL: bundle)
        NSApp.setActivationPolicy(.accessory)
        lifecycle.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        guard let status = lifecycle.deviceStatusItem else { fatalError("缺少设备面板") }
        defer { NSStatusBar.system.removeStatusItem(status.item) }

        func helpers() -> [NSRunningApplication] {
            NSRunningApplication.runningApplications(withBundleIdentifier: SettingsPanelCoordinator.bundleIdentifier)
                .filter { $0.bundleURL?.standardizedFileURL == helper && !$0.isTerminated }
        }
        func waitFor(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(5)
            while !condition(), Date() < deadline { settle() }
            return condition()
        }
        func hasSettingsWindow(_ pid: pid_t) -> Bool {
            // 窗口服务器公开的 PID 和图层足以确认设置窗口属于另一个进程。
            let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
            return windows.contains {
                $0[kCGWindowOwnerPID as String] as? pid_t == pid && $0[kCGWindowLayer as String] as? Int == 0
            }
        }

        require(helpers().isEmpty, "请先关闭正在运行的 Screen Annex 设置窗口")
        defer { helpers().forEach { $0.terminate() } }
        status.panel.showSettings() // 使用设备面板的生产设置入口。
        require(waitFor { helpers().first.map { $0.activationPolicy == .regular && hasSettingsWindow($0.processIdentifier) } == true },
                "设置没有作为独立 Dock 应用打开")
        let settings = helpers()[0]
        require(NSApp.activationPolicy() == .accessory, "只打开设置时主应用也出现在 Dock")
        lifecycle.showSettings()
        settle()
        require(helpers().map(\.processIdentifier) == [settings.processIdentifier], "重复打开设置启动了第二个进程")

        // 经过实际本机端口提交设置，检查主进程合并字段并保存到隔离偏好域。
        let name = "com.hosmirror.settings.test.\(UUID().uuidString)"
        let original = store.settings
        var updated = original
        updated.frameRate = original.frameRate == 60 ? 30 : 60
        var parallel = original
        parallel.alwaysOnTop.toggle() // 模拟菜单栏同时调整另一个字段。
        store.update(settings: parallel)
        let endpoint = SettingsPanelPort(name: name) { data in
            if let command = try? JSONDecoder().decode(SettingsPanelCommand.self, from: data) {
                store.applySettingsPanelCommand(command)
            }
        }
        withExtendedLifetime(endpoint) {
            require(SettingsPanelPort.send(SettingsPanelCommand.update(updated, previous: original), to: name), "设置消息没有通过本机端口")
            require(waitFor { store.settings.frameRate == updated.frameRate }, "主进程没有应用设置")
        }
        let saved = MirrorSettings.load(from: defaults)
        require(saved.frameRate == updated.frameRate && saved.alwaysOnTop == parallel.alwaysOnTop,
                "保存设置时覆盖了菜单栏的并行改动")

        let manager = MirrorWindowManager.shared
        let serial = "settings-dock-fixture"
        let model = "Dock 验证 " + UUID().uuidString.prefix(8)
        manager.open(serial: serial, store: store, model: model, connectImmediately: false)
        guard let window = NSApp.windows.compactMap({ $0 as? MirrorDeviceWindow }).first else { fatalError("缺少投屏窗口") }
        var mirrorApp: NSRunningApplication?
        require(waitFor {
            mirrorApp = NSWorkspace.shared.runningApplications.first {
                $0.bundleIdentifier?.hasPrefix(MirrorDockEntry.identifierPrefix) == true && $0.localizedName == model
            }
            return mirrorApp?.activationPolicy == .regular && NSApp.activationPolicy() == .accessory
        }, "Dock 入口未注册为设备型号")
        guard let mirrorApp, let mirrorURL = mirrorApp.bundleURL else { fatalError("缺少设备 Dock 应用") }
        require(Bundle(url: mirrorURL)?.url(forResource: "HarmonyMirror", withExtension: "icns") != nil && mirrorApp.icon?.isValid == true,
                "设备 Dock 图标未随应用加载")
        window.miniaturize(nil)
        require(waitFor { window.isMiniaturized }, "未能最小化投屏窗口")
        NSWorkspace.shared.openApplication(at: mirrorURL, configuration: .init()) { _, _ in }
        require(waitFor { !window.isMiniaturized && window.isVisible }, "投屏 Dock 入口没有恢复最小化窗口")
        lifecycle.showSettings() // 通过产品的端口激活设置进程，避免其他安装目录的同名 App 干扰。
        require(waitFor { settings.isActive && helpers().map(\.processIdentifier) == [settings.processIdentifier] },
                "设置入口没有切回独立的设置进程")

        require(settings.terminate(), "无法退出独立设置进程")
        require(waitFor { settings.isTerminated && window.isVisible }, "退出设置影响了投屏窗口")
        lifecycle.showSettings()
        require(waitFor { helpers().first.map { hasSettingsWindow($0.processIdentifier) } == true }, "关闭设置后无法重新打开")
        window.close()
        require(waitFor { mirrorApp.isTerminated && NSApp.activationPolicy() == .accessory && helpers().count == 1 }, "关闭投屏影响了设置的 Dock 入口")
        print("通过：独立设置进程、两个 Dock 身份、复用设置、最小化恢复及独立关闭。")
    }

    static func checkSavedQualitySettings() {
        let suite = "HosMirror.QualityTest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)! // 测试不改动用户画质偏好。
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = Data(#"{"frameRate":15,"bitRateMbps":4,"scale":0.5,"autoReconnect":false,"alwaysOnTop":true,"autoQuality":false}"#.utf8)
        defaults.set(legacy, forKey: MirrorSettings.storageKey)
        let saved = MirrorSettings.load(from: defaults)
        require(saved.frameRate == 15 && saved.bitRateMbps == 4 && saved.scale == 0.5, "升级后丢失已保存的手动画质")
        require(saved.lockPhonesWithMac && saved.unlockPhonesWithMac, "旧版设置缺省时手机锁屏联动未默认开启")
        var disabled = saved
        disabled.unlockPhonesWithMac = false
        disabled.save(to: defaults)
        let reopened = MirrorSettings.load(from: defaults)
        require(reopened.lockPhonesWithMac && !reopened.unlockPhonesWithMac, "手机锁屏联动两个开关未独立保存")
        require(!saved.autoReconnect && saved.alwaysOnTop, "升级后丢失重连或置顶偏好")
        let older = Data(#"{"frameRate":30,"bitRateMbps":8,"scale":1,"autoReconnect":true,"alwaysOnTop":false}"#.utf8)
        defaults.set(older, forKey: MirrorSettings.storageKey)
        var migrated = MirrorSettings.load(from: defaults)
        require(migrated.frameRate == 30 && migrated.bitRateMbps == 16 && migrated.scale == 1, "旧默认值没有迁移到鸿蒙平衡档")
        migrated.bitRateMbps = 8
        migrated.save(to: defaults)
        require(MirrorSettings.load(from: defaults).bitRateMbps == 8, "升级后无法手动选回旧码率")
        defaults.set(Data(#"{"frameRate":30,"bitRateMbps":12,"scale":1,"autoReconnect":true,"alwaysOnTop":false,"harmonyQualityVersion":1}"#.utf8),
                     forKey: MirrorSettings.storageKey)
        require(MirrorSettings.load(from: defaults).bitRateMbps == 16, "上一个版本的平衡档没有迁移")
        print("通过：兼容旧版画质设置。")
    }

    static func checkScreenLink() {
        let environment = ProcessInfo.processInfo.environment
        guard let logPath = environment["HOSMIRROR_SCREEN_LINK_LOG"],
              let resources = environment["HOSMIRROR_RESOURCES"],
              AppResources.root.path == resources else { fatalError("需要隔离的调试命令夹具") }
        let logURL = URL(fileURLWithPath: logPath)
        let suite = "HosMirror.ScreenLinkTest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionStore(discoverDevices: false, defaults: defaults)
        store.updateHarmonyDevices([DeviceInfo(serial: "harmony-fixture")])
        store.updateAndroidDevices([
            AndroidDevice(serial: "android-fixture", state: "device", model: "Android"),
            AndroidDevice(serial: "unauthorized-fixture", state: "unauthorized", model: "Android"),
        ])
        let lifecycle = MirrorAppLifecycle(store: store)
        func log() -> String { (try? String(contentsOf: logURL, encoding: .utf8)) ?? "" }
        func waitFor(_ expected: String) -> Bool {
            let deadline = Date().addingTimeInterval(4)
            while !log().contains(expected) && Date() < deadline { settle() }
            return log().contains(expected)
        }
        lifecycle.applyMacLockState(true)
        lifecycle.applyMacLockState(true) // 重复通知不能重复对同一手机发送锁屏命令。
        require(waitFor("KEYCODE_SLEEP") && waitFor("power-shell suspend"), "锁屏通知未发送到两端")
        lifecycle.applyMacLockState(false)
        require(waitFor("wm dismiss-keyguard") && waitFor("uitest uiInput dircFling 2"), "解锁没有按系统路径执行")
        let all = log()
        require(all.components(separatedBy: "KEYCODE_SLEEP").count == 2 && !all.contains("unauthorized-fixture"), "重复锁屏或包含未授权设备")
        var disabled = store.settings
        disabled.lockPhonesWithMac = false
        disabled.unlockPhonesWithMac = false
        store.update(settings: disabled)
        lifecycle.applyMacLockState(true)
        lifecycle.applyMacLockState(false)
        settle()
        require(log() == all, "关闭联动后仍向设备发命令")
        print("通过：锁屏联动目标、两端命令、重复通知和独立开关。")
    }

    static func checkVideoTiming() throws {
        let fixture = try Data(contentsOf: URL(fileURLWithPath: "Tests/HosMirrorCoreTests/Resources/sample.h264"))
        let nals = H264.split(fixture) // 使用可解码的参数集、关键帧和增量帧。
        let deltas = nals.filter { H264.type(of: $0) == .slice }
        guard let idr = nals.first(where: { H264.type(of: $0) == .idr }), deltas.count >= 2 else { fatalError("缺少回放帧") }
        func annexB(_ nals: [[UInt8]]) -> Data {
            nals.reduce(into: Data()) { data, nal in data.append(contentsOf: [0, 0, 0, 1]); data.append(contentsOf: nal) }
        }
        let config = annexB(nals.filter { H264.type(of: $0) == .sps || H264.type(of: $0) == .pps })
        let renderer = VideoRenderer() // 观察实际交给生产显示层和录制器的样本。
        var samples: [CMSampleBuffer] = []
        var sizeChanges = 0
        renderer.onSampleBuffer = { samples.append($0) }
        renderer.onSize = { _ in sizeChanges += 1 }
        renderer.consume(VideoPacket(accessUnit: config))
        renderer.consume(VideoPacket(accessUnit: config)) // 同一配置重发不触发尺寸发布。
        let originUs: Int64 = 8_000_000_000 // 设备时间与当前 Mac 时钟互不相干。
        let start = CMClockGetTime(CMClockGetHostTimeClock())
        renderer.consume(VideoPacket(accessUnit: annexB([idr]), timing: .init(presentationTimeUs: originUs, isKeyFrame: true)))
        let startup = CMClockGetTime(CMClockGetHostTimeClock()) - start // 首帧的预览解码器初始化时间随机器负载变化。
        let burstStartUs = originUs + max(16_667, Int64(startup.seconds * 1_000_000))
        renderer.consume(VideoPacket(accessUnit: annexB([deltas[0]]), timing: .init(presentationTimeUs: burstStartUs, isKeyFrame: false)))
        renderer.consume(VideoPacket(accessUnit: annexB([deltas[1]]), timing: .init(presentationTimeUs: burstStartUs + 16_667, isKeyFrame: false)))
        require(samples.count == 3 && sizeChanges == 1, "重复配置影响了连续视频帧的送显")
        let step = samples[2].presentationTimeStamp - samples[1].presentationTimeStamp // 比较同批到达的两个增量帧。
        require(abs(step.seconds - 0.016667) < 0.000001, "连续到达的帧失去了设备端帧间隔")
        let headroom = samples[0].presentationTimeStamp - start
        require(abs(headroom.seconds) < 0.25, "首帧未映射到 Mac 显示时钟")
        func hasFlag(_ sample: CMSampleBuffer, _ key: CFString) -> Bool {
            let flags = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Bool]]
            return flags?.first?[key as String] == true // 与 Core Media 对缺省布尔值的解释一致。
        }
        require(samples.allSatisfy { !hasFlag($0, kCMSampleAttachmentKey_DisplayImmediately) }, "Android 帧仍要求替换队列中的画面")
        require(!hasFlag(samples[0], kCMSampleAttachmentKey_NotSync) && hasFlag(samples[1], kCMSampleAttachmentKey_NotSync), "关键帧与增量帧标记错误")
        renderer.reset()
        renderer.consume(VideoPacket(accessUnit: config))
        renderer.consume(VideoPacket(accessUnit: annexB([idr]))) // 无设备时间戳的鸿蒙仍使用实时送显。
        require(samples.count == 4 && hasFlag(samples[3], kCMSampleAttachmentKey_DisplayImmediately), "鸿蒙送显方式发生变化")
        print("通过：Android 帧间隔、主机时钟、关键帧标记、重复配置及鸿蒙实时送显。")
    }

    static func snapshot(_ window: NSWindow, name: String) throws { // 原生截图包括标题栏而非只截视频内容。
        window.makeKeyAndOrderFront(nil) // 只激活本测试进程自己的窗口。
        settle() // 等待完整标题与内容布局。
        guard let chrome = window.contentView?.superview, let bitmap = chrome.bitmapImageRepForCachingDisplay(in: chrome.bounds) else { throw HdcError("无法读取原生窗口视图") } // 不伪造示意图。
        chrome.cacheDisplay(in: chrome.bounds, to: bitmap) // 保留真实标题栏布局与图标。
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("outputs/macos-ui-tests") // 截图只进入忽略的本地输出目录。
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) // 不覆盖旧任务材料。
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw HdcError("无法导出窗口截图") } // 原生位图必须有效。
        try png.write(to: folder.appendingPathComponent(name)) // 用户可查看真实对比。
    }
}
