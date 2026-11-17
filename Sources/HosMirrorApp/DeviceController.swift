import Foundation
import SwiftUI
import AppKit
import HosMirrorCore

struct MirrorSettings: Codable, Equatable {
    var frameRate: Int = 30
    var bitRateMbps: Int = 16
    var scale: Double = 1.0
    var autoReconnect: Bool = true
    var alwaysOnTop: Bool = false // 打开时，新连接使用置顶；关闭时恢复各设备自己的选择。
    var lockPhonesPreference: Bool? // 旧版设置缺少字段时默认开启。
    var unlockPhonesPreference: Bool?
    var lockPhonesWithMac: Bool {
        get { lockPhonesPreference ?? true }
        set { lockPhonesPreference = newValue }
    }
    var unlockPhonesWithMac: Bool {
        get { unlockPhonesPreference ?? true }
        set { unlockPhonesPreference = newValue }
    }
    private var harmonyQualityVersion: Int? = 2 // 仅迁移旧版出厂参数。
    var appearancePreference: MirrorAppearance? // 可选字段兼容旧设置，缺省时使用浅色。
    var mirrorAppearance: MirrorAppearance {
        get { appearancePreference ?? .light } // 不因旧配置缺少外观字段而丢失其余设置。
        set { appearancePreference = newValue } // 与画质和置顶偏好一同持久化。
    }
    var fileDropDirectory: String? // 可选字段兼容已有设置，新增功能不会重置画质和置顶偏好。
    var androidFileDropDirectory: String? // Android 公共下载目录与鸿蒙目录采用相同设置语义。
    var androidFileDestination: String {
        get { androidFileDropDirectory ?? DevicePlatform.android.defaultDirectory } // 默认同样为手机“下载/HosMirror”。
        set { androidFileDropDirectory = newValue } // 独立存储不同系统的物理路径。
    }
    var fileDestination: String {
        get { fileDropDirectory ?? FileDelivery.defaultDirectory } // 首次使用默认进入手机“下载/HosMirror”。
        set { fileDropDirectory = newValue } // 保存用户指定的手机目录。
    }

    static let storageKey = "mirror.settings"

    static func load(from defaults: UserDefaults = .standard) -> MirrorSettings {
        guard let data = defaults.data(forKey: storageKey),
              var value = try? JSONDecoder().decode(MirrorSettings.self, from: data)
        else { return MirrorSettings() }
        let version = value.harmonyQualityVersion ?? 0
        if version < 2 {
            let previousDefault = version == 0 ? 8 : 12
            if value.frameRate == 30, value.bitRateMbps == previousDefault, value.scale == 1 {
                value.bitRateMbps = MirrorSettings().bitRateMbps
            }
            if value.scale == 0.75 { value.scale = 1 } // 旧 75% 实际一直是原始分辨率。
            value.harmonyQualityVersion = 2
            value.save(to: defaults) // 保存迁移标记，今后可以手动选回旧版参数。
        }
        return value
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    var summary: String {
        "\(frameRate) fps · \(bitRateMbps) Mbps · \(Int(scale * 100))%"
    }
}

@MainActor
final class DeviceController: ObservableObject, Identifiable {
    nonisolated let serial: String // 设备标识不可变，允许 Identifiable 非隔离读取。
    nonisolated let platform: DevicePlatform // 同一套界面按后端转换协议。
    nonisolated var id: String { platform.identifier(serial: serial) }
    var displayName: String { customName ?? deviceModel } // 改名覆盖展示文本，底层识别继续使用原始型号。
    private var mirrorName: String {
        // 仅 Android 的枚举可能用序列号补空字段，投屏界面改用明确的通用名称。
        if platform == .android, customName == nil, deviceModel == serial { return "设备" }
        return displayName.isEmpty ? "设备" : displayName
    }
    var windowTitle: String { platform.title(model: mirrorName) } // Dock 复用去掉系统前缀后的同一名称。
    var fileDestination: String { platform == .android ? settings.androidFileDestination : settings.fileDestination } // 拖放使用本窗口对应的真实手机路径。

    @Published var connected = false
    @Published var busy = false
    @Published private(set) var connectionPreview: CGImage? // 柔焦显影只使用内存中的本设备画面。
    @Published private(set) var hasVideoFrame = false // 首个有效关键帧提交渲染后才移除连接遮罩。
    @Published private(set) var hasVideoFormat = false // 首个 SPS 已给出视频方向，此时可确定窗口外框。
    @Published private(set) var reconnectPending = false // 等待自动重试时保持连接画面。
    @Published private(set) var connectionStage: ConnectionStage = .checkingDevice // 使用真实启动阶段。
    @Published var status = "未连接"
    @Published var physicalSize = CGSize(width: 1080, height: 2340)
    @Published var videoSize = CGSize(width: 1080, height: 2340)
    @Published var framesPerSecond = 0
    @Published var isRecording = false
    @Published var isAlwaysOnTop = false // 标题栏和窗口层级只观察本设备的状态。
    @Published var deviceModel = ""
    @Published private(set) var customName: String? // 只有会话存储能够同步已经保存的设备名称。
    @Published var logLines: [String] = []

    lazy var renderer = VideoRenderer() // 只在鸿蒙原生窗口中创建；Android 由 scrcpy 自己显示。
    let fileDrops: FileDropController // 文件传输拥有独立串行队列，不占用触控和视频控制线程。
    private(set) var settings: MirrorSettings
    private(set) var session: DeviceSession?

    private var recorder: Recorder?
    private var frameCounter = 0
    private var wheelDrag = ScrollWheelDrag()
    private var pendingWheelPixels = 0.0 // 控制通道忙时，只保留尚未发送的累计位移。
    private var wheelPoint = CGPoint(x: 0.5, y: 0.5) // 保留最新指针下的滚动容器位置。
    private var wheelInFlight = false
    private var wheelEndTask: Task<Void, Never>?
    private var wheelEnding = false
    private var fpsTimer: Timer?
    private var reconnectPolicy = ReconnectPolicy() // 连续失败预算跨短命连接保留。
    private var userDisconnected = false
    private var loggedFirstFrame = false
    private var pendingText = "" // 仅当前一次发送还在进行时合并后续字符。
    private var textRequests = 0
    private let worker = SessionWorker<DeviceSession>() // 一台设备的全部阻塞 I/O 都在这里串行执行。
    private var desktopClient: ScrcpyDesktopProcess? // 只拥有该 Android 设备的官方客户端进程。
    private let systemActions = DispatchQueue(label: "com.hosmirror.device-system-actions", qos: .userInitiated) // 不同设备可并行，同一设备保持顺序。
    private var wakeWhenConnected = false // 用户开启鸿蒙投屏后，在首次成功连接时唤醒。
    private var androidPinRestart: UUID? // 区分置顶重启和用户在重启期间主动断开。
    var isRestartingForWindowPin: Bool { androidPinRestart != nil }
    private var attempt = ConnectionAttempt() // 每次连接都换新凭据，使旧回调失效。
    private var nativeSize = CGSize(width: 1080, height: 2340) // 保存未受视频缩放影响的面板尺寸。
    private let onModel: (String) -> Void // 把新读取的默认型号交给设备存储。
    var initialWindowPin: (() -> Bool)? // 每次主动连接读取最新的全局和设备偏好。
    private var connectionStartedAt: ContinuousClock.Instant? // 记录单次启动的真实首帧耗时。

    init(serial: String, settings: MirrorSettings, platform: DevicePlatform = .harmony, model: String = "", customName: String? = nil, onModel: @escaping (String) -> Void = { _ in }) {
        self.serial = serial
        self.platform = platform // 设备身份在窗口整个生命周期内保持不变。
        self.deviceModel = model // Android 枚举提供的名称无需等待出图。
        self.customName = customName // 窗口创建前即载入本设备的自定义名称。
        self.onModel = onModel // 同一设备的探测结果随 App 重启保留。
        self.settings = settings
        fileDrops = FileDropController(serial: serial, hdc: Hdc(binary: AppResources.hdcBinary), platform: platform) // 每台设备独立任务与结果。
        guard platform == .harmony else { return } // Android 不安装自研视频或输入管线。
        renderer.onSize = { [weak self] size in
            guard let self, size.width > 0 else { return }
            self.interruptScrolling() // 旋转后旧坐标不能继续作为拖动起点。
            self.videoSize = size
            self.physicalSize = ScreenGeometry.orientedSize(native: self.nativeSize, video: size) // 旋转时同步触控宽高。
            self.hasVideoFormat = true
            let physical = self.physicalSize // 捕获值，避免工作线程读取主线程状态。
            self.worker.perform(attempt: self.attempt) { $0.updateSize(physical) } // 自检也使用当前方向。
        }
        renderer.onFirstFrame = { [weak self] in
            guard let self, self.connected else { return } // 已取消会话不能提前结束新连接画面。
            self.connectionPreview = self.renderer.currentSnapshot // 先发布可模糊的真实帧，再触发显影动画。
            self.hasVideoFrame = true // 以显示图层真正就绪为准，而非收到编码包就结束加载。
            if let started = self.connectionStartedAt {
                let elapsed = started.duration(to: .now).components // 用单调时钟计时，避免系统时间变化影响。
                let milliseconds = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
                self.log("首帧就绪：\(milliseconds) ms") // 记录点击连接到有效画面，便于同设备对照。
            }
            self.reconnectPolicy.videoDisplayed() // 真实首帧是连接恢复的必要条件。
        }
        renderer.onSampleBuffer = { [weak self] sample in
            self?.recorder?.append(sample)
        }
        renderer.onKeyFrameNeeded = { [weak self] in
            guard let self, self.connected else { return }
            self.worker.perform(attempt: self.attempt) { $0.requestKeyFrame() } // 连接结束时丢弃排队的请求。
        }
    }

    func update(settings: MirrorSettings) {
        self.settings = settings
    }

    func updateCustomName(_ value: String?) {
        customName = value // 发布修改或清除，让已打开窗口立即更新。
    }

    // MARK: - Lifecycle

    func connect(retrying: Bool = false, wakeAndroidOnStart: Bool = true) {
        guard !busy, !connected, desktopClient == nil else { return } // 等前一个 Android 实例清理完毕再启动。
        if !retrying {
            reconnectPolicy = ReconnectPolicy() // 用户主动连接才立即重置失败预算。
            wakeWhenConnected = platform == .harmony
            if androidPinRestart == nil, let initialWindowPin {
                isAlwaysOnTop = initialWindowPin() // 自动重连和 Android 应用本次手动置顶时保留当前状态。
            }
        }
        attempt.cancel() // 取消旧的延迟重连、输入和帧回调。
        let attempt = ConnectionAttempt() // 这次连接拥有独立的生命周期凭据。
        self.attempt = attempt
        connectionStartedAt = .now // 自动重试独立计时。
        busy = true
        resetScrolling() // 新连接不能继承上一会话的惯性尾数或排队步进。
        hasVideoFrame = false // 每次新连接都需要等待新会话的首帧。
        hasVideoFormat = false
        reconnectPending = false
        connectionStage = .checkingDevice
        userDisconnected = false
        status = "正在连接 \(serial)…"
        let settings = self.settings // 固定本次启动参数，避免途中修改设置产生混合配置。
        let quality = platform == .android ? "scrcpy 默认画质" : settings.summary
        log("连接 \(serial)（\(quality)）")
        let serial = self.serial
        if platform == .android {
            connectAndroid(attempt: attempt, wakeOnStart: wakeAndroidOnStart) // Android 的传输目录在实际拖入时读取。
            return // 不进入自研会话、解码或渲染。
        }
        worker.start(attempt: attempt, create: { [weak self] in
            let updateProgress: (ConnectionStage) -> Void = { stage in // 两个后端共用真实进度和取消边界。
                Task { @MainActor [weak self] in
                    guard let self, self.attempt === attempt, !attempt.isCancelled else { return } // 旧连接不能污染新窗口。
                    self.connectionStage = stage // 不伪造百分比。
                }
            }
            let hdc = Hdc(binary: AppResources.hdcBinary) // 现有鸿蒙传输不变。
            let bootstrapper = DeviceBootstrapper(hdc: hdc, resources: AppResources.harmonyRoot, log: { line in
                Task { @MainActor [weak self] in if !attempt.isCancelled { self?.log(line) } } // 日志不阻塞设备工作队列。
            }, progress: updateProgress, onIdentity: { identity in
                Task { @MainActor [weak self] in
                    guard let self, self.attempt === attempt, !attempt.isCancelled else { return } // 取消或旧会话不再修改名称。
                    self.deviceModel = identity.displayName // 复用完整启动探测，提前显示型号。
                    self.onModel(identity.displayName)
                }
            })
            let started = try bootstrapper.bootstrap(serial: serial, frameRate: settings.frameRate, bitRateMbps: settings.bitRateMbps, scale: settings.scale, attempt: attempt) // 鸿蒙使用设置中的固定参数。
            let session = DeviceSession(try MirrorSession(hdc: hdc, started: started)) // 继续使用鸿蒙原有渲染链路。
            session.onFrame = { [weak self] frame in
                DispatchQueue.main.async { [weak self] in // 按单一视频读取线程的提交顺序处理参数集和画面。
                    guard let self, self.attempt === attempt, !attempt.isCancelled else { return }
                    self.renderer.consume(frame) // 渲染状态和录制入口统一由主线程访问。
                    self.frameCounter += 1
                }
            }
            session.onError = { [weak self] message in
                Task { @MainActor [weak self] in
                    guard let self, self.attempt === attempt, !attempt.isCancelled else { return }
                    self.log("视频流: \(message)")
                    self.handleStreamEnd(message: message) // 旧连接的结束事件不能中断新连接。
                }
            }
            return session // 工作队列接管所有权，取消时也在同一队列内停止。
        }, completion: { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.attempt === attempt, !attempt.isCancelled else { return }
                self.busy = false
                switch result {
                case .success(let session):
                    self.session = session
                    self.nativeSize = session.deviceSize
                    self.physicalSize = session.deviceSize
                    self.videoSize = session.deviceSize // 等首个 SPS 到来后再按实际视频方向调整。
                    self.deviceModel = session.model
                    self.onModel(session.model) // 记住最终默认型号，别名优先级保持独立。
                    self.connectionStage = .waitingForFrame // 通道完成后继续等待实际视频。
                    self.connected = true
                    self.reconnectPolicy.connectionOpened(at: Date()) // Socket 建立成功不能清除连续断流次数。
                    self.status = "已连接"
                    self.log("已连接 \(serial)（\(session.model) / \(session.modelCode) · \(session.effectiveFPS) fps · \(session.effectiveBitrate) Mbps · \(Int(session.effectiveScale * 100))%）")
                    self.startFPSTimer()
                    self.worker.perform(attempt: attempt) { $0.start() } // 接管状态后才接收帧和结束事件。
                    if self.wakeWhenConnected {
                        self.wakeWhenConnected = false // 后续自动重连不重复亮屏。
                        self.enqueueSystemAction(.wake) { _ in } // 后台唤醒与视频送显并行。
                    }
                    if ProcessInfo.processInfo.environment["HOSMIRROR_SELFTEST"] == "1" {
                        self.worker.perform(attempt: attempt) { [weak self] session in
                            let passed = session.verifyControl() // 自检不再阻塞主线程。
                            Task { @MainActor [weak self] in
                                guard !attempt.isCancelled else { return }
                                self?.log("控制通道自检：\(passed ? "通过" : "失败")")
                            }
                        }
                    }
                    if ProcessInfo.processInfo.environment["HOSMIRROR_SELFTEST_RECORD"] == "1" {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                            guard !attempt.isCancelled else { return }
                            self?.startRecording()
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                            guard !attempt.isCancelled else { return }
                            self?.finishRecording()
                        }
                    }
                case .failure(let error):
                    self.connected = false
                    self.status = "连接失败"
                    self.log("失败: \(error.localizedDescription)")
                    self.scheduleReconnect(message: error.localizedDescription)
                }
            }
        })
    }

    func bringAndroidWindowToFront() {
        desktopClient?.bringToFront() // 重复打开时激活当前设备的进程。
    }

    var hasPendingOrOpenConnection: Bool {
        connected || busy || reconnectPending || desktopClient != nil // 跳过正在关闭的 Android 实例，避免重复启动。
    }

    var isActivelyMirroring: Bool {
        guard connected, hasVideoFrame, !attempt.isCancelled else { return false } // 排除纯调试连接、启动中和重连中。
        switch platform {
        case .harmony: return MirrorWindowManager.shared.hasOpenWindow(for: self)
        case .android: return desktopClient?.hasOpenWindow == true
        }
    }

    func performSystemAction(_ action: DeviceSystemAction, requiresMirror: Bool = true,
                             followMac: Bool = false, completion: @escaping (Error?) -> Void) {
        let mirroring = isActivelyMirroring
        guard mirroring || !requiresMirror else { completion(HdcError("投屏窗口已关闭")); return }
        // 单台设备可直接使用已经授权的调试连接，未投屏时使用独立的命令凭据。
        enqueueSystemAction(action, attempt: mirroring ? attempt : ConnectionAttempt(), followMac: followMac, completion: completion)
    }

    private func enqueueSystemAction(_ action: DeviceSystemAction, attempt: ConnectionAttempt? = nil,
                                     followMac: Bool = false,
                                     completion: @escaping (Error?) -> Void) {
        let attempt = attempt ?? self.attempt // 排队时关闭或重连会取消旧会话的请求。
        let platform = self.platform
        let serial = self.serial
        let hdc = Hdc(binary: AppResources.hdcBinary)
        let adb = Adb(directory: AndroidRuntime.directory)
        systemActions.async { [weak self] in
            let result = Result { try action.run(on: platform, serial: serial, hdc: hdc, adb: adb, attempt: attempt, followMac: followMac) }
            DispatchQueue.main.async { [weak self] in
                switch result {
                case .success: completion(nil)
                case .failure(let error):
                    self?.log("\(action.title)失败：\(error.localizedDescription)")
                    completion(error)
                }
            }
        }
    }

    private func connectAndroid(attempt: ConnectionAttempt, wakeOnStart: Bool) {
        let directory = AndroidRuntime.directory // 不依赖系统 PATH。
        let serial = serial // 后台只接收不可变参数。
        let visible = NSScreen.screens.first?.visibleFrame.size // 与 scrcpy 默认启动的主屏一致。
        let chrome = NSWindow.frameRect(forContentRect: .zero, styleMask: [.titled]).height // 标题栏不计入视频可用高度。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let adb = Adb(directory: directory)
            let panel = try? adb.screenSize(serial: serial, attempt: attempt, timeout: 2) // 失败不妨碍官方客户端正常启动。
            let rotation = panel != nil ? adb.displayRotation(serial: serial, attempt: attempt) : nil
            let productName = adb.productDisplayName(serial: serial, attempt: attempt)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.attempt === attempt, !attempt.isCancelled else { return } // 已取消时不再启动程序。
                if let productName, productName != self.deviceModel {
                    self.deviceModel = productName
                    self.onModel(productName) // 更新设备记录，后台枚举不会用型号代码覆盖产品名。
                }
                var arguments = AndroidRuntime.arguments(serial: serial, title: self.windowTitle,
                                                         fps: nil, bitrate: nil, maxSize: nil, onTop: self.isAlwaysOnTop)
                if let panel, let rotation, let visible {
                    let oriented = rotation.isMultiple(of: 2) ? panel : CGSize(width: panel.height, height: panel.width)
                    let fit = MirrorWindowGeometry.maximumContent(device: oriented, visible: visible, chromeHeight: chrome)
                    // 只设置限制尺寸的一边，由 scrcpy 用实际首帧比例算另一边。
                    if fit.height >= visible.height - chrome - 1 {
                        arguments.append("--window-height=\(max(1, Int(fit.height.rounded(.down))))")
                    } else {
                        arguments.append("--window-width=\(max(1, Int(fit.width.rounded(.down))))")
                    }
                }
                arguments += ["--no-terminal-title", "--no-audio", "--no-clipboard-autosync"] // 保留 App 原有的音频和剪贴板选择。
                if !wakeOnStart { arguments.append("--no-power-on") } // 应用窗口置顶时保留手机的亮灭屏状态。
                let target = self.fileDestination // 旧版客户端或消息端口不可用时，仍给原生拖放传入正确目录。
                arguments.append("--push-target=\(target.hasSuffix("/") ? target : target + "/")")
                self.startAndroidProcess(directory: directory, arguments: arguments, attempt: attempt)
            }
        }
    }

    private func startAndroidProcess(directory: URL, arguments: [String], attempt: ConnectionAttempt) {
        let client = ScrcpyDesktopProcess()
        desktopClient = client
        connectionStage = .waitingForFrame
        client.onDrop = { [weak self] urls in
            guard let self, self.attempt === attempt, !attempt.isCancelled else { return } // 已关闭或替换的会话不能提交拖放。
            self.fileDrops.enqueue(urls, directory: self.fileDestination, connected: true) // 子进程的已显示投屏窗口确认了这次拖放，目录按拖入时的设置读取。
        }
        client.onVideo = { [weak self] in
            guard let self, self.attempt === attempt, !attempt.isCancelled else { return }
            self.androidPinRestart = nil
            self.reconnectPolicy.connectionOpened(at: .now)
            self.reconnectPolicy.videoDisplayed() // 只有官方客户端收到实际视频才显示“投屏中”。
            self.hasVideoFrame = true
            self.connected = true
            self.busy = false
            self.status = "已连接"
        }
        client.onExit = { [weak self] code, diagnostic in
            guard let self else { return }
            self.fileDrops.cancelAll() // 在 scrcpy 中关窗或断流，也取消该设备还在执行的任务。
            self.desktopClient = nil // 即使是手动停止也释放已结束的实例。
            guard self.attempt === attempt, !attempt.isCancelled else { return }
            self.androidPinRestart = nil
            self.busy = false
            self.connected = false
            self.hasVideoFrame = false
            self.status = code == 0 ? "已断开" : "连接中断"
            if code != 0 { // 从原生窗口正常退出不被当作断流，也不会再弹出来。
                if let diagnostic { self.log(diagnostic) }
                self.scheduleReconnect(message: diagnostic ?? "scrcpy 连接中断")
            }
        }
        do { try client.start(directory: directory, arguments: arguments, windowID: id, displayName: mirrorName, transfers: fileDrops) } // 投屏进程只接收该设备的传输状态。
        catch {
            desktopClient = nil
            androidPinRestart = nil
            busy = false
            status = "无法启动内置 scrcpy"
            log(error.localizedDescription)
        }
    }

    func disconnect(completion: (() -> Void)? = nil) {
        fileDrops.cancelAll() // 主动断开或关闭设备窗口时停止尚未完成的发送/安装。
        androidPinRestart = nil
        userDisconnected = true
        wakeWhenConnected = false
        reconnectPending = false // 取消不能继续展示自动重连动画。
        connectionStartedAt = nil // 用户取消后没有可报告的首帧。
        attempt.cancel() // 立即使后台启动和已投递回调失效。
        clearSession(completion: completion) // 真正的阻塞清理由工作队列完成。
        busy = false
        status = "已断开"
        connectionPreview = nil // 主动断开后清除屏幕预览，不在会话外保留私密画面。
        if platform == .harmony { MirrorWindowManager.shared.closeWindow(for: self) }
    }

    func applyWindowPinChange() {
        guard platform == .android, let client = desktopClient, client.hasOpenWindow else { return }
        fileDrops.cancelAll() // 置顶重启会关闭旧窗口，旧窗口的队列也随之停止。
        let restart = UUID()
        androidPinRestart = restart
        attempt.cancel() // 旧客户端正常停止后，由这里发起一次带新置顶选项的连接。
        connected = false
        hasVideoFrame = false
        busy = true
        status = "正在应用窗口置顶…"
        client.stop { [weak self] in
            guard let self, self.androidPinRestart == restart else { return }
            self.busy = false
            self.connect(wakeAndroidOnStart: false)
        }
    }

    private func clearSession(completion: (() -> Void)? = nil) {
        if platform == .android {
            connected = false
            hasVideoFrame = false
            if let desktopClient { desktopClient.stop(completion: completion) }
            else { completion?() } // 在尺寸探测阶段取消时还没有客户端进程。
            return
        }
        finishRecording() // 断流时也要完整结束当前 MP4。
        resetScrolling() // 断线后不再继续派发旧的滚轮操作。
        textRequests = 0
        pendingText = "" // 未派发的输入不能跨连接或发送到下一个设备焦点。
        connectionPreview = renderer.captureCurrentFrame() ?? connectionPreview // 自动重连时可以模糊最近的可取画面。
        worker.stop(completion: completion) // 此操作排在下一次 bootstrap 前，不会误杀新守护进程。
        session = nil
        connected = false
        hasVideoFrame = false // 不复用断线前已经出现过画面的状态。
        hasVideoFormat = false
        fpsTimer?.invalidate()
        fpsTimer = nil
        frameCounter = 0
        framesPerSecond = 0
        loggedFirstFrame = false
        renderer.reset() // 渲染操作与 consume 现在都在主线程。
    }

    private func handleStreamEnd(message: String) {
        attempt.cancel() // 相同连接重复发送的结束事件只能处理一次。
        clearSession()
        status = "连接中断"
        scheduleReconnect(message: "视频流结束（\(message)）")
    }

    private func scheduleReconnect(message: String) {
        guard settings.autoReconnect, !userDisconnected else { return }
        guard let delay = reconnectPolicy.nextDelay(at: Date()) else {
            reconnectPending = false // 达到上限后留在断开页，允许用户手动重连。
            status = "连接连续失败，请手动重连"
            log("已停止自动重连：连续五次重试未能稳定出图")
            return
        }
        reconnectPending = true // 重试等待期间也显示明确的连接状态。
        let scheduledAttempt = attempt // 后续手动连接会替换凭据并使这个定时器失效。
        status = "\(message)，\(delay) 秒后重连…"
        log("自动重连 \(reconnectPolicy.attempts)/5：\(message)，等待 \(delay) 秒") // 日志区分真实断流重试与用户主动连接。
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.attempt === scheduledAttempt,
                  !self.userDisconnected, !self.connected, !self.busy else { return }
            self.connect(retrying: true) // 保留本轮失败次数，不再因短暂接通而无限重试。
        }
    }

    // MARK: - Input

    func touch(_ phase: TouchPhase, at normalized: CGPoint) {
        guard connected else { return }
        if case .down = phase {
            flushTypedText() // 点击切换手机焦点前，先发送原输入框的文字。
            interruptScrolling() // 先结束滚轮触摸，再发送真实鼠标按下。
        }
        let x = ScreenGeometry.pixel(normalized.x, extent: physicalSize.width) // 边缘坐标不会超出物理屏幕。
        let y = ScreenGeometry.pixel(normalized.y, extent: physicalSize.height)
        worker.perform(attempt: attempt) { $0.touch(phase, x: x, y: y) } // 控制通道等待离开主线程。
    }

    func scroll(_ input: ScrollWheelInput, at normalized: CGPoint) {
        guard connected, hasVideoFrame, input.delta.isFinite else { return }
        guard input.delta != 0 || input.endsGesture || input.startsGesture else { return } // 横向滚轮不能取消待发的抬起。
        if input.startsGesture { interruptScrolling() }
        wheelEndTask?.cancel()
        wheelEndTask = nil
        wheelEnding = input.endsGesture
        wheelPoint = normalized
        let points = input.precise ? input.delta : input.delta * 24 // 鼠标格数与触控板的点数分别换算。
        let pixels = points * physicalSize.height / max(1, input.viewportHeight)
        let limit = physicalSize.height / 5
        if pendingWheelPixels * pixels < 0 { pendingWheelPixels = 0 } // 转向时优先响应新的方向。
        pendingWheelPixels = max(-limit, min(limit, pendingWheelPixels + pixels))
        flushScrolling()
        guard !input.endsGesture, input.delta != 0 else { return }
        wheelEndTask = Task { @MainActor [weak self] in
            // 鼠标没有抬手事件；触控板异常丢失 phase 时也能释放触摸。
            try? await Task.sleep(for: .milliseconds(input.precise ? 220 : 85))
            guard !Task.isCancelled, let self else { return }
            self.wheelEndTask = nil
            self.wheelEnding = true
            self.flushScrolling()
        }
    }

    private func flushScrolling() {
        guard !wheelInFlight, connected else { return }
        var events = wheelDrag.move(by: pendingWheelPixels, at: wheelPoint, in: physicalSize)
        pendingWheelPixels = 0
        if wheelEnding {
            if let up = wheelDrag.end() { events.append(up) }
            wheelEnding = false
        }
        guard !events.isEmpty else { return }
        let attempt = self.attempt // 结果只能影响发出这次请求的会话。
        wheelInFlight = true
        worker.perform(attempt: attempt) { [weak self] session in
            for event in events { session.touch(event.phase, x: event.x, y: event.y) }
            Task { @MainActor [weak self] in
                guard let self, self.attempt === attempt, !attempt.isCancelled else { return }
                self.wheelInFlight = false
                self.flushScrolling()
            }
        }
    }

    private func interruptScrolling() {
        wheelEndTask?.cancel()
        wheelEndTask = nil
        pendingWheelPixels = 0
        wheelEnding = false
        if let up = wheelDrag.end() {
            worker.perform(attempt: attempt) { $0.touch(up.phase, x: up.x, y: up.y) }
        }
    }

    private func resetScrolling() {
        interruptScrolling() // 会话清理也会抬起尚未送达的设备触摸。
        wheelInFlight = false // 旧结果会被连接凭据拦截，不会修改新批次状态。
    }

    func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags) {
        guard connected else { return }
        if modifiers.contains(.command) {
            switch code {
            case 123: press(KeyMap.back); return
            case 126: press(KeyMap.home); return
            default: break
            }
        }
        if let keyCode = KeyMap.hardware(code) {
            press(keyCode)
        }
    }

    func sendText(_ text: String) {
        flushTypedText() // 文字面板发送前保留已经键入的顺序。
        enqueueText(text)
    }

    func typeText(_ text: String) {
        guard connected, hasVideoFrame, !text.isEmpty else { return }
        pendingText += text
        if textRequests == 0 { flushTypedText() } // 第一个字立即发，无需等批处理计时。
    }

    private func flushTypedText() {
        let text = pendingText
        pendingText = ""
        enqueueText(text)
    }

    private func enqueueText(_ text: String) {
        guard connected, !text.isEmpty else { return }
        let attempt = self.attempt
        textRequests += 1
        worker.perform(attempt: attempt) { [weak self] session in
            let sent = (try? session.sendText(text, x: 0, y: 0)) != nil
            Task { @MainActor [weak self] in
                guard let self, self.attempt === attempt, !attempt.isCancelled else { return }
                self.textRequests -= 1
                if !sent { self.log("发送文字失败，请确认手机输入框已获得焦点") }
                if self.textRequests == 0 { self.flushTypedText() }
            }
        }
    }

    func rotate() {
        interruptScrolling()
        let horizontal = videoSize.width < videoSize.height // 每次按钮切换方向，而非始终请求横屏。
        worker.perform(attempt: attempt) { $0.rotate(horizontal: horizontal) }
    }

    func rightClick() {
        guard connected || busy else { return } // 连接过程尚未出图时也允许把唤醒请求排在启动之后。
        flushTypedText()
        interruptScrolling()
        let attempt = self.attempt
        worker.perform(attempt: attempt) { [weak self] session in
            do { try session.backOrWake() } // 与其他设备 I/O 共用串行队列，主线程不等待查询。
            catch {
                Task { @MainActor [weak self] in
                    guard !attempt.isCancelled else { return }
                    self?.log("返回 / 唤醒失败：\(error.localizedDescription)")
                }
            }
        }
    }

    func press(_ code: UInt32) {
        flushTypedText() // 删除、回车、返回等必须排在先前输入的字符之后。
        interruptScrolling()
        worker.perform(attempt: attempt) { $0.pressKey(code) }
    }

    func screenshot() {
        guard connected else { return }
        let directory = picturesDirectory
        let target = directory.appendingPathComponent("shot-\(UUID().uuidString).jpeg") // 多设备同时截图也不会覆盖文件。
        let attempt = self.attempt
        worker.perform(attempt: attempt) { [weak self] session in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try session.screenshot(to: target) // 文件传输不在 UI 线程等待。
                Task { @MainActor [weak self] in self?.log("截图已保存 \(target.path)") }
            } catch {
                Task { @MainActor [weak self] in self?.log("截图失败: \(error.localizedDescription)") }
            }
        }
    }

    // MARK: - Clipboard

    func pasteFromMac() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            log("电脑剪贴板为空")
            return
        }
        sendText(text)
    }

    func copyToMac() {
        guard connected else { return }
        let attempt = self.attempt
        worker.perform(attempt: attempt) { [weak self] session in
            let text = session.deviceClipboardText() // 设备命令在工作队列执行。
            Task { @MainActor [weak self] in
                guard !attempt.isCancelled else { return }
                if let text {
                    NSPasteboard.general.clearContents() // 系统剪贴板仅在主线程访问。
                    NSPasteboard.general.setString(text, forType: .string)
                    self?.log("已复制设备剪贴板（\(text.count) 字符）")
                } else {
                    self?.log("读取设备剪贴板失败，请确认设备权限与连接状态")
                }
            }
        }
    }

    // MARK: - Output locations

    private var picturesDirectory: URL {
        if let root = ProcessInfo.processInfo.environment["HOSMIRROR_OUTPUT_DIR"] {
            return URL(fileURLWithPath: root).appendingPathComponent("Pictures")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/HosMirror")
    }

    private var moviesDirectory: URL {
        if let root = ProcessInfo.processInfo.environment["HOSMIRROR_OUTPUT_DIR"] {
            return URL(fileURLWithPath: root).appendingPathComponent("Movies")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/HosMirror")
    }

    // MARK: - Recording

    func toggleRecording() {
        if isRecording {
            finishRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard let description = renderer.formatDescription else {
            log("还没有收到关键帧，无法录制")
            return
        }
        let directory = moviesDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("rec-\(Int(Date().timeIntervalSince1970)).mp4")
        do {
            let recorder = try Recorder(url: url, format: description)
            self.recorder = recorder
            isRecording = true
            log("开始录制 \(url.lastPathComponent)")
        } catch {
            log("开始录制失败: \(error.localizedDescription)")
        }
    }

    private func finishRecording() {
        guard let recorder else { return }
        recorder.finish()
        self.recorder = nil
        isRecording = false
        log("录制已保存")
    }

    // MARK: - Helpers

    private func startFPSTimer() {
        fpsTimer?.invalidate()
        let attempt = self.attempt // 已投递的旧计时任务不能影响新会话统计。
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.attempt === attempt, !attempt.isCancelled else { return }
                self.framesPerSecond = self.frameCounter
                self.frameCounter = 0
                // 采集端在静止画面时不推帧，不能用稀疏帧率推断链路差并重启会话。
                if self.framesPerSecond > 0, !self.loggedFirstFrame {
                    self.loggedFirstFrame = true
                    self.log("视频流已出图")
                }
                if ProcessInfo.processInfo.environment["HOSMIRROR_DEBUG"] == "1", self.framesPerSecond > 0 {
                    self.log("fps \(self.framesPerSecond)")
                }
            }
        }
    }

    func log(_ line: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let entry = "[\(formatter.string(from: Date()))] \(line)"
        logLines.append(entry)
        if logLines.count > 300 { logLines.removeFirst(logLines.count - 300) }
        if ProcessInfo.processInfo.environment["HOSMIRROR_DEBUG"] == "1" {
            FileHandle.standardError.write(Data((entry + "\n").utf8))
        }
    }
}
