import Foundation
import CoreGraphics

public enum AppResources {
    public static var root: URL {
        if let resource = Bundle.main.resourceURL,
           (FileManager.default.fileExists(atPath: resource.appendingPathComponent("tools/hdc").path)
            || FileManager.default.fileExists(atPath: resource.appendingPathComponent("scrcpy").path)) { // Android 资源定位不依赖鸿蒙 hdc 是否存在。
            return resource
        }
        if let env = ProcessInfo.processInfo.environment["HOSMIRROR_RESOURCES"] {
            return URL(fileURLWithPath: env)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources")
    }

    public static var harmonyRoot: URL {
        if let path = ProcessInfo.processInfo.environment["HOSMIRROR_HARMONY_RESOURCES"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true) // 明确指定的本机 SDK 路径优先。
        }
        let bundled = root // 兼容旧版 App 和命令行开发环境的资源布局。
        if ProcessInfo.processInfo.environment["HOSMIRROR_RESOURCES"] != nil
            || FileManager.default.isExecutableFile(atPath: bundled.appendingPathComponent("tools/hdc").path) {
            return bundled
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Screen Annex/HarmonyOS", isDirectory: true) // Finder 启动的 App 也能找到本机 SDK。
    }

    public static var hdcBinary: URL {
        harmonyRoot.appendingPathComponent("tools/hdc") // 第三方 SDK 由用户单独准备。
    }
}

/// A live mirror + control session for one device.
public final class MirrorSession: SessionResource {
    public let serial: String
    public let model: String
    public let modelCode: String // 完整产品名称之外保留诊断代码。
    public let effectiveFPS: Int
    public let effectiveBitrate: Int
    public let effectiveScale: Double
    public private(set) var deviceSize: CGSize
    public var onFrame: ((VideoPacket) -> Void)?
    public var onError: ((String) -> Void)?

    private let hdc: Hdc
    private let started: StartedSession
    private let scrcpy: ScrcpyClient
    private let control: ControlClient
    private var stopped = false
    private var activeTouch: (x: Int, y: Int)? // 关窗和重连时抬起设备上尚未结束的触摸。
    private var keyboardDriver: String? // 同一次连接中的英文与数字输入共用设备端 Driver。
    private var canPressBackViaControl = true // 旧版 agent 明确拒绝返回方法后，本次连接继续用系统命令。

    public init(hdc: Hdc, started: StartedSession) throws {
        self.hdc = hdc
        self.started = started
        self.serial = started.serial
        self.model = started.model
        self.modelCode = started.modelCode
        self.effectiveFPS = started.frameRate
        self.effectiveBitrate = started.bitRateMbps
        self.effectiveScale = started.scale
        self.deviceSize = started.deviceSize
        let video: ScrcpyClient
        do {
            video = try ScrcpyClient(port: started.videoPort) // 创建视频 socket，但暂不读取，等回调安装完毕。
        } catch {
            started.cleanup() // 视频连接失败时释放已经建立的转发和设备进程。
            throw error
        }
        do {
            self.control = try ControlClient(port: started.controlPort) // 控制连接也是会话启动的一部分。
        } catch {
            video.stop() // 部分初始化失败时先关闭已打开的视频 socket。
            started.cleanup() // 再释放设备资源，避免重连留下旧转发。
            throw error
        }
        self.scrcpy = video // 两条通道成功后才接管视频资源。

        scrcpy.onFrame = { [weak self] frame in self?.onFrame?(VideoPacket(accessUnit: frame)) } // 鸿蒙通道未提供设备时间戳。
        scrcpy.onError = { [weak self] message in self?.onError?(message) }
    }

    public func start() {
        scrcpy.start() // 调用方安装 onFrame/onError 后显式开始接收。
        keyboardDriver = control.createKeyboardDriver() // 在首帧显影期间准备按键入口。
    }

    public func requestKeyFrame() {
        guard !stopped else { return }
        scrcpy.requestKeyFrame()
    }

    deinit { stop() } // 已完整初始化的会话即使被意外释放也不遗留资源。

    public func stop() {
        guard !stopped else { return }
        stopped = true
        scrcpy.stop()
        if let activeTouch { control.touch(.up, x: activeTouch.x, y: activeTouch.y) }
        control.close()
        started.cleanup()
    }

    public func updateSize(_ size: CGSize) {
        if size.width > 0, size.height > 0 { deviceSize = size }
    }

    // MARK: - Input

    public func touch(_ phase: TouchPhase, x: Int, y: Int) {
        control.touch(phase, x: x, y: y)
        switch phase {
        case .down: activeTouch = (x, y)
        case .move: if activeTouch != nil { activeTouch = (x, y) }
        case .up: activeTouch = nil
        }
    }

    @discardableResult
    public func scroll(x: Int, y: Int, steps: Int) -> Bool {
        guard let command = HarmonyInputCommand.swipe(x: x, y: y, steps: steps, size: deviceSize) else { return steps == 0 }
        // 触屏列表可能忽略鼠标轴；用系统连续滑动命令把每批滚轮转换为一次完整手势。
        return (try? runInputCommand(command, timeout: 2)) != nil
    }

    public func rotate(horizontal: Bool) {
        control.rotate(horizontal: horizontal)
    }

    public func backOrWake() throws {
        let screen = (try? hdc.shell("hidumper -s RenderService -a screen", serial: serial, timeout: 2)) ?? "" // 读取当前主物理屏，不能依据桌面焦点判断已亮屏。
        var state = DisplayPowerState.parse(screen) // 主物理屏与虚拟投屏屏幕的电源状态不同。
        if state == .unknown {
            let output = (try? hdc.shell("hidumper -s PowerManagerService -a '-s'", serial: serial, timeout: 2)) ?? ""
            state = DisplayPowerState.parse(output) // 查询失败或仅返回服务标题时不能猜测屏幕亮灭。
        }
        if state == .on, canPressBackViaControl, let keyboardDriver {
            switch control.pressBack(driver: keyboardDriver) {
            case .sent:
                return
            case .unsupported:
                canPressBackViaControl = false
            case .unconfirmed:
                canPressBackViaControl = false
                throw HdcError("设备未确认返回操作")
            }
        }
        // 熄屏或无法确认亮屏时只唤醒。旧 agent 继续使用已支持的系统返回键。
        try runInputCommand(RightClickPolicy.command(for: state), timeout: 3)
    }

    public func pressKey(_ code: UInt32) {
        if let keyboardDriver, (2000...2071).contains(code) {
            if !control.sendKeyboardStroke(KeyMap.Stroke(code: code, shift: false), driver: keyboardDriver) {
                self.keyboardDriver = nil // 超时后不能重发同一按键，避免重复退格或回车。
            }
            return
        }
        _ = try? hdc.shell(KeyMap.command(code), serial: serial, timeout: 10)
    }

    public func sendText(_ text: String, x: Int, y: Int) throws {
        if let keyboardDriver, let strokes = KeyMap.asciiStrokes(for: text) {
            for stroke in strokes {
                guard control.sendKeyboardStroke(stroke, driver: keyboardDriver) else {
                    self.keyboardDriver = nil // 请求可能已经执行，后续文字改用系统命令。
                    throw HdcError("鸿蒙设备未确认键盘输入")
                }
            }
            return
        }
        guard let command = HarmonyInputCommand.focusedText(text) else { throw HdcError("文本包含设备不支持的字符") }
        try runInputCommand(command, timeout: 5) // 普通字符、输入法确认的文字和主动粘贴走同一路径。
    }

    private func runInputCommand(_ command: String, timeout: TimeInterval) throws {
        // hdc 的本地退出码不一定是远端命令的退出码，检查远端返回并避免把输入内容写入错误日志。
        let marker = "__HOSMIRROR_INPUT_STATUS__"
        guard let output = try? hdc.shell("\(command); printf '\\n\(marker)%d\\n' \"$?\"", serial: serial, timeout: timeout),
              output.split(whereSeparator: \.isNewline).last == "\(marker)0",
              !output.contains("Missing parameter"), !output.contains("invalid command"),
              !output.contains("[Fail]") else { throw HdcError("鸿蒙设备未能执行输入命令") }
    }

    /// One tap in the middle of the screen; used by the self-test to prove the
    /// uitest control channel is alive end to end.
    @discardableResult
    public func verifyControl() -> Bool {
        control.tap(x: Int(deviceSize.width / 2), y: Int(deviceSize.height / 2))
    }

    public func deviceClipboardText() -> String? {
        guard let output = try? hdc.shell("testhelper get-pastedata", serial: serial, timeout: 10) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Capture

    public func screenshot(to destination: URL) throws {
        let remote = "/data/local/tmp/hosmirror_shot.jpeg"
        _ = try hdc.shell("snapshot_display -f \(remote)", serial: serial)
        _ = try hdc.run(["-t", serial, "file", "recv", remote, destination.path], timeout: 30)
    }
}
