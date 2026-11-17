import Foundation // 自有 Swift 客户端连接未修改的官方 scrcpy-server。
import CoreGraphics // 与鸿蒙共用物理坐标模型。
import ImageIO // 将 Android 原始截图保存为共用的 JPEG 格式。
import Darwin // 只回收当前会话拥有的 ADB 客户端进程。

public final class AndroidMirrorSession: DeviceSessionBackend {
    public let serial: String // 一台设备独立持有自己的转发与 server。
    public let model: String // 服务端返回的实际设备名。
    public let modelCode: String // 保留枚举时型号供诊断。
    public let effectiveFPS: Int // 与连接设置一致。
    public let effectiveBitrate: Int // 与自动或手动画质一致。
    public let effectiveScale: Double // 当前编码缩放比例。
    public var onFrame: ((VideoPacket) -> Void)? // 交付 Annex-B 视频与设备的原始时间信息。
    public var onError: ((String) -> Void)? // 断流共用五次恢复预算。
    private let adb: Adb // 只使用随包工具。
    private let video: AndroidSocket // 每台设备独享视频流。
    private let control: AndroidSocket // 每台设备独享控制流。
    private let server: Process // 唯一由本会话启动的 ADB shell。
    private let serverLog: AndroidServerLog // 限量保存启动错误，不落盘。
    private let port: UInt16 // 只删除自身分配的转发。
    private let remote: String // 只删除自身上传的临时 jar。
    private let attempt: ConnectionAttempt // 与统一控制器共享取消，关窗立即解除后台等待。
    private let state = NSCondition() // 同步视频尺寸、停止标记与剪贴板回应。
    private var physical: CGSize // 当前屏幕方向的物理坐标范围。
    private var encoded: CGSize // scrcpy 控制协议要求的编码尺寸。
    private var started = false // start() 只创建一组接收线程。
    private var stopped = false // 清理与错误回调均幂等。
    private var clipboard: String? // 仅在用户复制时临时保存设备文本。
    private var clipboardGeneration = 0 // 区分旧缓存和本次请求的真实回应。
    public var deviceSize: CGSize { state.lock(); defer { state.unlock() }; return physical } // 主线程读取一致尺寸。

    private init(serial: String, model: String, code: String, fps: Int, bitrate: Int, scale: Double, physical: CGSize, encoded: CGSize, adb: Adb, video: AndroidSocket, control: AndroidSocket, server: Process, log: AndroidServerLog, port: UInt16, remote: String, attempt: ConnectionAttempt) { // 全部资源建立成功后才移交所有权。
        self.serial = serial; self.model = model; modelCode = code // 设备身份不会被后续刷新替换。
        effectiveFPS = fps; effectiveBitrate = bitrate; effectiveScale = scale // 保存实际启动配置。
        self.physical = physical; self.encoded = encoded; self.adb = adb // 坐标模型与工具均绑定设备。
        self.video = video; self.control = control; self.server = server; serverLog = log // 绑定自有连接和进程。
        self.port = port; self.remote = remote; self.attempt = attempt // 清理限定到当前资源和当前连接。
    }

    public static func open(device: AndroidDevice, directory: URL = AndroidRuntime.directory, frameRate: Int, bitrate: Int, scale: Double, autoQuality: Bool, attempt: ConnectionAttempt, progress: @escaping (ConnectionStage) -> Void) throws -> AndroidMirrorSession { // 由 DeviceController 工作队列调用。
        let adb = Adb(directory: directory) // 不创建桌面 scrcpy 窗口。
        progress(.checkingDevice) // 与鸿蒙相同的真实启动阶段。
        try attempt.checkCancellation() // 用户关窗后不探测手机。
        guard try adb.devices(attempt: attempt).contains(where: { $0.serial == device.serial && $0.canConnect }) else { throw HdcError("设备未连接或尚未允许调试，请确认手机授权") } // 不使用陈旧枚举状态。
        let native = try adb.screenSize(serial: device.serial, attempt: attempt) // 从实际屏幕尺寸计算画质和初始方向。
        let fps = autoQuality ? 60 : frameRate // 统一自动模式的上限。
        let bits = autoQuality ? (native.width * native.height >= 2_000_000 ? 16 : 8) : bitrate // Android 自动模式按设备像素数选启动码率。
        let ratio = autoQuality ? (device.serial.contains(":") ? 0.75 : 1) : scale // 无线默认降低分辨率，连接期间不改档。
        let maximum = max(8, Int(max(native.width, native.height) * ratio) / 8 * 8) // scrcpy max_size 采用八的倍数。
        let id = String(format: "%08x", UInt32.random(in: 1...0x7fffffff)) // 官方 scid 允许的非负三十一位范围。
        let remote = "/data/local/tmp/hosmirror-\(id).jar" // 临时文件名不与其他 scrcpy 客户端冲突。
        var allocated: UInt16?; var process: Process?; var video: AndroidSocket?; var control: AndroidSocket? // 工厂负责部分失败回滚。
        var completed = false // 只有成功创建完整对象后才能免除回滚。
        defer { // 取消、握手失败和型号读取失败走同一清理。
            if !completed {
                video?.close(); control?.close() // 先切断当前设备端会话。
                if let process, process.isRunning { process.terminate() } // 不按名称终止其他进程。
                if let allocated { _ = try? adb.run(["-s", device.serial, "forward", "--remove", "tcp:\(allocated)"], timeout: 5) } // 只删除自身转发。
                _ = try? adb.run(["-s", device.serial, "shell", "rm -f \(FileDelivery.quote(remote))"], timeout: 5) // 只删除自身临时 jar。
            }
        }
        progress(.preparingDevice) // 对应真实 server 推送。
        try adb.run(["-s", device.serial, "push", directory.appendingPathComponent("scrcpy-server").path, remote], timeout: 120, attempt: attempt) // 不要求用户额外安装 Android App。
        try attempt.checkCancellation() // 取消后不再申请新转发。
        let output = try adb.run(["-s", device.serial, "forward", "tcp:0", "localabstract:scrcpy_\(id)"], timeout: 5) // 原子分配后必须先拿到端口，避免取消导致转发已创建却无法清理。
        guard let portText = output.split(whereSeparator: \.isWhitespace).last, let port = UInt16(portText), port > 0 else { throw HdcError("ADB 未返回有效的转发端口：\(output)") } // 不能猜测或复用其他连接端口。
        allocated = port // 此后失败必须删除此转发。
        try attempt.checkCancellation() // 即使分配期间被取消，也能通过已知端口回滚。
        let log = AndroidServerLog() // 服务端错误只在启动失败时展示。
        let server = Process() // 保持 shell 连接直到当前会话结束。
        let pipe = Pipe() // 持续排空诊断，避免采集端因输出阻塞。
        server.executableURL = adb.binary // 启动固定内置 ADB。
        let options = "scid=\(id) tunnel_forward=true video_codec=h264 audio=false control=true clipboard_autosync=false max_size=\(maximum) max_fps=\(fps) video_bit_rate=\(bits * 1_000_000) send_device_meta=true send_stream_meta=true send_frame_meta=true send_dummy_byte=true" // scrcpy 5.0.1 的真实选项名。
        server.arguments = ["-s", device.serial, "shell", "CLASSPATH=\(FileDelivery.quote(remote)) app_process / com.genymobile.scrcpy.Server 5.0.1 \(options)"] // 固定命令中的动态路径严格转义。
        server.standardInput = FileHandle.nullDevice; server.standardOutput = pipe; server.standardError = pipe // 不等待不存在的交互终端。
        pipe.fileHandleForReading.readabilityHandler = { handle in let bytes = handle.availableData; if bytes.isEmpty { handle.readabilityHandler = nil } else { log.append(bytes) } } // 诊断始终有界。
        do { try server.run() } catch { pipe.fileHandleForReading.readabilityHandler = nil; throw error } // 启动失败不留下读取回调。
        process = server // 工厂在完整移交前拥有终止权。
        progress(.connectingVideo) // 连接画面使用同一个阶段模型。
        let deadline = Date().addingTimeInterval(15) // 初始化握手有上限，但静止画面不设断流时限。
        while video == nil && Date() < deadline { // ADB 端口存在不代表设备端已监听。
            try attempt.checkCancellation() // 取消可以打断等待。
            if !server.isRunning { throw HdcError("设备采集端启动失败：\(log.text)") } // 保留真实 Java/权限错误。
            if let candidate = try? AndroidSocket(port: port) {
                do { // dummy 字节确认设备端实际接受视频连接。
                    let dummy = try candidate.read(1, attempt: attempt, deadline: min(deadline, Date().addingTimeInterval(0.5))) // 设备端未就绪时迅速重试。
                    guard dummy == Data([0]) else { throw HdcError("Android 握手无效") } // 拒绝连接到其他服务。
                    video = candidate // 只有确认握手才接管连接。
                } catch { candidate.close() } // 失败连接立即失效。
            }
            if video == nil { usleep(50_000) } // 等待期间只占用本设备的后台队列。
        }
        guard let video else { throw HdcError("等待设备采集端超时：\(log.text)") } // 不报告虚假的已连接。
        progress(.connectingControl) // 第二条 socket 与第一条属于同一 scid。
        let channel = try AndroidSocket(port: port); control = channel // 必须在读取设备名之前接通控制，设备端会等待 accept。
        let nameBytes = try video.read(64, attempt: attempt, deadline: deadline) // 官方固定六十四字节设备名。
        let name = String(decoding: nameBytes.prefix { $0 != 0 }, as: UTF8.self) // 不读取零填充。
        guard try video.read(4, attempt: attempt, deadline: deadline) == Data("h264".utf8) else { throw HdcError("设备返回了不支持的视频编码") } // 不把编码标识误当像素尺寸。
        guard case .size(let width, let height) = try AndroidWire.videoHeader(video.read(12, attempt: attempt, deadline: deadline)) else { throw HdcError("设备未返回初始视频尺寸") } // scrcpy 5 的初始 session metadata。
        let encoded = CGSize(width: width, height: height) // 编码缩放后的尺寸。
        let physical = ScreenGeometry.orientedSize(native: native, video: encoded) // 初始横屏不被当作竖屏。
        try attempt.checkCancellation() // 所有资源建立完毕仍检查是否已关窗。
        let session = AndroidMirrorSession(serial: device.serial, model: name.isEmpty ? device.model : name, code: device.model, fps: fps, bitrate: bits, scale: ratio, physical: physical, encoded: encoded, adb: adb, video: video, control: channel, server: server, log: log, port: port, remote: remote, attempt: attempt) // 完整移交资源和取消凭据。
        completed = true // 工厂 defer 不再清理已交付连接。
        return session // 由统一工作队列管理生命周期。
    }

    public func start() { // 回调安装后才启动两个读取线程。
        state.lock(); let shouldStart = !started && !stopped; started = true; state.unlock() // 重复 start 不重复读取同一流。
        guard shouldStart else { return } // 已停止会话不能复活。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.readVideo() } // 视频不在主线程解包。
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.readClipboard() } // 设备消息独立于输入队列读取。
    }
    private func readVideo() { // 旋转、配置帧和普通帧采用相同协议解析。
        do {
            while !attempt.isCancelled { // 静止屏幕可以长时间没有帧。
                let header = try AndroidWire.videoHeader(video.read(12, attempt: attempt)) // 正确区分 session 元数据。
                switch header {
                case .size(let width, let height): state.lock(); encoded = CGSize(width: width, height: height); state.unlock() // 控制坐标立即跟随编码方向。
                case .frame(let count, let timing):
                    let accessUnit = try video.read(count, attempt: attempt) // 读完载荷后按套接字顺序交付。
                    onFrame?(VideoPacket(accessUnit: accessUnit, timing: timing))
                }
            }
        } catch { report(error) } // 真正断流交给共用恢复逻辑。
    }
    private func readClipboard() { // 只处理官方设备消息，不主动同步到电脑剪贴板。
        do {
            while !attempt.isCancelled {
                let type = try control.read(1, attempt: attempt)[0] // 设备消息类型独立于控制消息类型。
                switch type {
                case 0: // CLIPBOARD，长度及文本均来自真实设备回应。
                    let length = Int(AndroidWire.unsigned(try control.read(4, attempt: attempt), at: 0, bytes: 4)) // 先检查长度。
                    guard length <= 262139 else { throw HdcError("设备剪贴板消息过长") } // 不允许任意内存增长。
                    let value = String(decoding: try control.read(length, attempt: attempt), as: UTF8.self) // 空剪贴板保持空字符串。
                    state.lock(); clipboard = value; clipboardGeneration += 1; state.broadcast(); state.unlock() // 唤醒这次用户复制请求。
                case 1: _ = try control.read(8, attempt: attempt) // ACK 序号，不写入系统剪贴板。
                default: throw HdcError("设备返回了未知控制消息") // 不猜测后续消息边界。
                }
            }
        } catch { report(error) } // 控制通道不可用也应停止当前会话。
    }
    private func report(_ error: Error) { // 主动取消不触发重连，真实断流带有可用的设备端诊断。
        guard !attempt.isCancelled else { return } // 不发布主动关闭的错误。
        let detail = serverLog.text.trimmingCharacters(in: .whitespacesAndNewlines) // 不输出无意义空行。
        onError?(detail.isEmpty ? error.localizedDescription : "\(error.localizedDescription)：\(detail)") // 保留实际采集原因。
    }
    public func stop() { // 视频、控制与服务端清理均幂等。
        state.lock(); let shouldStop = !stopped; stopped = true; clipboard = nil; state.broadcast(); state.unlock() // 清除内存中的设备文本。
        guard shouldStop else { return } // 多个结束通知不能重复清理。
        attempt.cancel(); video.close(); control.close() // 首先解除后台读取。
        if server.isRunning { server.terminate() } // 只结束本会话的 ADB shell。
        let process = server // 延迟回收只持有具体进程，不搜索全局进程名。
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } } // 非响应客户端不会永久遗留。
        _ = try? adb.run(["-s", serial, "forward", "--remove", "tcp:\(port)"], timeout: 5) // 不影响其他设备或其他应用的转发。
        _ = try? adb.run(["-s", serial, "shell", "rm -f \(FileDelivery.quote(remote))"], timeout: 5) // 删除自己创建的 jar。
    }
    public func updateSize(_ size: CGSize) { state.lock(); physical = size; state.unlock() } // 共用控制器根据真实 SPS 方向更新。
    private func position(x: Int, y: Int) -> Data { state.lock(); defer { state.unlock() }; return AndroidWire.position(x: x, y: y, physical: physical, video: encoded) } // 一致快照避免混用两次旋转尺寸。
    private func send(_ data: Data) { do { try control.send(data) } catch { report(error) } } // 输入错误进入真实错误反馈。
    public func touch(_ phase: TouchPhase, x: Int, y: Int) { send(AndroidWire.touch(phase, position: position(x: x, y: y))) } // 同一 VideoSurface 提供输入。
    public func scroll(x: Int, y: Int, steps: Int) -> Bool { do { try control.send(AndroidWire.scroll(steps: steps, position: position(x: x, y: y))); return true } catch { report(error); return false } } // 滚轮保持纯轴事件。
    public func rotate(horizontal: Bool) { send(Data([11])) } // scrcpy 的 rotate-device 切换当前旋转，不写系统永久设置。
    public func backOrWake() throws { try control.send(Data([4, 0])); try control.send(Data([4, 1])) } // 官方 BACK_OR_SCREEN_ON 与鸿蒙右键语义一致。
    public func pressKey(_ code: UInt32) { guard let android = AndroidWire.androidKey(code) else { return }; send(AndroidWire.key(code: android, down: true)); send(AndroidWire.key(code: android, down: false)) } // 标题栏和键盘共用映射。
    public func sendText(_ text: String, x: Int, y: Int) { do { try control.send(AndroidWire.clipboard(text, paste: true)) } catch { report(error) } } // 保留中文与长文本，不使用有字符限制的 input text。
    public func verifyControl() -> Bool { deviceClipboardText() != nil } // 仅显式自检入口等待设备真实回应，不把 socket 存活当自检成功。
    public func deviceClipboardText() -> String? { // 用户主动请求时读取真实设备回应，不复用陈旧缓存。
        state.lock(); let generation = clipboardGeneration; state.unlock() // 记录请求前的状态。
        do { try control.send(Data([8, 0])) } catch { report(error); return nil } // COPY_KEY_NONE 仅读取当前剪贴板。
        state.lock(); defer { state.unlock() } // 等待时 NSCondition 自动释放锁。
        let deadline = Date().addingTimeInterval(3) // 设备不回应不能卡死输入队列。
        while clipboardGeneration == generation && !stopped && !attempt.isCancelled && Date() < deadline { _ = state.wait(until: min(deadline, Date().addingTimeInterval(0.1))) } // 轮询取消，且总等待有上限。
        let result = stopped || attempt.isCancelled || clipboardGeneration == generation ? nil : clipboard // 空文本仍然是有效结果。
        clipboard = nil // 完成请求后不保留私密文本缓存。
        return result // 只交付给当前明确请求的调用者。
    }
    public func screenshot(to destination: URL) throws { // 两个平台的截图按钮保存同样的 JPEG 文件。
        let remote = "/data/local/tmp/hosmirror-shot-\(UUID().uuidString).png" // 不覆盖其他截图。
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png") // 本地 PNG 仅用于转换。
        defer { try? FileManager.default.removeItem(at: local); _ = try? adb.run(["-s", serial, "shell", "rm -f \(FileDelivery.quote(remote))"], timeout: 5) } // 只清理当前任务临时文件。
        try adb.run(["-s", serial, "shell", "screencap -p \(FileDelivery.quote(remote))"], timeout: 15, attempt: attempt) // 截图采用设备原始分辨率，关窗可取消。
        try adb.run(["-s", serial, "pull", remote, local.path], timeout: 30, attempt: attempt) // 不通过字符串管道传递二进制 PNG。
        guard let source = CGImageSourceCreateWithURL(local as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let target = CGImageDestinationCreateWithURL(destination as CFURL, "public.jpeg" as CFString, 1, nil) else { throw HdcError("无法读取设备截图") } // 失败不留下伪 JPEG。
        CGImageDestinationAddImage(target, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary) // 保留清晰内容并与现有保存格式一致。
        guard CGImageDestinationFinalize(target) else { throw HdcError("无法保存设备截图") } // 磁盘失败明确报告。
    }
}

private final class AndroidServerLog: @unchecked Sendable { // 服务端输出来自后台管道。
    private let lock = NSLock() // 所有诊断读写同步。
    private var tail = Data() // 不保存屏幕、音频或剪贴板。
    func append(_ data: Data) { lock.lock(); defer { lock.unlock() }; tail.append(data); if tail.count > 8192 { tail = Data(tail.suffix(8192)) } } // 上限八 KiB。
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: tail, as: UTF8.self) } // 返回一致的诊断快照。
}
