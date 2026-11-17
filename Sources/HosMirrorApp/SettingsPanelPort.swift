import CoreFoundation
import Foundation

/// 两个窗口进程通过本机消息交换操作与快照，端口名随每次设置进程启动更新。
@MainActor
final class SettingsPanelPort {
    private final class Receiver {
        let receive: (Data) -> Void
        init(_ receive: @escaping (Data) -> Void) { self.receive = receive }
    }

    private let receiver: Receiver
    private let port: CFMessagePort
    private let source: CFRunLoopSource

    init?(name: String, receive: @escaping (Data) -> Void) {
        let receiver = Receiver(receive)
        self.receiver = receiver
        var context = CFMessagePortContext(version: 0, info: Unmanaged.passUnretained(receiver).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        var nameInUse = DarwinBoolean(false)
        guard let port = CFMessagePortCreateLocal(nil, name as CFString, { _, _, data, info in
            guard let data, let info, CFDataGetLength(data) <= 1_048_576 else { return nil }
            let receiver = Unmanaged<Receiver>.fromOpaque(info).takeUnretainedValue()
            receiver.receive(data as Data) // 消息源在主运行循环处理，按到达顺序交给界面与会话。
            return nil
        }, &context, &nameInUse), !nameInUse.boolValue else { return nil }
        guard let source = CFMessagePortCreateRunLoopSource(nil, port, 0) else {
            CFMessagePortInvalidate(port)
            return nil
        }
        self.port = port
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    deinit {
        CFRunLoopSourceInvalidate(source)
        CFMessagePortInvalidate(port)
    }

    static func send<T: Encodable>(_ value: T, to name: String) -> Bool {
        guard let data = try? JSONEncoder().encode(value),
              let port = CFMessagePortCreateRemote(nil, name as CFString) else { return false }
        // 不等待对端回包，避免两个界面进程互相等待。
        return CFMessagePortSendRequest(port, 0, data as CFData, 0.05, 0, nil, nil) == kCFMessagePortSuccess
    }
}

struct SettingsPanelChannel {
    let id: UUID
    var commands: String { "com.hosmirror.settings.\(id.uuidString).commands" }
    var events: String { "com.hosmirror.settings.\(id.uuidString).events" }
}
