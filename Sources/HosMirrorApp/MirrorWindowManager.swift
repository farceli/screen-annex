import AppKit
import SwiftUI
import Combine
import HosMirrorCore

/// Owns AppKit mirror windows so each device gets a real, aspect-correct window
/// without the phantom default window that `WindowGroup(for:)` creates.
@MainActor
final class MirrorWindowManager: NSObject, NSWindowDelegate, ObservableObject {
    static let shared = MirrorWindowManager()

    private var windows: [String: MirrorDeviceWindow] = [:]
    private var awaitingInitialLayout = Set<String>() // 窗口已建立但尚未按首个视频方向定好尺寸。
    private var observers: [String: MirrorWindowObserver] = [:]
    private var controllers: [String: DeviceController] = [:]
    private var recentWindowIDs: [String] = [] // 从最近使用到最早使用，退出应用或最小化不清空。
    private var dockEntries: [String: MirrorDockEntry] = [:] // 每个设备独立注册图标与型号。
    private var creatingDockIDs = Set<String>() // codesign 等待时避免重复处理型号观察通知。
    private var visibleDockIDs = Set<String>()
    var dockSource: Bundle? // 直接运行 Swift 测试时由测试注入实际 App 包。
    var onWindowPresenceChanged: (() -> Void)? // 由应用生命周期统一决定是否显示 Dock 图标。
    @Published private(set) var focusedController: DeviceController? // 菜单快捷键跟随当前投屏窗口。

    var needsFallbackDockEntry: Bool { recentWindowIDs.contains { !visibleDockIDs.contains($0) } }

    var dockWindows: [(String, String)] {
        recentWindowIDs.compactMap { id in windows[id].map { (id, $0.title) } }
    }

    @discardableResult
    func showWindow(id: String) -> Bool {
        guard !awaitingInitialLayout.contains(id), let window = windows[id] else { return false }
        NSApp.activate(ignoringOtherApps: true) // 从其他应用切回时让窗口真正来到前台。
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        MirrorWindowSnap.shared.revealGroup(from: id) // 已是焦点时，Dock 点击仍会唤回其他设备。
        return true
    }

    @discardableResult
    func showMostRecentWindow() -> Bool {
        guard let id = recentWindowIDs.first else { return false }
        return showWindow(id: id)
    }

    func hasOpenWindow(for controller: DeviceController) -> Bool {
        windows[controller.id] != nil && controllers[controller.id] === controller // 最小化的投屏仍有窗口；已关闭的立即从集合移除。
    }

    func open(serial: String, store: SessionStore, platform: DevicePlatform = .harmony, model: String = "", connectImmediately: Bool = true) {
        if platform == .android {
            guard connectImmediately else { return } // 不为 Android 创建占位的自研播放窗口。
            let controller = store.controller(for: serial, platform: platform, model: model)
            if controller.connected { controller.bringAndroidWindowToFront(); return } // 同一设备只激活自己的窗口。
            guard !controller.hasPendingOrOpenConnection else { return } // 启动和重连不会因重复点击而重置。
            controller.connect() // 官方客户端创建自己的 SDL 窗口。
            return
        }
        let key = platform.identifier(serial: serial) // 窗口身份包含系统，底层序列号不变。
        if windows[key] != nil {
            showWindow(id: key)
            if connectImmediately, let controller = controllers[key],
               !controller.connected, !controller.busy, !controller.reconnectPending {
                controller.connect()
            }
            return
        }

        let controller = store.controller(for: serial, platform: platform, model: model)
        if connectImmediately && !controller.hasVideoFormat { awaitingInitialLayout.insert(key) }
        store.restoreAlwaysOnTop(for: controller) // 重开时恢复本设备的独立选择。
        // Host SwiftUI inside a plain container so a re-render can never
        // propagate a fitting size that resizes the window behind our back.
        let container = MirrorContentView(rootView: MirrorPane(controller: controller), controller: controller) // 内容容器覆盖视频、连接画面和任务面板的拖放。

        let window = MirrorDeviceWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 780),
            styleMask: [.titled, .resizable, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        window.titleVisibility = .hidden
        // 保留与 SDL 同样的原生标题栏背景和内容分隔，由 AppKit 按窗口外观绘制。
        window.appearance = store.settings.mirrorAppearance.native // 默认浅色，同时尊重用户明确选择的深色或系统模式。
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.title = controller.windowTitle // 名称尚未读取时不把序列号当作型号。
        window.identifier = NSUserInterfaceItemIdentifier(key)
        window.delegate = self
        let visible = window.availableScreenFrame
        window.setFrameTopLeftPoint(NSPoint(x: max(window.frame.minX, visible.minX), y: visible.maxY)) // 只在创建时放到可见区域顶部。

        MirrorTitlebar.install(
            on: window,
            controller: controller,
            store: store, // 标题栏将置顶操作绑定到本设备。
            presentText: { [weak window] in
                guard let window else { return }
                MirrorWindowManager.presentTextSheet(on: window, controller: controller)
            }
        )

        windows[key] = window
        controllers[key] = controller
        observers[key] = MirrorWindowObserver(
            window: window,
            controller: controller,
            store: store,
            waitForVideoFormat: connectImmediately
        )

        if connectImmediately { // 隔离窗口检查可以跳过真实设备操作。
            if !controller.hasPendingOrOpenConnection { controller.connect() }
        } else {
            presentWindow(for: controller)
        }
    }

    fileprivate func presentWindow(for controller: DeviceController) {
        let id = controller.id
        guard controllers[id] === controller, !recentWindowIDs.contains(id) else { return }
        awaitingInitialLayout.remove(id)
        recentWindowIDs.insert(id, at: 0)
        updateDockEntry(for: controller)
        onWindowPresenceChanged?() // 提升激活策略后再显示窗口，Dock 可以立即返回这里。
        showWindow(id: id)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let serial = window.identifier?.rawValue,
              windows[serial] === window,
              let controller = controllers[serial]
        else { return }

        unregisterWindow(for: controller)
        controller.disconnect() // 窗口已经开始关闭，只需清理投屏会话。
    }

    func closeWindow(for controller: DeviceController) {
        guard controllers[controller.id] === controller, let window = windows[controller.id] else { return }
        unregisterWindow(for: controller) // 先移除关联，关闭通知不会重复断开。
        window.close()
    }

    private func unregisterWindow(for controller: DeviceController) {
        awaitingInitialLayout.remove(controller.id)
        dockEntries.removeValue(forKey: controller.id)?.close()
        visibleDockIDs.remove(controller.id)
        MirrorWindowSnap.shared.remove(controller.id)
        if focusedController === controller { focusedController = nil }
        observers.removeValue(forKey: controller.id)?.detach()
        windows[controller.id] = nil
        controllers[controller.id] = nil
        recentWindowIDs.removeAll { $0 == controller.id }
        onWindowPresenceChanged?()
    }

    fileprivate func updateDockEntry(for controller: DeviceController) {
        let id = controller.id
        guard let dockSource, hasOpenWindow(for: controller), !awaitingInitialLayout.contains(id), !controller.deviceModel.isEmpty,
              dockEntries[id]?.model != controller.deviceModel, creatingDockIDs.insert(id).inserted else { return }
        defer { creatingDockIDs.remove(id) }
        do {
            let entry = try MirrorDockEntry(model: controller.deviceModel, source: dockSource) { [weak self] in
                self?.showWindow(id: id)
            } closeWindow: { [weak self] in
                self?.windows[id]?.close()
            } didLaunch: { [weak self] launched in
                guard let self else { return }
                if launched { self.visibleDockIDs.insert(id) }
                else { self.dockEntries[id] = nil }
                self.onWindowPresenceChanged?()
            }
            guard hasOpenWindow(for: controller) else { entry.close(); return }
            dockEntries.updateValue(entry, forKey: id)?.close()
            visibleDockIDs.remove(id)
            onWindowPresenceChanged?()
        } catch {
            controller.log("设备 Dock 入口创建失败：\(error.localizedDescription)")
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? MirrorDeviceWindow, let id = window.identifier?.rawValue else { return }
        focusedController = controllers[id] // AppKit 已将这个投屏窗口设为当前窗口。
        guard windows[id] === window else { return }
        MirrorWindowSnap.shared.revealGroup(from: id)
        recentWindowIDs.removeAll { $0 == id }
        recentWindowIDs.insert(id, at: 0)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? MirrorDeviceWindow, let id = window.identifier?.rawValue,
              let focusedController, focusedController === controllers[id] else { return }
        self.focusedController = nil // 只清理失去焦点的窗口，避免覆盖另一个已获得焦点的窗口。
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        if let window = sender as? MirrorDeviceWindow, let snapped = window.snappedFrame { return snapped.size }
        return (sender as? MirrorDeviceWindow)?.constrainedFrameSize(frameSize) ?? frameSize // 拖任意边都同步约束另一个方向，并遵守最小尺寸。
    }

    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        guard let window = window as? MirrorDeviceWindow else { return newFrame }
        return window.snappedFrame ?? window.maximumDeviceFrame // 磁吸时原生缩放入口也使用分配的外框。
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? MirrorDeviceWindow else { return }
        window.enforceSnapFrame() // 系统窗口命令也要遵守磁吸位置。
        if window.snappedFrame == nil, let id = window.identifier?.rawValue,
           !awaitingInitialLayout.contains(id), controllers[id]?.connected == true {
            window.reportSnapGeometry(id: id) // 只记录自由布局的位置，用于下次开启磁吸时排序。
        }
    }

    func windowDidResize(_ notification: Notification) {
        (notification.object as? MirrorDeviceWindow)?.enforceSnapFrame()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        (notification.object as? MirrorDeviceWindow)?.enforceSnapFrame()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        (notification.object as? MirrorDeviceWindow)?.enforceSnapFrame()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard let window = notification.object as? MirrorDeviceWindow else { return }
        window.updateLayout(device: window.deviceSize, title: window.title) // 移到另一屏幕时重新计算可用大小。
    }

    // MARK: - Text injection

    static func presentRename(on window: NSWindow?, controller: DeviceController, store: SessionStore) {
        presentRename(on: window, current: controller.customName,
                      placeholder: controller.deviceModel.isEmpty ? controller.serial : controller.deviceModel) { name in
            store.setCustomName(name, for: controller)
        }
    }

    static func presentRename(on window: NSWindow?, current: String?, placeholder: String,
                              save: @escaping (String) -> Void) {
        guard let window, window.attachedSheet == nil else { return } // 将改名表单绑定到触发操作的窗口。
        let alert = NSAlert() // 使用 AppKit 的原生模态表单。
        alert.messageText = "自定义设备名称"
        alert.informativeText = "此名称仅在 Screen Annex 中显示。留空并保存可恢复默认名称。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 270, height: 24)) // 单行输入，避免名称折行。
        field.stringValue = current ?? ""
        field.placeholderString = placeholder
        field.setAccessibilityLabel("设备名称")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field // 打开后直接输入。
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return } // 取消保留原名称。
            save(field.stringValue)
        }
    }

    static func presentTextSheet(on window: NSWindow, controller: DeviceController) {
        let alert = NSAlert()
        alert.messageText = "发送文本到设备"
        alert.informativeText = "文本会注入到设备当前光标位置。"
        alert.addButton(withTitle: "发送")
        alert.addButton(withTitle: "取消")

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 110))
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true

        let textView = NSTextView(frame: scroll.bounds)
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        scroll.documentView = textView
        alert.accessoryView = scroll

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let text = textView.string
            guard !text.isEmpty else { return }
            Task { @MainActor in controller.sendText(text) }
        }
        DispatchQueue.main.async { alert.window.makeFirstResponder(textView) }
    }
}

// MARK: - Content container

/// Plain AppKit container for the SwiftUI mirror pane. Using a container (rather
/// than making the hosting view the window's content view directly) keeps
/// SwiftUI re-renders from feeding a fitting size back into the window.
final class MirrorContentView: NSView {
    private let hosting: MirrorHostingView<MirrorPane>
    private weak var controller: DeviceController? // 不延长已经关闭的设备会话生命周期。

    init(rootView: MirrorPane, controller: DeviceController? = nil) {
        hosting = MirrorHostingView(rootView: rootView) // SwiftUI 容器也允许非活动窗口接收第一次点击。
        self.controller = controller // 默认 nil 保留原有离屏 UI 夹具的可用性。
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL, .png, .tiff]) // 同时支持 Finder 文件与剪贴板形式的拖放图片。
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true } // 未聚焦时点击仍进入内容视图，不在容器层被吞掉。

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard controller != nil, sender.draggingSourceOperationMask.contains(.copy) else { return [] } // 只接受复制语义，绝不移动电脑原文件。
        controller?.fileDrops.hovering = true // SwiftUI 显示目标高亮。
        return .copy // 系统指针显示可复制标记。
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) } // 指针跨越视频/任务面板时保持同一目标。
    override func draggingExited(_ sender: NSDraggingInfo?) { controller?.fileDrops.hovering = false } // 离开目标即清除高亮。
    override func draggingEnded(_ sender: NSDraggingInfo) { controller?.fileDrops.hovering = false } // 拖放取消也清理状态。

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let controller else { return false } // 已关闭的窗口不得发送文件。
        controller.fileDrops.hovering = false // 放下后立即切换为任务状态。
        let pasteboard = sender.draggingPasteboard // 只读取本次用户主动拖入的数据。
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [] // 优先使用原文件，保留格式和名字。
        if !urls.isEmpty {
            controller.fileDrops.enqueue(urls, directory: controller.fileDestination, connected: controller.connected) // 一次多选按顺序排队。
            return true // 后续成功或错误都在面板显示。
        }
        guard let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { return false } // 无文件 URL 的图片统一导出无损 PNG。
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("拖入图片-\(UUID().uuidString).png") // 仅创建本应用独占的临时副本。
        do {
            try png.write(to: local, options: .atomic) // 成功写出后才允许排入发送队列。
            controller.fileDrops.enqueue([local], directory: controller.fileDestination, connected: controller.connected, removeAfter: true) // 任务结束清理临时副本。
        } catch {
            let alert = NSAlert() // 本地图片导出失败时也有明确提示。
            alert.messageText = "发送失败" // 与传输错误保持同一措辞。
            alert.informativeText = "无法读取拖入图片：\(error.localizedDescription)" // 显示磁盘/权限等实际原因。
            if let window { alert.beginSheetModal(for: window) } // 使用原生窗口提示，不阻塞全局事件循环。
        }
        return true // 拖放已接收且已经产生任务或可见错误。
    }

    override func layout() {
        super.layout()
        hosting.frame = bounds
    }
}

// MARK: - Titlebar

@MainActor
enum MirrorTitlebar {
    static func install(
        on window: NSWindow,
        controller: DeviceController,
        store: SessionStore,
        presentText: @escaping () -> Void
    ) {
        let trailingHost = MirrorHostingView(
            rootView: MirrorTitlebarControls(controller: controller, store: store, presentText: presentText)
        )
        trailingHost.identifier = NSUserInterfaceItemIdentifier("hosmirror.titlebar-controls") // 用于原生布局验证。
        guard let titlebar = window.standardWindowButton(.closeButton)?.superview else { return } // 通过公开窗口按钮定位原生标题栏。
        trailingHost.translatesAutoresizingMaskIntoConstraints = false
        titlebar.addSubview(trailingHost) // 在现有原生标题栏内布置按钮，避免附件抬高窗口标题栏。
        (window as? MirrorDeviceWindow)?.titleControls = trailingHost
        let title = MirrorTitleHostingView(rootView: MirrorTitleView(controller: controller))
        title.identifier = NSUserInterfaceItemIdentifier("hosmirror.centered-title") // 验证相对整个窗口的实际中心。
        title.translatesAutoresizingMaskIntoConstraints = false // 让标题跟随整个标题栏的几何中心，而非两侧剩余空间。
        titlebar.addSubview(title)
        let reserve = MirrorTitlebarControls.width + 8 // 左右对称保留空间，避免标题挤进交通灯或功能区。
        let titleHeight = window.frame.height - window.contentRect(forFrameRect: window.frame).height
        let width = title.widthAnchor.constraint(equalTo: titlebar.widthAnchor, constant: -2 * reserve)
        width.priority = .defaultHigh // 多台设备挤在同一屏时允许缩到零宽，避免约束冲突。
        NSLayoutConstraint.activate([
            trailingHost.trailingAnchor.constraint(equalTo: titlebar.trailingAnchor, constant: -6),
            trailingHost.centerYAnchor.constraint(equalTo: titlebar.centerYAnchor),
            trailingHost.widthAnchor.constraint(equalToConstant: MirrorTitlebarControls.width),
            trailingHost.heightAnchor.constraint(equalToConstant: titleHeight),
            title.centerXAnchor.constraint(equalTo: titlebar.centerXAnchor),
            title.centerYAnchor.constraint(equalTo: titlebar.centerYAnchor),
            title.heightAnchor.constraint(equalToConstant: titleHeight),
            title.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
            width,
        ])
    }
}

/// 原生点击穿过窗口激活阶段，供视频容器与标题栏按钮共用。
class MirrorHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true } // 只接受系统已经派发的首击，不合成或重复发送事件。
}

/// 标题仅负责显示，鼠标事件继续交给原生标题栏，保留拖动窗口的行为。
private final class MirrorTitleHostingView: NSHostingView<MirrorTitleView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil } // 不拦截标题栏拖动与双击。
}

struct MirrorTitleView: View {
    @ObservedObject var controller: DeviceController

    private var label: String {
        controller.windowTitle // 固定前缀只用于窗口标题，不增加连接画面文案。
    }

    var body: some View {
        (Text(controller.platform.windowTitlePrefix).bold()
         + Text(" " + (controller.displayName.isEmpty ? "设备" : controller.displayName)))
            .font(.system(size: 12, weight: .regular)) // 前缀加粗，设备名保持常规字重。
            .foregroundStyle(.primary) // 浅色使用深字，深色使用浅字，跟随原生窗口外观。
            .lineLimit(1)
            .minimumScaleFactor(0.8) // 极小屏幕无法容纳首选最小尺寸时保留标题可读性。
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .help("\(label) · \(controller.connected ? "已连接" : "未连接")")
    }
}

struct MirrorTitlebarControls: View {
    static let width: CGFloat = 100 // 桌面、多任务、置顶、更多，共四个紧凑的图标位置。
    @ObservedObject var controller: DeviceController
    let store: SessionStore // 置顶偏好由会话存储按设备写入。
    let presentText: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            button("house", "桌面") { controller.press(KeyMap.home) }
            button("rectangle.on.rectangle", "多任务") { controller.press(KeyMap.recent) }
            Button { store.toggleAlwaysOnTop(for: controller) } label: {
                Image(systemName: controller.isAlwaysOnTop ? "pin.fill" : "pin")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(controller.isAlwaysOnTop ? Color.accentColor : Color.primary)
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(controller.isAlwaysOnTop ? "取消窗口置顶" : "窗口置顶")
            .accessibilityLabel("窗口置顶")
            .accessibilityValue(controller.isAlwaysOnTop ? "已开启" : "已关闭")
            overflowMenu
        }
        .padding(.horizontal, 3)
        .frame(width: Self.width)
    }

    private func button(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary) // 功能图标与标题使用同一语义前景色。
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var overflowMenu: some View {
        Menu {
            Button("自定义设备名称…") {
                MirrorWindowManager.presentRename(on: NSApp.keyWindow, controller: controller, store: store) // 修改当前投屏窗口对应的设备。
            }
            Divider()
            Button("返回（右键返回 / 熄屏时唤醒）") { controller.rightClick() }
            Button("旋转") { controller.rotate() }
                .keyboardShortcut("r", modifiers: .command)
            Button("截图") { controller.screenshot() }
                .keyboardShortcut("s", modifiers: .command)
            Button(controller.isRecording ? "停止录制" : "开始录制") { controller.toggleRecording() }
            Divider()
            Button("发送文本…") { presentText() }
            Button("粘贴电脑剪贴板") { controller.pasteFromMac() }
            Button("复制设备剪贴板") { controller.copyToMac() }
            FileDropHistoryMenuItem(transfers: controller.fileDrops) // 直接观察任务记录，提示自动收起后仍可按需查看。
            Divider()
            Button("电源键") { controller.press(KeyMap.power) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(controller.isRecording ? Color.red : Color.primary) // 录制反馈保留，常态图标同时适配深浅色。
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22, height: 20)
        .help(controller.isRecording ? "更多 · 正在录制" : "更多")
        .accessibilityLabel(controller.isRecording ? "更多，正在录制" : "更多功能")
    }
}

// MARK: - Window lifecycle

@MainActor
private final class MirrorWindowObserver {
    private var cancellables = Set<AnyCancellable>()
    private var hasFittedVideo = false // 每个窗口只在首个视频方向确定时自动最大化一次。
    private let window: MirrorDeviceWindow

    init(window: MirrorDeviceWindow, controller: DeviceController, store: SessionStore, waitForVideoFormat: Bool) {
        self.window = window

        controller.$physicalSize.combineLatest(controller.$connected, controller.$hasVideoFormat)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2 }
            .receive(on: RunLoop.main)
            .sink { [weak self, weak controller] _, _, _ in
                guard let self, let controller else { return }
                let manager = MirrorWindowManager.shared
                // 同一轮通知可能包含旧方向。读取已提交的最新值，避免短暂应用探测比例。
                if waitForVideoFormat && !controller.hasVideoFormat { return }
                self.updateVideoLayout(size: controller.physicalSize, connected: controller.connected, id: controller.id)
                if controller.hasVideoFormat && controller.connected {
                    manager.presentWindow(for: controller) // 磁吸布局也在首次显示前完成。
                }
            }
            .store(in: &cancellables)

        controller.$busy.combineLatest(controller.$connected, controller.$reconnectPending)
            .receive(on: RunLoop.main)
            .sink { [weak controller] _, _, _ in
                guard let controller, !controller.busy, !controller.connected, !controller.reconnectPending else { return }
                MirrorWindowManager.shared.presentWindow(for: controller) // 初次连接失败时仍可在窗口内查看状态和重试。
            }
            .store(in: &cancellables)

        controller.$deviceModel.combineLatest(controller.$customName)
            .map { [platform = controller.platform] model, customName in platform.title(model: customName ?? model) } // 别名变化和回退均更新系统窗口标题。
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] title in
                guard let self else { return }
                self.window.title = title // 系统窗口列表与居中标题显示相同固定前缀。
                self.window.updateLayout(device: self.window.deviceSize, title: self.window.title) // 名称变长时同步提高可读最小宽度。
            }
            .store(in: &cancellables)

        controller.$deviceModel.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak controller] _ in
                if let controller { MirrorWindowManager.shared.updateDockEntry(for: controller) }
            }
            .store(in: &cancellables)

        controller.$isAlwaysOnTop
            .removeDuplicates()
            .sink { [weak window] pinned in
                window?.level = pinned ? .floating : .normal // 当前原生窗口立即应用本设备的选择。
            }
            .store(in: &cancellables)

        store.$settings
            .receive(on: RunLoop.main)
            .sink { [weak self] settings in
                self?.window.appearance = settings.mirrorAppearance.native // 保存外观后立即更新，无需断开投屏。
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.window.updateLayout(device: self.window.deviceSize, title: self.window.title) // 显示器分辨率或 Dock 可用区域改变后重新约束。
            }
            .store(in: &cancellables)

        window.updateLayout(device: controller.physicalSize, title: window.title) // 连接加载阶段也不能缩到标题栏重叠。
    }

    func detach() {
        cancellables.removeAll() // 关闭窗口后停止设备和屏幕通知订阅。
    }

    private func updateVideoLayout(size: CGSize, connected: Bool, id: String) {
        let maximize = connected && !hasFittedVideo
        if connected { hasFittedVideo = true }
        window.updateLayout(device: size, title: window.title, maximize: maximize)
        if connected { window.reportSnapGeometry(id: id) }
        // 重连时仍使用上次确定的磁吸外框，关闭窗口时由管理器移出窗口组。
    }
}
