import CoreGraphics // 原生投屏窗口使用完整设备尺寸。
import Foundation // 设备枚举、参数构造与路径解析无需引入界面框架。

/// Android 设备与鸿蒙设备分别建模，避免相同序列号进入错误的协议后端。
public struct AndroidDevice: Identifiable, Equatable, Sendable {
    public let serial: String // ADB 返回的原始序列号仅作为独立进程参数使用。
    public let state: String // 保留 unauthorized/offline 等真实状态，不伪装为可投屏。
    public let model: String // 来自 adb devices -l 的 model 字段。
    public let transport: DeviceTransport?
    public init(serial: String, state: String, model: String, transport: DeviceTransport? = nil) {
        self.serial = serial
        self.state = state
        self.model = model
        self.transport = transport
    }
    public var id: String { serial } // 同一 Android 设备刷新时保持稳定标识。
    public var canConnect: Bool { state == "device" } // 只有已授权且在线的设备允许启动。
    public var statusText: String { // 将常见 ADB 状态转为可操作的中文提示。
        switch state {
        case "device": return "已就绪" // ADB 已完成授权。
        case "unauthorized": return "请在手机上允许 USB 调试" // 不绕过系统授权。
        case "offline": return "设备离线，请重新连接" // 离线不能继续启动 scrcpy。
        default: return "暂不可连接（\(state)）" // 未知状态保留原文供排查。
        }
    }
    public static func parse(_ output: String) -> [AndroidDevice] { // 纯解析函数便于无设备回归。
        var seen = Set<String>() // 防止重复行生成重复的 SwiftUI 标识。
        return output.split(whereSeparator: \.isNewline).compactMap { line in // ADB 每行描述一台设备。
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init) // 同时兼容空格、制表符和 CRLF。
            guard fields.count >= 2, !line.hasPrefix("List of devices"), !line.hasPrefix("*"), // 排除表头与服务启动提示。
                  !fields[0].hasPrefix("adb:"), ["device", "unauthorized", "offline", "recovery", "sideload", "bootloader", "no"].contains(fields[1]), // 不把任意日志当设备。
                  seen.insert(fields[0]).inserted else { return nil } // 保留首条真实设备记录。
            let model = fields.first(where: { $0.hasPrefix("model:") }).map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") } ?? fields[0] // 未授权时可能没有型号。
            let serial = fields[0]
            let serviceName = serial.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let transport: DeviceTransport?
            if fields.dropFirst(2).contains(where: { $0.hasPrefix("usb:") }) {
                transport = .usb
            } else if serviceName.hasSuffix("._adb-tls-connect._tcp") || (try? Adb.validateAddress(serial)) != nil {
                transport = .wireless // 无线调试可按 IP:端口或 mDNS 服务名出现在列表。
            } else {
                transport = nil // 模拟器或缺少连接标记的设备保留未知状态。
            }
            return AndroidDevice(serial: serial, state: fields[1], model: model, transport: transport)
        }
    }
}

/// 通过官方 Platform Tools 连接 Android，测试可在运行目录提供隔离替身。
public struct Adb: Sendable {
    public let directory: URL // 指向当前平台的完整 scrcpy 运行目录。
    public var binary: URL { binary(in: ProcessInfo.processInfo.environment) }

    func binary(in environment: [String: String]) -> URL {
        if let path = environment["HOSMIRROR_ADB"], !path.isEmpty { return URL(fileURLWithPath: path) } // 允许自定义 SDK 安装位置。
        let files = FileManager.default
        let bundled = directory.appendingPathComponent("adb")
        if files.isExecutableFile(atPath: bundled.path) { return bundled } // 兼容旧版本和隔离测试。
        let sdk = files.homeDirectoryForCurrentUser.appendingPathComponent("Library/Android/sdk/platform-tools/adb")
        if files.isExecutableFile(atPath: sdk.path) { return sdk } // Finder 启动时仍能使用默认 Android Studio SDK。
        for path in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(path)).appendingPathComponent("adb")
            if files.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return sdk // 缺失时由调用入口提供配置提示。
    }
    public init(directory: URL) { self.directory = directory } // 路径可注入以支持隔离测试。
    @discardableResult
    public func run(_ arguments: [String], timeout: TimeInterval = 15, attempt: ConnectionAttempt? = nil, poll: (() -> Void)? = nil) throws -> String { // 共用超时、取消与真实字节轮询。
        let executable = binary // 此次调用使用同一个已解析的路径。
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw HdcError("请安装 Android SDK Platform Tools，或设置 HOSMIRROR_ADB。")
        }
        return try Hdc(binary: executable, displayName: "ADB").run(arguments, timeout: timeout, attempt: attempt, poll: poll)
    }
    public func devices(attempt: ConnectionAttempt? = nil) throws -> [AndroidDevice] { // 所有真实设备状态都来自 ADB。
        AndroidDevice.parse(try run(["devices", "-l"], attempt: attempt)) // -l 提供用户可读的型号，启动中的请求可取消。
    }

    public func productDisplayName(serial: String, attempt: ConnectionAttempt) -> String? {
        // 厂商可能把商品名放在 vendor 分区，普通型号字段则可能只返回硬件代码。
        let command = "for p in ro.product.marketname ro.vendor.oplus.market.name ro.oplus.market.name ro.product.model; do v=$(getprop \"$p\"); [ -z \"$v\" ] || printf '%s\\n' \"$v\"; done"
        guard let output = try? run(["-s", serial, "shell", command], timeout: 2, attempt: attempt) else { return nil }
        return output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !["", "unknown", "null", "undefined"].contains($0.lowercased()) }
    }
    public static func validateAddress(_ raw: String) throws -> String { // 无线连接与配对都要求显式端口。
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines) // 允许用户粘贴时带首尾空格。
        guard let separator = value.lastIndex(of: ":"), let port = Int(value[value.index(after: separator)...]), (1...65535).contains(port) else { // 拒绝无效端口。
            throw HdcError("请输入手机无线调试页面显示的 IP:端口") // 不猜测配对端口或连接端口。
        }
        let host = String(value[..<separator]) // 支持普通主机与方括号 IPv6 地址。
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:[]") // 不接受空格、选项或 shell 语法。
        guard !host.isEmpty, !host.hasPrefix("-"), host.unicodeScalars.allSatisfy(allowed.contains) else { // 保持输入作为单个地址参数。
            throw HdcError("无线地址格式不正确") // 在启动工具前反馈错误。
        }
        return value // 原样传给 ADB，避免改写 IPv6 表示。
    }
    public func connect(_ address: String) throws { // 已配对设备使用连接端口。
        let result = try run(["connect", Self.validateAddress(address)], timeout: 30) // ADB 连接失败可能仍返回零退出码。
        guard result.lowercased().contains("connected to") else { throw HdcError(result) } // 只接受已连接或已经连接的明确结果。
    }
    public func pair(_ address: String, code: String) throws { // Android 11+ 无线调试支持六位配对码。
        guard code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw HdcError("请输入手机显示的六位配对码") } // 不保存或记录配对码。
        let result: String // 错误路径同样不能将配对码写入诊断。
        do { result = try run(["pair", Self.validateAddress(address), code], timeout: 30) } // 配对不经过 shell，也不写入用户偏好。
        catch { throw HdcError(error.localizedDescription.replacingOccurrences(of: code, with: "[配对码已隐藏]")) } // 工具若回显参数，仍将敏感码清除。
        guard result.lowercased().contains("successfully paired") else { throw HdcError(result.replacingOccurrences(of: code, with: "[配对码已隐藏]")) } // 成功配对不等于已经连接。
    }
    public func longEdge(serial: String) throws -> Int { // 手动画质缩放以设备报告的尺寸为基准。
        let size = try screenSize(serial: serial) // 与原生会话共用屏幕覆盖尺寸规则。
        return Int(max(size.width, size.height)) // 返回当前逻辑屏幕长边。
    }
    public func screenSize(serial: String, attempt: ConnectionAttempt? = nil, timeout: TimeInterval = 15) throws -> CGSize { // 原生窗口需要完整宽高，而非仅长边。
        let text = try run(["-s", serial, "shell", "wm", "size"], timeout: timeout, attempt: attempt) // 不访问屏幕内容，关窗时可以取消。
        let sizes = text.split(whereSeparator: \.isWhitespace).compactMap { value -> CGSize? in // Override size 位于物理尺寸之后，优先使用最后一项。
            let pair = value.split(separator: "x").compactMap { Int($0) } // 仅接受完整的宽高数字。
            return pair.count == 2 && pair.allSatisfy({ (1...65535).contains($0) }) ? CGSize(width: pair[0], height: pair[1]) : nil // 过滤日志和畸形尺寸。
        }
        guard let edge = sizes.last else { throw HdcError("无法读取 Android 屏幕尺寸") } // 不静默使用错误缩放。
        return edge // 供 scrcpy 的 max-size 参数使用。
    }

    public func displayRotation(serial: String, attempt: ConnectionAttempt) -> Int? { // 只读当前默认屏幕的实际方向，不能使用自动旋转偏好代替。
        let command = "dumpsys input | grep -m 1 -E 'Viewport (INTERNAL|VIRTUAL): displayId=0,.*orientation=[0-3]'"
        guard let line = try? run(["-s", serial, "shell", command], timeout: 2, attempt: attempt),
              let marker = line.range(of: "orientation="),
              let value = line[marker.upperBound...].first?.wholeNumberValue, (0...3).contains(value) else { return nil }
        return value // 无法读取时让官方客户端自行计算首屏窗口大小。
    }
}

/// Android 后端的启动参数保持独立，鸿蒙端口与守护进程不参与此流程。
public enum AndroidRuntime {
    public static var platform: String { // 与 vendor 清单和打包脚本共用平台名。
        #if arch(arm64)
        return "macos-aarch64" // Apple Silicon 使用原生二进制。
        #else
        return "macos-x86_64" // Intel Mac 使用 x86_64 二进制。
        #endif
    }
    public static var directory: URL { AppResources.root.appendingPathComponent("scrcpy/\(platform)") } // 客户端与 server 均来自当前 App 的运行目录。
    public static func arguments(serial: String, title: String, fps: Int?, bitrate: Int?, maxSize: Int?, onTop: Bool) -> [String] { // 未手动设置画质时使用 scrcpy 自己的默认值。
        var result = ["--serial=\(serial)", "--window-title=\(title)"] // 使用等号绑定值，避免序列号被当成选项。
        if let fps { result.append("--max-fps=\(fps)") } // 只在手动模式下传入帧率。
        if let bitrate { result.append("--video-bit-rate=\(bitrate)M") } // 只在手动模式下传入码率。
        if let maxSize { result.append("--max-size=\(maxSize)") } // 未设置时保留 scrcpy 原始尺寸策略。
        if onTop { result.append("--always-on-top") } // 连接设置在启动窗口时生效。
        return result // 其余控制、音频、剪贴板和文件拖放沿用上游实现。
    }
    public static func environment(directory: URL, inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] { // 显式指定全部设备端与图标路径。
        var result = inherited // 保留系统会话变量，兼容 SDL 的原生窗口。
        result["ADB"] = Adb(directory: directory).binary(in: inherited).path // scrcpy 与设备列表使用同一个 ADB。
        result["SCRCPY_SERVER_PATH"] = directory.appendingPathComponent("scrcpy-server").path // client/server 必须来自同一版本。
        result["SCRCPY_ICON_PATH"] = directory.appendingPathComponent("scrcpy.png").path // 保留上游程序图标与来源识别。
        return result // 环境修改仅作用于当前子进程。
    }
}
