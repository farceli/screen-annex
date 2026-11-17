import Foundation
import Darwin // 超时或取消时强制回收不响应 SIGTERM 的本地主进程。

public struct HdcError: Error, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Thin wrapper around the bundled `hdc` binary.
public final class Hdc: Sendable { // 仅保存不可变工具 URL，每次调用的进程与输出缓冲均独立。
    public let binary: URL
    private let displayName: String // 同一套有界输出与超时逻辑也供内置 ADB 使用。

    public init(binary: URL, displayName: String = "hdc") { // 默认名称保持所有鸿蒙调用兼容。
        self.binary = binary
        self.displayName = displayName // 错误必须指出实际失败的工具。
    }

    @discardableResult
    public func run(_ args: [String], timeout: TimeInterval = 30,
                    attempt: ConnectionAttempt? = nil, poll: (() -> Void)? = nil) throws -> String {
        try attempt?.checkCancellation() // 排队期间取消的命令不得启动。
        let process = Process()
        process.executableURL = binary
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw HdcError("无法执行 \(displayName): \(error.localizedDescription)")
        }
        let output = HdcOutput() // 两条输出管道共享线程安全的有限缓冲区。
        let readers = DispatchGroup() // 返回前等待读取结束，避免遗失最后的错误原因。
        for handle in [outPipe.fileHandleForReading, errPipe.fileHandleForReading] {
            readers.enter() // 每条管道独立排空，防止大输出导致子进程死锁。
            DispatchQueue.global(qos: .utility).async {
                defer { readers.leave() } // 所有读取路径都回收等待计数。
                while true {
                    let data = handle.availableData // 阻塞读取发生在后台线程。
                    if data.isEmpty { break } // 子进程关闭写端后停止。
                    output.append(data) // 锁内只复制数据，不调用外部回调。
                }
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        var nextPoll = Date() // 有进度监听时立刻读取一次，再限频到每半秒一次。
        while process.isRunning && Date() < deadline && attempt?.isCancelled != true {
            if let poll, Date() >= nextPoll {
                poll() // 调用方可从手机读取真实已写入字节，禁止模拟百分比。
                nextPoll = Date().addingTimeInterval(0.5) // 避免高频设备 shell 请求。
            }
            usleep(20_000)
        }
        let interrupted = process.isRunning // 正常退出不能误报成超时。
        if process.isRunning {
            process.terminate() // 先请求正常退出。
            let grace = Date().addingTimeInterval(0.3) // 给本地主进程短暂的回收时间。
            while process.isRunning && Date() < grace { usleep(10_000) } // 不占用 UI 线程。
            if process.isRunning { kill(process.processIdentifier, SIGKILL) } // 不遗留卡死的 hdc 客户端。
        }
        process.waitUntilExit()
        readers.wait() // 两条管道均已读到 EOF 后再检查完整结果。
        let text = output.text // 保留原始设备诊断供失败提示使用。
        try attempt?.checkCancellation() // 取消的结果不能被接管为成功。
        if interrupted { throw HdcError("\(displayName) 超时（\(Int(timeout)) 秒）：\(text)") } // 给出时限与设备输出。

        if process.terminationStatus != 0 {
            throw HdcError(text.isEmpty ? "\(displayName) 失败: \(args.joined(separator: " "))" : text)
        }
        return text
    }

    public func listTargets(attempt: ConnectionAttempt? = nil) throws -> [String] {
        try readTargets(verbose: false, attempt: attempt).filter(\.canConnect).map(\.serial) // 投屏启动只验证可用设备。
    }

    public func targets() throws -> [DeviceInfo] {
        try readTargets(verbose: true, attempt: nil) // 菜单需要区分授权失败和设备离线。
    }

    private func readTargets(verbose: Bool, attempt: ConnectionAttempt?) throws -> [DeviceInfo] {
        let arguments = verbose ? ["list", "targets", "-v"] : ["list", "targets"]
        let output = try run(arguments, timeout: 10, attempt: attempt)
        if output.contains("Connect server failed") || output.contains("[Fail]") { throw HdcError(output) } // 某些 HDC 失败仍返回零退出码。
        var seen = Set<String>()
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let serial = fields.first, !["[empty]", "empty"].contains(serial.lowercased()) else { return nil }
            let state = fields.count >= 3 ? fields[2] : fields.dropFirst().first ?? "connected" // 简略输出也可能附带 Unauthorized。
            guard ["connected", "ready", "unauthorized", "offline", "unknown"].contains(state.lowercased()),
                  seen.insert(serial).inserted else { return nil } // 排除日志与重复设备。
            let transport: DeviceTransport?
            switch fields.dropFirst().first?.lowercased() {
            case "usb": transport = .usb
            case "tcp": transport = .wireless
            default: transport = nil
            }
            return DeviceInfo(serial: serial, state: state, transport: transport)
        }
    }

    @discardableResult
    public func shell(_ command: String, serial: String, timeout: TimeInterval = 20, attempt: ConnectionAttempt? = nil) throws -> String {
        try run(["-t", serial, "shell", command], timeout: timeout, attempt: attempt) // 保留原调用的默认超时。
    }

    public func push(local: URL, remote: String, serial: String, attempt: ConnectionAttempt? = nil) throws {
        _ = try run(["-t", serial, "file", "send", local.path, remote], timeout: 120, attempt: attempt) // 重新连接时仍会校验远端文件摘要。
    }

    public func forward(localPort: Int, remote: String, serial: String) throws {
        let output = try run(["-t", serial, "fport", "tcp:\(localPort)", remote], timeout: 15) // 先记录成功建立的转发，再检查取消。
        if output.contains("[Fail]") || output.contains("Forward parament failed") || output.contains("Connect server failed") {
            throw HdcError(output) // HDC 的文本错误也需要走兼容回退和清理。
        }
    }

    public func removeForward(localPort: Int, serial: String) {
        _ = try? run(["-t", serial, "fport", "rm", "tcp:\(localPort)"], timeout: 10)
    }

    public func connectWireless(_ address: String) throws {
        _ = try run(["tconn", address], timeout: 15)
    }
}

/// 只保存输出尾部，防止异常命令无限输出耗尽内存。
private final class HdcOutput: @unchecked Sendable { // 全部可变数据都由内部 NSLock 保护。
    private let lock = NSLock() // stdout/stderr 两个读线程共用此锁。
    private var data = Data() // 缓冲区最多保留 256 KiB。
    func append(_ chunk: Data) {
        lock.lock() // 同步追加与截断。
        defer { lock.unlock() } // 即使未来增加返回分支也会释放锁。
        data.append(chunk) // 保存设备错误原文。
        if data.count > 262_144 { data = Data(data.suffix(262_144)) } // 保留最后的结果和错误码。
    }
    var text: String {
        lock.lock() // 读取一致快照。
        defer { lock.unlock() } // 返回时释放锁。
        return String(decoding: data, as: UTF8.self) // 非 UTF-8 字节不导致整个错误文本丢失。
    }
}
