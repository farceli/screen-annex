import Foundation
import Darwin

public struct H2Error: Error, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Minimal HTTP/2 (h2c) client tailored to one gRPC server-streaming call.
///
/// Stream 1 carries video; short IDR requests use separate streams on the same socket.
/// Headers use literal-without-indexing and response headers are not decoded.
public final class H2Connection {
    private var fd: Int32 = -1
    private let readQueue = DispatchQueue(label: "hosmirror.h2.read")
    private let stateLock = NSLock() // 保护 socket 生命周期和写操作。
    private var closed = false // 只能在 stateLock 内读写。
    private var started = false // 防止启动多个并发读取循环。
    private let authority: String
    private var nextRequestStream: UInt32 = 3 // HTTP/2 客户端使用递增的奇数流标识。

    public var onData: (([UInt8]) -> Void)?
    public var onEnd: ((String?) -> Void)?

    public init(port: UInt16, path: String = "/ScrcpyService/onStart") throws {
        authority = "127.0.0.1:\(port)"
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw H2Error("无法创建 socket") }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            fd = -1 // 初始化失败后标记 socket 已释放。
            throw H2Error("无法连接 127.0.0.1:\(port)")
        }

        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) // 写入同样不能无限阻塞。

        write(Array("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8))

        var settings = Data()
        appendSetting(to: &settings, id: 0x4, value: 16 * 1024 * 1024) // INITIAL_WINDOW_SIZE
        sendFrame(type: 0x4, flags: 0, stream: 0, payload: [UInt8](settings))
        sendFrame(type: 0x8, flags: 0, stream: 0, payload: bigEndian32(16 * 1024 * 1024))

        sendRequest(path: path, stream: 1)
    }

    func requestKeyFrame() {
        stateLock.lock() // 分配本次请求专用流，不能占用承载视频的流 1。
        let stream = nextRequestStream
        nextRequestStream += 2
        stateLock.unlock()
        sendRequest(path: "/ScrcpyService/onRequestIDRFrame", stream: stream)
    }

    private func sendRequest(path: String, stream: UInt32) {
        var headers: [UInt8] = []
        appendHeader(to: &headers, name: ":method", value: "POST")
        appendHeader(to: &headers, name: ":scheme", value: "http")
        appendHeader(to: &headers, name: ":path", value: path)
        appendHeader(to: &headers, name: ":authority", value: authority)
        appendHeader(to: &headers, name: "content-type", value: "application/grpc")
        appendHeader(to: &headers, name: "te", value: "trailers")
        appendHeader(to: &headers, name: "user-agent", value: "hosmirror/0.1")

        sendFrame(type: 0x1, flags: 0x4, stream: stream, payload: headers)
        // gRPC message for `Empty`: compression flag + zero length
        sendFrame(type: 0x0, flags: 0x1, stream: stream, payload: [0, 0, 0, 0, 0])
    }

    public func start() {
        stateLock.lock() // 读取线程只能创建一次。
        guard !started, !closed else { stateLock.unlock(); return }
        started = true // close 从此只 shutdown，由读循环最终 close。
        stateLock.unlock()
        readQueue.async { self.readLoop() } // 读循环完成最终 close 前保持对象存活。
    }

    deinit { close() } // 从未开始读取的连接也必须释放描述符。

    private var isClosed: Bool {
        stateLock.lock() // close 可来自另一工作队列。
        defer { stateLock.unlock() }
        return closed // 返回受锁保护的停止状态。
    }

    public func close() {
        stateLock.lock() // 避免 shutdown/写入/最终 close 互相竞争。
        defer { stateLock.unlock() }
        guard !closed else { return }
        closed = true // 先阻止后续写入和回调。
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR) // 唤醒阻塞的 recv，但不立即复用描述符。
            if !started {
                Darwin.close(fd) // 没有读取线程时由当前线程完成释放。
                fd = -1
            }
        }
    }

    // MARK: - Frame output

    private func sendFrame(type: UInt8, flags: UInt8, stream: UInt32, payload: [UInt8]) {
        var frame = [UInt8]()
        let length = payload.count
        frame.append(UInt8((length >> 16) & 0xFF))
        frame.append(UInt8((length >> 8) & 0xFF))
        frame.append(UInt8(length & 0xFF))
        frame.append(type)
        frame.append(flags)
        frame.append(contentsOf: bigEndian32(stream & 0x7FFF_FFFF))
        frame.append(contentsOf: payload)
        write(frame)
    }

    private func write(_ bytes: [UInt8]) {
        stateLock.lock() // 序列化完整帧写入，关闭不能在中途复用 fd。
        defer { stateLock.unlock() }
        guard fd >= 0, !closed else { return }
        var offset = 0
        while offset < bytes.count {
            let sent = bytes.withUnsafeBytes { raw -> Int in
                Darwin.send(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
            }
            if sent <= 0 { return }
            offset += sent
        }
    }

    private func appendSetting(to data: inout Data, id: UInt16, value: UInt32) {
        data.append(UInt8((id >> 8) & 0xFF))
        data.append(UInt8(id & 0xFF))
        data.append(contentsOf: bigEndian32(value))
    }

    private func appendHeader(to bytes: inout [UInt8], name: String, value: String) {
        let nameBytes = Array(name.utf8)
        let valueBytes = Array(value.utf8)
        bytes.append(0x00) // literal header field without indexing, new name
        bytes.append(UInt8(nameBytes.count))
        bytes.append(contentsOf: nameBytes)
        bytes.append(UInt8(valueBytes.count))
        bytes.append(contentsOf: valueBytes)
    }

    private func bigEndian32(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    // MARK: - Frame input

    private func readLoop() {
        var reason: String? // 只在循环结束时发送一次结束通知。
        defer {
            stateLock.lock() // 读循环是已启动连接唯一的最终关闭者。
            let notify = !closed // 用户主动停止时不产生自动重连通知。
            closed = true
            if fd >= 0 { Darwin.close(fd); fd = -1 } // recv 已结束，现在可以安全释放 fd。
            stateLock.unlock()
            if notify { onEnd?(reason) } // 不在锁内调用外部回调。
        }
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)

        reading: while !isClosed {
            let received = chunk.withUnsafeMutableBytes { raw -> Int in
                Darwin.recv(fd, raw.baseAddress, raw.count, 0)
            }
            if received <= 0 {
                if received < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                    continue
                }
                break
            }
            buffer.append(contentsOf: chunk[0..<received])

            while buffer.count >= 9 {
                let length = Int(buffer[0]) << 16 | Int(buffer[1]) << 8 | Int(buffer[2])
                guard buffer.count >= 9 + length else { break }
                let type = buffer[3]
                let flags = buffer[4]
                let stream = UInt32(buffer[5] & 0x7F) << 24 | UInt32(buffer[6]) << 16 | UInt32(buffer[7]) << 8 | UInt32(buffer[8])
                let payload = Array(buffer[9..<(9 + length)])
                buffer.removeFirst(9 + length)
                if let end = handleFrame(type: type, flags: flags, stream: stream, payload: payload) {
                    reason = end // END_STREAM/GOAWAY 同时结束读取并释放 socket。
                    break reading
                }
            }
        }

    }

    private func handleFrame(type: UInt8, flags: UInt8, stream: UInt32, payload: [UInt8]) -> String? {
        switch type {
        case 0x4: // SETTINGS
            if flags & 0x1 == 0 { sendFrame(type: 0x4, flags: 0x1, stream: 0, payload: []) }
        case 0x6: // PING
            if flags & 0x1 == 0 { sendFrame(type: 0x6, flags: 0x1, stream: 0, payload: payload) }
        case 0x0: // DATA
            if !payload.isEmpty {
                if stream == 1 { onData?(payload) } // IDR 命令的响应体不参与 H.264 解包。
                sendFrame(type: 0x8, flags: 0, stream: 0, payload: bigEndian32(UInt32(payload.count)))
                if stream == 1 { sendFrame(type: 0x8, flags: 0, stream: stream, payload: bigEndian32(UInt32(payload.count))) }
            }
            if stream == 1, flags & 0x1 != 0 { return "stream closed" }
        case 0x1: // HEADERS
            if stream == 1, flags & 0x1 != 0 { return "trailers" }
        case 0x7: // GOAWAY
            return "goaway"
        case 0x3: // RST_STREAM 也必须结束当前视频会话。
            if stream == 1 { return "stream reset" }
        default:
            break
        }
        return nil // 非结束帧继续读取。
    }
}
