import Foundation // 同一窗口只面对统一的会话能力，不区分底层传输。
import CoreGraphics // 视频尺寸与触控坐标采用同一模型。

public enum DevicePlatform: String, Sendable, CaseIterable, Codable { // 原始值也用于读取持久化的设备记录。
    case harmony = "鸿蒙" // 使用现有 hdc/uitest 后端。
    case android = "Android" // 使用官方 scrcpy-server 协议。
    public func identifier(serial: String) -> String { rawValue + ":" + serial } // 两个平台即使序列号相同也不会共用窗口。
    public var titlePrefix: String { self == .harmony ? "HarmonyOS" : "Android" } // 显示用英文名称，设备标识仍沿用各后端原来的命名空间。
    public var windowTitlePrefix: String { "「\(titlePrefix)」" } // 菜单分组保留裸系统名，窗口标题使用书名括号样式。
    public func title(model: String) -> String { windowTitlePrefix + " " + (model.isEmpty ? "设备" : model) }
    public var defaultDirectory: String { self == .android ? "/sdcard/Download/HosMirror" : FileDelivery.defaultDirectory } // 两个平台均默认放入手机“下载/HosMirror”。
    public var packageExtension: String { self == .android ? "apk" : "hap" } // 安装入口一致，实际格式服从设备系统。
}

/// 一个 Annex-B 视频包，可同时携带设备编码器提供的时间信息。
public struct VideoPacket: Sendable {
    public struct Timing: Equatable, Sendable {
        public let presentationTimeUs: Int64 // scrcpy 使用微秒，交给渲染器换算到 Mac 时钟。
        public let isKeyFrame: Bool // 关键帧可独立恢复解码。

        public init(presentationTimeUs: Int64, isKeyFrame: Bool) {
            self.presentationTimeUs = presentationTimeUs
            self.isKeyFrame = isKeyFrame
        }
    }

    public let accessUnit: Data // 只包含 H.264 载荷。
    public let timing: Timing? // 参数集以及无时间戳的鸿蒙视频包均可省略。

    public init(accessUnit: Data, timing: Timing? = nil) {
        self.accessUnit = accessUnit
        self.timing = timing
    }
}

/// 协议适配器只处理设备差异；窗口、输入、截图、录制和重连共用现有控制器。
public protocol DeviceSessionBackend: SessionResource {
    var serial: String { get } // 不可变设备身份。
    var model: String { get } // 用户可读的设备名。
    var modelCode: String { get } // 保留底层型号用于诊断。
    var effectiveFPS: Int { get } // 本次启动采用的帧率。
    var effectiveBitrate: Int { get } // 本次启动采用的码率。
    var effectiveScale: Double { get } // 本次启动采用的缩放。
    var deviceSize: CGSize { get } // 当前物理方向尺寸，供统一窗口约束使用。
    var onFrame: ((VideoPacket) -> Void)? { get set } // 两个平台使用同一渲染器。
    var onError: ((String) -> Void)? { get set } // 断流进入同一重连策略。
    func start() // 回调安装之后才接收帧。
    func requestKeyFrame() // 解码缺少参考帧时请求独立画面。
    func updateSize(_ size: CGSize) // 旋转同步触控坐标。
    func touch(_ phase: TouchPhase, x: Int, y: Int) // 单一触控入口。
    func scroll(x: Int, y: Int, steps: Int) -> Bool // 滚轮不能回退成点击。
    func rotate(horizontal: Bool) // 用户切换方向的入口一致。
    func backOrWake() throws // 右键亮屏返回、熄屏唤醒。
    func pressKey(_ code: UInt32) // 统一逻辑键由后端映射到系统键码。
    func sendText(_ text: String, x: Int, y: Int) throws // 中文文本与粘贴共用。
    func verifyControl() -> Bool // 仅显式诊断入口调用。
    func deviceClipboardText() -> String? // 复制按钮等待真实设备响应。
    func screenshot(to destination: URL) throws // 图片路径与反馈统一。
}

public extension DeviceSessionBackend {
    func requestKeyFrame() {} // Android 桌面客户端自行管理视频解码。
}

extension MirrorSession: DeviceSessionBackend {}

/// 用引用类型擦除后端差异，使 SessionWorker 仍拥有严格串行的资源释放权。
public final class DeviceSession: SessionResource {
    private let backend: any DeviceSessionBackend // 不对界面暴露系统专有类型。
    public init(_ backend: any DeviceSessionBackend) { self.backend = backend } // 工厂在工作队列中创建实际后端。
    public var serial: String { backend.serial } // 委托到固定设备。
    public var model: String { backend.model } // 两个平台同样展示营销名或实际型号。
    public var modelCode: String { backend.modelCode } // 诊断保留原型号。
    public var effectiveFPS: Int { backend.effectiveFPS } // 日志采用真实配置。
    public var effectiveBitrate: Int { backend.effectiveBitrate } // 日志采用真实配置。
    public var effectiveScale: Double { backend.effectiveScale } // 日志采用真实配置。
    public var deviceSize: CGSize { backend.deviceSize } // 窗口约束不再区分系统。
    public var onFrame: ((VideoPacket) -> Void)? { get { backend.onFrame } set { backend.onFrame = newValue } } // 保留设备发来的时间信息。
    public var onError: ((String) -> Void)? { get { backend.onError } set { backend.onError = newValue } } // 同一断流恢复流程。
    public func start() { backend.start() } // 回调就绪后启动。
    public func requestKeyFrame() { backend.requestKeyFrame() }
    public func stop() { backend.stop() } // 每个后端必须允许重复清理。
    public func updateSize(_ size: CGSize) { backend.updateSize(size) } // 统一坐标方向。
    public func touch(_ phase: TouchPhase, x: Int, y: Int) { backend.touch(phase, x: x, y: y) } // 不在界面分叉点击逻辑。
    public func scroll(x: Int, y: Int, steps: Int) -> Bool { backend.scroll(x: x, y: y, steps: steps) } // 同一滚轮累计策略。
    public func rotate(horizontal: Bool) { backend.rotate(horizontal: horizontal) } // 同一菜单命令。
    public func backOrWake() throws { try backend.backOrWake() } // 保留真实失败。
    public func pressKey(_ code: UInt32) { backend.pressKey(code) } // 后端只转换键码。
    public func sendText(_ text: String, x: Int, y: Int) throws { try backend.sendText(text, x: x, y: y) } // 同一发送文本面板。
    public func verifyControl() -> Bool { backend.verifyControl() } // 原诊断能力保持可用。
    public func deviceClipboardText() -> String? { backend.deviceClipboardText() } // 同一剪贴板按钮。
    public func screenshot(to destination: URL) throws { try backend.screenshot(to: destination) } // 同一保存目录和错误反馈。
}
