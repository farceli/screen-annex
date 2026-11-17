import Foundation
import Darwin

public enum TouchPhase {
    case down, move, up
}

/// Client for the uitest agent JSON-RPC socket.
public final class ControlClient {
    private var fd: Int32 = -1
    private let lock = NSLock()
    private var requestHandler: ((String, Any) -> [String: Any]?)? // 内部测试可观察协议请求，不需要设备。

    init(requestHandler: @escaping (String, Any) -> [String: Any]?) {
        self.requestHandler = requestHandler // 仅供模块测试注入请求端。
    }

    deinit { close() } // 正常与测试实例均允许安全释放。

    public init(port: UInt16) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HdcError("无法创建控制 socket") }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size)) // 触摸移动是小包，立即发送。

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
            throw HdcError("无法连接控制通道 127.0.0.1:\(port)")
        }

        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    public func close() {
        lock.lock()
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            fd = -1
        }
        lock.unlock()
    }

    @discardableResult
    public func request(api: String, args: Any) -> [String: Any]? {
        if let requestHandler { return requestHandler(api, args) } // 测试与真实调用共用同一高层滚轮路径。
        return exchange(method: "Gestures", params: ["api": api, "args": args])
    }

    func createKeyboardDriver() -> String? {
        let reply = exchange(method: "callHypiumApi", params: ["api": "Driver.create", "this": "", "args": []])
        return reply?["result"] as? String
    }

    func sendKeyboardStroke(_ stroke: KeyMap.Stroke, driver: String) -> Bool {
        // 通用 UiTest 方法使用现有连接和 Driver 引用，避免为每个字键启动 hdc 和 uitest。
        let api = stroke.shift ? "Driver.triggerCombineKeys" : "Driver.triggerKey"
        let args: [UInt32] = stroke.shift ? [2047, stroke.code] : [stroke.code]
        guard let reply = exchange(method: "callHypiumApi", params: ["api": api, "this": driver, "args": args]),
              reply["result"] != nil else { return false }
        return reply["exception"] == nil || reply["exception"] is NSNull
    }

    enum BackResult: Equatable {
        case sent
        case unsupported
        case unconfirmed
    }

    func pressBack(driver: String) -> BackResult {
        // 复用文字输入的 UiTest 连接，通过系统返回动作省去启动第二次 HDC。
        let reply = exchange(method: "callHypiumApi", params: ["api": "Driver.pressBack", "this": driver, "args": []])
        return Self.backResult(from: reply)
    }

    static func backResult(from reply: [String: Any]?) -> BackResult {
        guard let reply else { return .unconfirmed }
        if let exception = reply["exception"], !(exception is NSNull) {
            // 只有设备明确报告没有对应处理器时才回退，避免超时或执行错误后重复返回。
            let details = exception as? [String: Any]
            let message = details?["message"] as? String
            return message?.hasPrefix("No handler found for api") == true ? .unsupported : .unconfirmed
        }
        return reply["result"] != nil ? .sent : .unconfirmed
    }

    private func exchange(method: String, params: [String: Any]) -> [String: Any]? {
        let message: [String: Any] = [
            "module": "com.ohos.devicetest.hypiumApiHelper",
            "method": method,
            "params": params,
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: message) else { return nil }

        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return nil }

        var bytes = [UInt8](payload)
        bytes.append(0x0A) // newline

        var offset = 0
        while offset < bytes.count {
            let sent = bytes.withUnsafeBytes { raw -> Int in
                Darwin.send(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
            }
            if sent <= 0 { return nil }
            offset += sent
        }

        var response = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let received = chunk.withUnsafeMutableBytes { raw -> Int in
                Darwin.recv(fd, raw.baseAddress, raw.count, 0)
            }
            if received <= 0 { break }
            response.append(contentsOf: chunk[0..<received])
            if response.contains(0x0A) { break }
        }

        guard !response.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: Data(response)) as? [String: Any]
        else { return nil }
        return json
    }

    public func touch(_ phase: TouchPhase, x: Int, y: Int) {
        let api: String
        switch phase {
        case .down: api = "touchDown"
        case .move: api = "touchMove"
        case .up: api = "touchUp"
        }
        _ = request(api: api, args: ["x": x, "y": y])
    }

    @discardableResult
    public func tap(x: Int, y: Int) -> Bool {
        let down = request(api: "touchDown", args: ["x": x, "y": y]) != nil
        let up = request(api: "touchUp", args: ["x": x, "y": y]) != nil
        return down && up
    }

    /// 使用设备端鼠标滚轮轴事件；失败时也不能回退为可能触发点击的触摸手势。
    @discardableResult
    public func scroll(x: Int, y: Int, steps: Int) -> Bool {
        let count = min(3, max(-3, steps)) // 每批有界，避免占用控制通道过久。
        guard count != 0 else { return true } // 小数累计或手势结束不产生空操作。
        let args = ["x": x, "y": y] // 原生轴事件定位到指针下的滚动容器。
        let api = count > 0 ? "AxisDown" : "AxisUp" // 保持已有滚动方向约定。
        func accepted(_ response: [String: Any]?) -> Bool {
            guard let response else { return false }
            for key in ["exception", "error"] {
                if let value = response[key], !(value is NSNull) { return false } // 非空错误才表示设备拒绝。
            }
            return true
        }
        var success = true
        for _ in 0..<abs(count) {
            if !accepted(request(api: api, args: args)) { success = false; break } // 失败时停止后续步进。
        }
        let stopped = accepted(request(api: "AxisStop", args: args)) // 即使中途失败也尝试结束滚轮轴序列。
        return success && stopped // 整个路径从不发送 touchDown/Up 或鼠标按钮事件。
    }

    public func rotate(horizontal: Bool) {
        _ = request(api: "Driver.setDisplayRotation", args: [horizontal ? 1 : 0])
    }

    public func captureLayout() -> [String: Any]? {
        request(api: "captureLayout", args: [:])
    }
}
