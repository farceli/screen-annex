import Foundation
import CoreGraphics
import CryptoKit

public enum DeviceTransport: Hashable, Sendable {
    case usb
    case wireless
}

public struct DeviceInfo: Identifiable, Hashable, Sendable {
    public let serial: String
    public var id: String { serial }
    public let state: String // HDC 的详细枚举包含授权状态。
    public let transport: DeviceTransport? // 旧版工具省略连接方式时保留未知状态。
    public var canConnect: Bool { state == "connected" || state == "ready" } // 仅允许已就绪设备投屏。
    public var statusText: String {
        switch state {
        case "unauthorized": return "请在手机上允许 USB 调试"
        case "offline": return "设备离线，请重新连接"
        default: return "暂不可连接（\(state)）"
        }
    }
    public init(serial: String, state: String = "connected", transport: DeviceTransport? = nil) {
        self.serial = serial
        self.state = state.lowercased() // 统一处理不同工具版本的大小写。
        self.transport = transport
    }
}

public struct StartedSession {
    public let serial: String
    public let model: String
    public let modelCode: String // 分别保留展示名称与硬件代码。
    public let videoPort: UInt16
    public let controlPort: UInt16
    public let deviceSize: CGSize
    public let frameRate: Int
    public let bitRateMbps: Int
    public let scale: Double
    public let cleanup: () -> Void
}

/// Pushes the device-side agent, starts `uitest` daemons and creates the two
/// forwarded ports used by the mirror session.
public final class DeviceBootstrapper {
    public typealias Logger = (String) -> Void

    private let hdc: Hdc
    private let resources: URL
    private let log: Logger
    private let progress: (ConnectionStage) -> Void // 通过真实步骤向界面报告阶段。
    private let portAllocator: (() throws -> UInt16)? // 测试可注入端口，避免依赖真实网络。
    private let onIdentity: (DeviceIdentity) -> Void // 主窗口可以复用启动探测读到的型号。

    public init(hdc: Hdc, resources: URL, log: @escaping Logger = { _ in }, portAllocator: (() throws -> UInt16)? = nil, progress: @escaping (ConnectionStage) -> Void = { _ in }, onIdentity: @escaping (DeviceIdentity) -> Void = { _ in }) {
        self.hdc = hdc
        self.resources = resources
        self.log = log
        self.progress = progress // 默认无观察者时保持原有启动行为。
        self.portAllocator = portAllocator // 默认仍使用系统分配的空闲端口。
        self.onIdentity = onIdentity // 命令行调用方可以继续忽略提前返回的型号。
    }

    public func bootstrap(
        serial: String,
        frameRate: Int = 30,
        bitRateMbps: Int = 8,
        scale: Double = 1.0,
        attempt: ConnectionAttempt = ConnectionAttempt() // 允许界面关闭时中止剩余启动步骤。
    ) throws -> StartedSession {
        try attempt.checkCancellation() // 取消的排队任务不再访问设备。
        progress(.checkingDevice) // 对应真实的设备发现与系统探测。
        log("检查设备 \(serial)…")
        guard try hdc.listTargets(attempt: attempt).contains(serial) else {
            throw HdcError("设备未连接：\(serial)")
        }

        let probe = try probeDevice(serial: serial, attempt: attempt)
        try attempt.checkCancellation() // 探测期间取消则不推送组件。
        log("uitest 版本 \(probe.version)")

        progress(.preparingDevice) // 接下来检查和同步设备组件。
        let assets = try selectAssets(uitestVersion: probe.version, isEmulator: probe.isEmulator)
        log("采集端 \(assets.server.lastPathComponent)，注入端 \(assets.agent.lastPathComponent)")

        var completed = false // 只有所有端口和组件准备完成才移交资源所有权。
        var ports: [Int] = [] // 记录已成功建立的转发，失败时按实际进度回滚。
        defer {
            if !completed { // 异常与取消都必须清理部分启动的设备会话。
                ports.forEach { hdc.removeForward(localPort: $0, serial: serial) } // 删除已建立的本地转发。
                _ = try? hdc.shell("pkill -9 -f singleness", serial: serial) // 停止可能已启动的守护进程。
            }
        }
        try attempt.checkCancellation() // 在开始修改设备状态前再次检查取消。
        _ = try? hdc.shell("pkill -9 -f singleness", serial: serial, attempt: attempt) // 停止上次会话，避免接入旧采集进程。
        try wait(until: uptime + 0.5, attempt: attempt) // 保留原有退出缓冲，防止旧进程尚未释放 socket。
        try syncFile(local: assets.server, remote: "/data/local/tmp/libscreen_casting.z.so", remoteMD5: probe.serverMD5, serial: serial, attempt: attempt)
        try attempt.checkCancellation() // 较大的文件传输完成后检查用户是否已关闭窗口。
        try syncFile(local: assets.agent, remote: "/data/local/tmp/agent.so", remoteMD5: probe.agentMD5, serial: serial, attempt: attempt)

        try attempt.checkCancellation() // 取消后不再启动采集守护进程。
        progress(.connectingVideo) // 视频端启动后仍需建立控制端。
        log("启动采集守护进程…")
        let scaleDivisor = scale == 0.5 ? 2 : 1 // 物理设备采集扩展读取整数缩放除数，不能直接传小数。
        let effectiveScale = 1 / Double(scaleDivisor)
        let params = "-scale \(scaleDivisor) -frameRate \(frameRate) -bitRate \(bitRateMbps << 20) -p 5000 -iFrameInterval 2000"
        let videoCommand = "/system/bin/uitest start-daemon singleness --extension-name libscreen_casting.z.so \(params) &"
        _ = try hdc.shell(videoCommand, serial: serial, attempt: attempt)
        var videoEndpoint = try waitForEndpoint(name: "scrcpy_grpc_socket", port: 5000, serial: serial, timeout: 1.4, attempt: attempt)
        if videoEndpoint == nil, try daemonCount(serial: serial, attempt: attempt) == 0 {
            log("采集守护进程未就绪，重试一次")
            _ = try hdc.shell(videoCommand, serial: serial, attempt: attempt)
            videoEndpoint = try waitForEndpoint(name: "scrcpy_grpc_socket", port: 5000, serial: serial, timeout: 1.4, attempt: attempt)
        }

        try attempt.checkCancellation() // 就绪后或兼容等待结束时检查取消。
        let videoPort = try portAllocator?() ?? freePort()
        try forward(localPort: videoPort, detected: videoEndpoint, name: "scrcpy_grpc_socket", port: 5000, serial: serial, attempt: attempt)

        ports.append(Int(videoPort)) // 后续任一步失败都能释放视频转发。
        try attempt.checkCancellation() // 不为已取消的连接启动控制端。
        progress(.connectingControl) // 这是实际控制端启动，不用计时伪造进度。
        log("启动注入守护进程…")
        _ = try hdc.shell("/system/bin/uitest start-daemon singleness &", serial: serial, attempt: attempt)
        let controlEndpoint = try waitForEndpoint(name: "uitest_socket", port: 8012, serial: serial, timeout: 0.8, attempt: attempt)

        let controlPort = try portAllocator?() ?? freePort()
        try forward(localPort: controlPort, detected: controlEndpoint, name: "uitest_socket", port: 8012, serial: serial, attempt: attempt)

        ports.append(Int(controlPort)) // 控制转发也纳入失败回滚。
        try attempt.checkCancellation() // 返回结果前执行最后一次取消检查。
        log("设备分辨率 \(Int(probe.size.width))×\(Int(probe.size.height))")

        let cleanup: () -> Void = { [hdc] in
            hdc.removeForward(localPort: Int(videoPort), serial: serial)
            hdc.removeForward(localPort: Int(controlPort), serial: serial)
            _ = try? hdc.shell("pkill -9 -f singleness", serial: serial)
        }

        progress(.waitingForFrame) // 连接成功尚不代表画面已经到达。
        completed = true // 从这里开始由 MirrorSession 负责清理。
        return StartedSession(
            serial: serial,
            model: probe.model,
            modelCode: probe.modelCode,
            videoPort: videoPort,
            controlPort: controlPort,
            deviceSize: probe.size,
            frameRate: frameRate,
            bitRateMbps: bitRateMbps,
            scale: effectiveScale,
            cleanup: cleanup
        )
    }

    // MARK: - Device probe

    private struct ProbeResult {
        let version: String
        let model: String
        let modelCode: String
        let isEmulator: Bool
        let serverMD5: String?
        let agentMD5: String?
        let size: CGSize
    }

    /// One round trip for everything we need to know before touching the device.
    private func probeDevice(serial: String, attempt: ConnectionAttempt) throws -> ProbeResult {
        let script = """
        echo __V__; /system/bin/uitest --version; \
        \(DeviceIdentity.probeCommand); \
        echo __E__; ls /system/lib64/libCPHMediaEngine.z.so 2>&1; \
        echo __M1__; md5sum /data/local/tmp/libscreen_casting.z.so 2>&1; \
        echo __M2__; md5sum /data/local/tmp/agent.so 2>&1; \
        echo __S__; SP_daemon -screen 2>&1
        """
        let output = try hdc.shell(script, serial: serial, timeout: 25, attempt: attempt)

        func section(_ name: String) -> String {
            guard let start = output.range(of: "__\(name)__") else { return "" }
            let rest = output[start.upperBound...]
            if let next = rest.range(of: "__", options: []) {
                return String(rest[..<next.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let versionSection = section("V")
        let version = versionSection
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { $0.first?.isNumber == true && $0.contains(".") }) ?? "0.0.0"

        let emulatorText = section("E")
        let isEmulator = emulatorText.contains("libCPHMediaEngine") && !emulatorText.lowercased().contains("no such file")

        let identity = DeviceIdentity.parse(output) // 使用同一套清洗和名称优先级，避免标题先后不一致。
        onIdentity(identity) // 复用本次探测，避免窗口再发一组名称查询。
        let sizeText = section("S")

        var size = CGSize(width: 1080, height: 2340)
        if let range = sizeText.range(of: #"(\d{3,5})x(\d{3,5})"#, options: .regularExpression) {
            let parts = sizeText[range].split(separator: "x")
            if parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]) {
                size = CGSize(width: width, height: height)
            }
        }

        return ProbeResult(
            version: version,
            model: identity.displayName,
            modelCode: identity.modelCode,
            isEmulator: isEmulator,
            serverMD5: firstMD5(section("M1")),
            agentMD5: firstMD5(section("M2")),
            size: size
        )
    }

    private func firstMD5(_ text: String) -> String? {
        guard let token = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" }).first,
              token.count == 32,
              token.allSatisfy({ $0.isHexDigit })
        else { return nil }
        return String(token).lowercased()
    }

    private struct Assets {
        let server: URL
        let agent: URL
    }

    private func selectAssets(uitestVersion: String, isEmulator: Bool) throws -> Assets {
        let version = Version(uitestVersion)
        let devices = resources.appendingPathComponent("devices")
        let agents = resources.appendingPathComponent("agents")

        let serverName: String
        if isEmulator {
            serverName = "libscrcpy_server_emulator.z.so"
        } else if version >= Version("6.0.2.1") {
            let preferred = "libscrcpy_server_unix_6.5-device.z.so"
            serverName = FileManager.default.fileExists(atPath: devices.appendingPathComponent(preferred).path)
                ? preferred
                : "libscrcpy_server_unix_6.4-20260113.z.so"
        } else if version >= Version("5.1.1.2") {
            serverName = "libscrcpy_server_5.10-20260114.z.so"
        } else {
            serverName = "libscrcpy_server3.z.so"
        }

        let agentName = version >= Version("6.0.2.1") ? "uitest_agent_1.2.2.so" : "uitest_agent_1.1.10.so"

        let server = devices.appendingPathComponent(serverName)
        let agent = agents.appendingPathComponent(agentName)
        guard FileManager.default.fileExists(atPath: server.path) else {
            throw HdcError("缺少设备端组件：\(serverName)")
        }
        guard FileManager.default.fileExists(atPath: agent.path) else {
            throw HdcError("缺少注入端组件：\(agentName)")
        }
        return Assets(server: server, agent: agent)
    }

    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime } // 用单调时钟限制探测和兼容等待。

    private func wait(until deadline: TimeInterval, attempt: ConnectionAttempt) throws {
        while uptime < deadline {
            try attempt.checkCancellation() // 等待期间也响应关闭窗口。
            Thread.sleep(forTimeInterval: max(0, min(0.075, deadline - uptime))) // 限制轮询间隔，避免忙等。
        }
        try attempt.checkCancellation()
    }

    private func waitForEndpoint(name: String, port: Int, serial: String, timeout: TimeInterval, attempt: ConnectionAttempt) throws -> String? {
        let deadline = uptime + timeout // 最长仍采用旧版的单次启动等待。
        let hexPort = String(format: "%04X", port) // 设备的 TCP 监听表以十六进制表示端口。
        let command = """
        if [ -r /proc/net/unix ]; then echo __UNIX__; grep -F ' @\(name)' /proc/net/unix; fi
        if [ -r /proc/net/tcp ] || [ -r /proc/net/tcp6 ]; then
            echo __TCP__; grep -i ':\(hexPort) ' /proc/net/tcp /proc/net/tcp6 2>/dev/null
        fi
        :
        """ // 只取目标监听项。设备不开放这些文件时使用兼容路径。
        while uptime < deadline {
            try attempt.checkCancellation()
            let output = try? hdc.shell(command, serial: serial, timeout: max(0.02, deadline - uptime), attempt: attempt)
            try attempt.checkCancellation() // 上面的兼容降级不能吞掉用户取消。
            guard let output, output.contains("__UNIX__") || output.contains("__TCP__") else { break }
            for line in output.split(whereSeparator: \.isNewline) {
                let columns = line.split(whereSeparator: \.isWhitespace)
                if columns.count == 8, columns[7] == "@\(name)", Int(columns[4], radix: 16) == 1,
                   let flags = Int(columns[3], radix: 16), flags & 0x10000 != 0 {
                    return "localabstract:\(name)" // UNIX 流式 socket 已处于监听状态。
                }
                if columns.count >= 10, columns[1].uppercased().hasSuffix(":\(hexPort)"), columns[3] == "0A" {
                    return "tcp:\(port)" // 老版设备的 TCP 端点已在监听。
                }
            }
            try wait(until: min(deadline, uptime + 0.075), attempt: attempt) // 给服务启动留出时间，随后重新观察。
        }
        try wait(until: deadline, attempt: attempt) // 表不可读或探测超时时按原时长等待。
        return nil // 转发继续使用抽象 socket 到 TCP 的原有回退。
    }

    private func forward(localPort: UInt16, detected: String?, name: String, port: Int, serial: String, attempt: ConnectionAttempt) throws {
        try attempt.checkCancellation() // 取消后不再创建新转发。
        let abstract = "localabstract:\(name)"
        let tcp = "tcp:\(port)"
        let preferred = detected ?? abstract // 有确切的监听端点时优先使用它。
        do {
            try hdc.forward(localPort: Int(localPort), remote: preferred, serial: serial)
        } catch {
            try attempt.checkCancellation() // 取消时只回滚已成功的转发。
            let fallback = preferred == abstract ? tcp : abstract
            log("\(preferred) 转发失败，回退 \(fallback)")
            try hdc.forward(localPort: Int(localPort), remote: fallback, serial: serial)
        }
    }

    private func daemonCount(serial: String, attempt: ConnectionAttempt) throws -> Int {
        let output = (try? hdc.shell("ps -ef | grep singleness | grep -v grep", serial: serial, attempt: attempt)) ?? ""
        try attempt.checkCancellation() // 取消后不能再启动采集守护进程。
        return output.split(separator: "\n").filter { $0.contains("uitest") }.count
    }

    private func syncFile(local: URL, remote: String, remoteMD5: String?, serial: String, attempt: ConnectionAttempt) throws {
        let localMD5 = md5(of: local)
        if remoteMD5 == localMD5 {
            log("\(remote) 已是最新")
            return
        }
        log("推送 \(local.lastPathComponent) → \(remote)")
        try hdc.push(local: local, remote: remote, serial: serial, attempt: attempt)
    }

    private func md5(of url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HdcError("无法分配本地端口") }
        defer { Darwin.close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw HdcError("无法分配本地端口") }

        var result = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &result) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        return result.sin_port.bigEndian
    }
}

struct Version: Comparable {
    private let parts: [Int]

    init(_ string: String) {
        parts = string
            .split(separator: ".")
            .map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
    }

    static func < (lhs: Version, rhs: Version) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        for index in 0..<count {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func >= (lhs: Version, rhs: Version) -> Bool { !(lhs < rhs) }
}
