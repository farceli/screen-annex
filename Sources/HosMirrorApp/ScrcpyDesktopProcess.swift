import AppKit // 前置窗口使用系统进程 API，不申请辅助功能权限。
import Combine // 观察文件队列的当前任务和结果。
import Darwin // 超时仅结束本次启动的进程。
import HosMirrorCore // 内置客户端与设备端固定为同一官方版本。
import SwiftUI // 复用鸿蒙传输记录的详情视图。

/// 生命周期包装；Android 的视频、音频和控制均留在官方进程内。
@MainActor
final class ScrcpyDesktopProcess {
    private let process = Process() // 每台设备只管理自己的客户端。
    private let output = Pipe() // 读取启动结果，防止子进程被填满的管道阻塞。
    private var pending = Data() // 一行日志可能分几段到达。
    private var windowWatch: Task<Void, Never>? // 等待官方客户端显示首帧窗口。
    private var lastError: String? // 只留最近的上游错误供界面显示。
    private var stopping = false // 多次关窗、取消或退出合并为一次停止。
    private var didFinish = false // 进程可能已退出，主线程的退出回调还没有执行。
    private var didShowWindow = false // 首帧窗口出现之前，ADB 已连接也不算在投屏。
    private let snapChannel = "com.hosmirror.scrcpy.\(UUID().uuidString)" // 每个子进程有独立的本机端口。
    private var snapEvents: SettingsPanelPort?
    private var snapGeometry: MirrorWindowSnap.Geometry?
    private var snapID: String?
    private var dockDirectory: URL?
    private weak var transfers: FileDropController? // 每个 scrcpy 窗口只观察其目标设备。
    private var transferObservation: AnyCancellable? // 客户端退出时结束状态观察。
    private var transferUpdate: Task<Void, Never>? // 合并同一轮主线程内的多次状态更新。
    private var transferReady = false // 子进程的命令端口就绪后才发送状态。
    private var lastToast: FileDropToastSnapshot? // 只发送变化后的快照。
    private var transferHistory: NSPanel? // 每台设备只打开一个传输记录窗口。
    var hasOpenWindow: Bool { didShowWindow && process.isRunning && !stopping } // 官方客户端关闭主窗口时会退出。
    private var completions: [() -> Void] = [] // App 退出可等待官方客户端自行清理。

    var onVideo: (() -> Void)?
    var onExit: ((Int32, String?) -> Void)?
    var onDrop: (([URL]) -> Void)? // 将一批拖入的文件交给绑定设备的队列。

    func start(directory: URL, arguments: [String], windowID: String, displayName: String, transfers: FileDropController) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(snapChannel, isDirectory: true)
        do {
            let bundle = try MirrorDockBundle.create(in: temporary, identifier: snapChannel, model: displayName, fallback: "设备",
                                                     executable: directory.appendingPathComponent("scrcpy"), executableName: "scrcpy",
                                                     icon: directory.appendingPathComponent("scrcpy.png"))
            process.executableURL = bundle.appendingPathComponent("Contents/MacOS/scrcpy")
            dockDirectory = temporary
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        process.arguments = arguments // 直接传入参数数组，不调用 shell。
        var environment = AndroidRuntime.environment(directory: directory) // 使用本机 ADB 和随包的服务端。
        snapID = windowID
        snapEvents = SettingsPanelPort(name: snapChannel + ".events") { [weak self] data in self?.handleWindowEvent(data) } // 复用当前窗口的消息端口。
        if snapEvents != nil { environment["HOSMIRROR_WINDOW_CHANNEL"] = snapChannel }
        self.transfers = transfers // 将任务状态绑定到本次启动的窗口。
        transferObservation = transfers.objectWillChange.sink { [weak self] in self?.scheduleTransferUpdate() } // 在变更实际提交之后读取快照。
        process.environment = environment
        process.standardInput = FileHandle.nullDevice // 客户端通过自己的窗口接收输入。
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData // 后台读取，主线程只处理小量文本。
            if chunk.isEmpty { handle.readabilityHandler = nil; return } // EOF 后停止监听。
            DispatchQueue.main.async { [weak self] in self?.consume(chunk) }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus // 只在进程退出后读取状态码。
            DispatchQueue.main.async { [weak self] in self?.finished(status) }
        }
        do { try process.run() }
        catch {
            output.fileHandleForReading.readabilityHandler = nil // 启动失败时不保留文件句柄监听。
            process.terminationHandler = nil
            closeTransferInterface() // 启动失败时释放传输队列观察。
            removeDockBundle()
            throw error
        }
        windowWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard self?.stillWaitingForWindow() == true else { return }
                try? await Task.sleep(for: .milliseconds(150)) // 未显示时继续等，避免阻塞或依赖管道日志缓冲。
            }
        }
    }

    func bringToFront() {
        guard process.isRunning else { return } // 已退出的 PID 不再作为目标。
        NSRunningApplication(processIdentifier: process.processIdentifier)?.activate() // 激活这个 scrcpy 实例，不影响另一台设备。
        if let snapID { MirrorWindowSnap.shared.revealGroup(from: snapID) }
    }

    func stop(completion: (() -> Void)? = nil) {
        guard !didFinish else { completion?(); return }
        if let completion { completions.append(completion) }
        guard !stopping else { return }
        stopping = true
        closeTransferInterface() // 主动关窗时一并关闭这台设备的传输记录。
        unregisterSnapWindow()
        windowWatch?.cancel() // 不将正在关闭的窗口当成刚完成的连接。
        guard process.isRunning else { return } // 等退出回调释放控制器的旧实例后再重启。
        process.interrupt() // 官方 SDL 将 SIGINT 转为退出事件，清理该设备会话。
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.process.isRunning else { return }
            kill(self.process.processIdentifier, SIGKILL) // 不按名称终止其他 scrcpy 或共享 ADB。
        }
    }

    private func consume(_ chunk: Data) {
        pending.append(chunk)
        while let newline = pending.firstIndex(of: 10) {
            let line = String(decoding: pending[..<newline], as: UTF8.self) // 上游工具的标准文本日志。
            pending.removeSubrange(...newline)
            if line.contains("ERROR:") { lastError = String(line.prefix(512)) } // 记录有界错误，不持久化日志。
        }
        if pending.count > 8192 { pending.removeAll(keepingCapacity: true) } // 无换行输出也不会无限增长。
    }

    private func stillWaitingForWindow() -> Bool {
        guard process.isRunning, !stopping else { return false }
        // scrcpy 收到首帧后才显示 SDL 主窗口。只读取窗口所属 PID 和层级，不读取标题、像素或辅助功能数据。
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        let normalLayer = Int(CGWindowLevelForKey(.normalWindow))
        let floatingLayer = Int(CGWindowLevelForKey(.floatingWindow))
        let shown = windows?.contains {
            guard $0[kCGWindowOwnerPID as String] as? Int32 == process.processIdentifier,
                  let layer = $0[kCGWindowLayer as String] as? Int else { return false }
            return layer == normalLayer || layer == floatingLayer // 已置顶的 SDL 窗口也能完成首帧检测。
        } ?? false
        guard shown else { return true }
        didShowWindow = true
        registerSnapWindow() // 此时已出现真实投屏窗口，首帧前收到的几何数据才生效。
        lastError = nil // 已成功恢复的编码器重试不应归因给之后的断开。
        onVideo?()
        return false
    }

    private func finished(_ status: Int32) {
        didFinish = true
        closeTransferInterface() // 从 SDL 关窗或连接中断也会清理界面。
        removeDockBundle()
        unregisterSnapWindow()
        snapEvents = nil
        windowWatch?.cancel()
        windowWatch = nil
        output.fileHandleForReading.readabilityHandler = nil
        onExit?(status, lastError)
        onVideo = nil
        onExit = nil
        onDrop = nil // 已结束的窗口不会再提交新任务。
        let callbacks = completions
        completions.removeAll()
        callbacks.forEach { $0() } // 每个退出等待者只通知一次。
    }

    private struct WindowEvent: Decodable {
        enum Action: String, Decodable {
            case geometry, raise, maximize, dragBegin, drag, dragEnd // 原有窗口磁吸事件。
            case dropReady, dropFiles, dropDismiss, dropHistory, dropCancel // 传输事件来自同一 scrcpy 窗口。
        }
        let action: Action
        let aspect: CGFloat?
        let titleHeight: CGFloat?
        let x: CGFloat?
        let y: CGFloat?
        let reorder: Bool?
        let paths: [String]? // 按 Finder 拖入顺序传送路径。
        let task: UUID? // 按用户实际点击的任务执行操作。
        let finished: Bool? // 已结束结果与进行中提示分别收起。
    }

    private struct SnapCommand: Encodable {
        let frame: [CGFloat]? // 由 [x, y, width, height] 表示 AppKit 屏幕坐标。
        var reveal: Bool? = nil // 单独的唤回指令不能被当成解除磁吸。
    }

    private func handleWindowEvent(_ data: Data) {
        guard !stopping, !didFinish, let id = snapID,
              let event = try? JSONDecoder().decode(WindowEvent.self, from: data) else { return }
        switch event.action {
        case .dropReady:
            transferReady = true // 子进程已经创建接收悬浮条状态的端口。
            scheduleTransferUpdate()
            return
        case .dropFiles:
            guard transferReady, process.isRunning, let paths = event.paths, !paths.isEmpty,
                  paths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }) else { return } // 只接收本机绝对路径。
            onDrop?(paths.map { URL(fileURLWithPath: $0) }) // JSON 保留 Unicode、引号及空格。
            return
        case .dropHistory:
            if transferReady { showTransferHistory() } // 菜单和悬浮条右键共用记录入口。
            return
        case .dropDismiss, .dropCancel:
            guard transferReady, let transfers, let item = transfers.toastItem,
                  item.id == event.task, item.finished == event.finished else { return } // 延迟消息不能误操作已经换掉的提示。
            if event.action == .dropDismiss { transfers.dismissToast(item) } // 收起时任务继续执行。
            else if !item.finished { transfers.cancel(item.id) } // 取消只作用于进行中的任务。
            return
        default: break // 其余消息沿用窗口磁吸处理。
        }
        let snap = MirrorWindowSnap.shared
        if event.action == .raise {
            if hasOpenWindow { snap.revealGroup(from: id) }
            return
        }
        if event.action == .maximize {
            if hasOpenWindow { snap.maximizeGroup(from: id) }
            return
        }
        guard let x = event.x, let y = event.y, x.isFinite, y.isFinite else { return }
        let point = CGPoint(x: x, y: y)
        if event.action == .geometry {
            guard let aspect = event.aspect, let titleHeight = event.titleHeight,
                  aspect.isFinite, aspect > 0, titleHeight.isFinite, titleHeight >= 0 else { return }
            snapGeometry = .init(aspect: aspect, titleHeight: titleHeight, origin: point)
            registerSnapWindow()
        } else if hasOpenWindow {
            switch event.action {
            case .dragBegin: snap.beginDrag(id, at: point, reorder: event.reorder == true)
            case .drag: snap.drag(id, to: point)
            case .dragEnd: snap.endDrag(id, at: point)
            default: break // 非拖动消息已在上方处理。
            }
        }
    }

    private struct TransferCommand: Encodable {
        let transfer = true // 明确区别于窗口位置指令。
        let toast: FileDropToastSnapshot? // 缺省时隐藏悬浮条。
    }

    private func scheduleTransferUpdate() {
        guard transferReady, transferUpdate == nil else { return } // 合并当前主线程上的连续通知。
        transferUpdate = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return } // 关窗后不再向旧端口提交。
            self.transferUpdate = nil // 后续状态变化可以排下一次更新。
            let toast = self.transfers?.toastItem.map(FileDropToastSnapshot.init) // 发布后读取实际可见任务。
            guard self.lastToast != toast else { return } // 相同进度或空状态无需重复发送。
            if SettingsPanelPort.send(TransferCommand(toast: toast), to: self.snapChannel + ".commands") {
                self.lastToast = toast // 下一次状态变化可以重试上一次未送达的快照。
            }
        }
    }

    private func showTransferHistory() {
        guard let transfers else { return } // 只显示该窗口对应设备的历史。
        let panel = transferHistory ?? NSPanel(contentRect: NSRect(x: 0, y: 0, width: 352, height: 400),
                                               styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false) // 记录独立于视频和手机输入。
        if transferHistory == nil {
            panel.title = "传输记录" // 与鸿蒙使用同一入口文案。
            panel.contentViewController = NSHostingController(rootView: FileDropHistory(transfers: transfers)) // 路径、失败原文与取消操作共用。
            panel.isReleasedWhenClosed = false // 再次查看时使用同一个窗口。
            panel.hidesOnDeactivate = false // 切回投屏后仍能查看传输状态。
            panel.center() // 第一次打开时位于当前屏幕中间。
            transferHistory = panel
        }
        NSApp.activate(ignoringOtherApps: true) // 请求来自 scrcpy，详情由 HosMirror 主进程展示。
        panel.makeKeyAndOrderFront(nil) // 让记录窗口可直接操作。
    }

    private func closeTransferInterface() {
        transferReady = false // 不再向退出中的窗口提交状态。
        transferObservation = nil // 解除队列观察。
        transferUpdate?.cancel() // 取消尚未执行的快照。
        transferUpdate = nil
        transferHistory?.close() // 随设备投屏关闭记录窗口。
        transferHistory = nil
    }

    private func registerSnapWindow() {
        guard hasOpenWindow, let id = snapID, let snapGeometry else { return }
        MirrorWindowSnap.shared.update(id, geometry: snapGeometry, apply: { [weak self] frame in
            guard let self else { return }
            let coordinates = frame.map { [$0.minX, $0.minY, $0.width, $0.height] }
            _ = SettingsPanelPort.send(SnapCommand(frame: coordinates), to: self.snapChannel + ".commands")
        }) { [weak self] in
            guard let self else { return }
            _ = SettingsPanelPort.send(SnapCommand(frame: nil, reveal: true), to: self.snapChannel + ".commands")
        }
    }

    private func unregisterSnapWindow() {
        if let snapID { MirrorWindowSnap.shared.remove(snapID) }
    }

    private func removeDockBundle() {
        if let dockDirectory { try? FileManager.default.removeItem(at: dockDirectory) }
        dockDirectory = nil
    }
}
