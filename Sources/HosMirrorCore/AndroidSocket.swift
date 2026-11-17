import Foundation // 有界消息收发与取消凭据。
import Darwin // 本地 ADB 转发只连接回环地址。

/// 描述符直到读取线程释放对象才关闭，避免关闭/重用竞态误读其他连接。
final class AndroidSocket: @unchecked Sendable {
    private let fd: Int32 // 生命周期内不可替换的套接字。
    private let stateLock = NSLock() // 同步关闭状态。
    private let writeLock = NSLock() // 控制消息不允许交错写入。
    private var stopped = false // 关闭后阻止新消息。
    init(port: UInt16) throws { // 仅连接用户设备对应的本地 ADB 转发。
        fd = socket(AF_INET, SOCK_STREAM, 0) // 使用 TCP 回环传输。
        guard fd >= 0 else { throw HdcError("无法创建 Android 通道") } // 不继续使用无效描述符。
        var yes: Int32 = 1 // 发送到断开的连接不能终止整个 App。
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) // macOS 的 SIGPIPE 防护。
        var address = sockaddr_in() // 不能连到任意外部网络地址。
        address.sin_family = sa_family_t(AF_INET) // IPv4 localhost。
        address.sin_port = port.bigEndian // 网络字节序。
        address.sin_addr.s_addr = inet_addr("127.0.0.1") // ADB 负责 USB/无线到手机的桥接。
        let status = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } // 同步连接本地端口。
        guard status == 0 else { Darwin.close(fd); throw HdcError("无法连接 Android 通道") } // 初始化失败及时关闭。
        var receive = timeval(tv_sec: 0, tv_usec: 200_000) // 短超时用于检查取消，而非判定静止画面断流。
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receive, socklen_t(MemoryLayout<timeval>.size)) // 空闲读取仍可及时停止。
        var sendTimeout = timeval(tv_sec: 3, tv_usec: 0) // 控制写入不能无限阻塞工作队列。
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size)) // 保持失败可恢复。
    }
    deinit { Darwin.close(fd) } // 没有并发读取持有对象时才真正释放描述符。
    var isStopped: Bool { stateLock.lock(); defer { stateLock.unlock() }; return stopped } // 所有线程读取一致状态。
    func close() { // shutdown 立即解除读取等待，重复调用安全。
        stateLock.lock() // 防止清理与写入观察到混合状态。
        stopped = true // 后续操作明确取消。
        Darwin.shutdown(fd, SHUT_RDWR) // 不立即 close，因此不会描述符重用。
        stateLock.unlock() // 不在锁中等待线程结束。
    }
    func read(_ count: Int, attempt: ConnectionAttempt, deadline: Date? = nil) throws -> Data { // 严格读取完整协议消息。
        var result = Data(count: count) // 分配由已验证长度决定的缓冲。
        var offset = 0 // TCP 可以拆分任意一个消息。
        while offset < count { // 不能将一次 recv 当成完整消息。
            try attempt.checkCancellation() // 连接期间与视频读取期间都可取消。
            if isStopped { throw CancellationError() } // 主动停止不报告网络故障。
            if let deadline, Date() >= deadline { throw HdcError("等待 Android 通道响应超时") } // 启动和剪贴板等待有明确上限。
            let amount = result.withUnsafeMutableBytes { bytes in Darwin.recv(fd, bytes.baseAddress!.advanced(by: offset), count - offset, 0) } // 在后台读取。
            if amount > 0 { offset += amount } // 按实际字节推进。
            else if amount < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue } // 静止画面不能触发重连。
            else { throw HdcError("Android 通道已关闭") } // 真正 EOF 或错误交给统一恢复策略。
        }
        return result // 返回完整消息，不向渲染器泄露半帧。
    }
    func send(_ data: Data) throws { // 发送一个不可交错的完整控制消息。
        writeLock.lock() // 输入和剪贴板命令可能来自不同后台线程。
        defer { writeLock.unlock() } // 错误时也释放写锁。
        var offset = 0 // 处理系统部分写入。
        while offset < data.count { // 不假定一次 send 完成。
            if isStopped { throw CancellationError() } // 停止后不发送旧输入。
            let amount = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: offset), data.count - offset, 0) } // 使用显式长度。
            if amount < 0 && errno == EINTR { continue } // 信号中断可重试。
            guard amount > 0 else { throw HdcError("Android 控制消息发送失败") } // 失败不能当作操作成功。
            offset += amount // 下一段继续发送剩余数据。
        }
    }
}
