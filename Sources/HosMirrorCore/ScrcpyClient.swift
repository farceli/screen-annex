import Foundation

/// Receives the H.264 access units of `ScrcpyService/onStart`.
public final class ScrcpyClient {
    private let connection: H2Connection
    private var grpcBuffer: [UInt8] = []
    private let lock = NSLock()
    private var stopping = false

    public var onFrame: ((Data) -> Void)?
    public var onError: ((String) -> Void)?

    public init(port: UInt16) throws {
        connection = try H2Connection(port: port)
        connection.onData = { [weak self] payload in self?.consume(payload) }
        connection.onEnd = { [weak self] reason in
            guard let self else { return }
            self.lock.lock() // stop 与接收回调来自不同线程。
            let stopping = self.stopping // 在锁内读取停止状态。
            self.lock.unlock()
            guard !stopping else { return }
            self.onError?(reason ?? "视频流已结束")
        }
    }

    public func start() {
        connection.start() // 完成回调注册以后才启动读取线程。
    }

    public func requestKeyFrame() {
        connection.requestKeyFrame() // 继续使用原 HDC 转发和 gRPC 连接，避免重新连接设备。
    }

    deinit { stop() } // 没有显式关闭时也释放 socket。

    public func stop() {
        lock.lock() // 与接收线程同步停止标记。
        stopping = true
        lock.unlock()
        connection.close()
    }

    private func consume(_ payload: [UInt8]) {
        lock.lock()
        grpcBuffer.append(contentsOf: payload)
        var messages: [[UInt8]] = []

        while grpcBuffer.count >= 5 {
            let length = Int(grpcBuffer[1]) << 24 | Int(grpcBuffer[2]) << 16 | Int(grpcBuffer[3]) << 8 | Int(grpcBuffer[4])
            guard length >= 0, grpcBuffer.count >= 5 + length else { break }
            messages.append(Array(grpcBuffer[5..<(5 + length)]))
            grpcBuffer.removeFirst(5 + length)
        }
        lock.unlock()

        for message in messages {
            if let data = Proto.replyData(message) {
                onFrame?(Data(data))
            }
        }
    }
}
