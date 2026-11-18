import XCTest // 验证真实会话接入官方帧格式和命令，不接触手机。
import Darwin // 回环替身模拟 ADB 转发后的两条 socket。
@testable import HosMirrorCore // 使用生产工厂、协议和资源清理代码。

final class AndroidNativeSessionTests: XCTestCase {
    func testSessionMetadataIsNotTreatedAsAVideoPayload() throws { // scrcpy 5 新增的会话元数据不能误按旧版解析。
        let portrait = Data([0x80, 0, 0, 0, 0, 0, 2, 208, 0, 0, 6, 64]) // 官方网络序：720×1600。
        XCTAssertEqual(try AndroidWire.videoHeader(portrait), .size(720, 1600)) // 初始窗口使用实际横竖屏。
        let frame = Data([0x40, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 11]) // config 标记不能被当作 session 尺寸。
        XCTAssertEqual(try AndroidWire.videoHeader(frame), .frame(length: 11, timing: nil)) // 配置包有载荷但没有播放时序。
        let timestamp = (UInt64(1) << 40) + 16_667 // 用超过 32 位的时间戳验证读取精度。
        let length = AndroidWire.integer(UInt32(11)) // 末尾四字节与时间字段独立。
        XCTAssertEqual(try AndroidWire.videoHeader(AndroidWire.integer(timestamp | (UInt64(1) << 61)) + length),
                       .frame(length: 11, timing: .init(presentationTimeUs: Int64(timestamp), isKeyFrame: true)))
        XCTAssertEqual(try AndroidWire.videoHeader(AndroidWire.integer(timestamp) + length),
                       .frame(length: 11, timing: .init(presentationTimeUs: Int64(timestamp), isKeyFrame: false)))
        XCTAssertThrowsError(try AndroidWire.videoHeader(Data(repeating: 0, count: 12))) // 空媒体 payload 无效。
        XCTAssertThrowsError(try AndroidWire.videoHeader(Data([0x80]))) // 短头不能被读取越界。
    }

    func testNativeSessionUsesTwoChannelsAndCleansOnlyItsOwnForward() throws { // 完整生产启动、读帧、输入、剪贴板及停止流程。
        let listener = try AndroidLoopback() // 仅在 localhost 建立测试 socket。
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hosmirror-native-test-" + UUID().uuidString) // 绝不使用真实 ADB 或设备。
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) // 放置专用工具替身。
        defer { try? FileManager.default.removeItem(at: folder) } // 测试退出清理文件。
        let trace = folder.appendingPathComponent("trace") // 记录真实生产命令的设备边界。
        let tool = folder.appendingPathComponent("adb") // 工厂只会调用这里的替身。
        let script = """
        #!/bin/sh
        # 只处理该测试所需的 ADB 命令，不访问真实设备。
        if [ "$1" = devices ]; then printf 'List of devices attached\\nfixture\\tdevice model:Fixture\\n'; exit 0; fi
        # 记录序列号和操作，以便验证没有使用全局 kill-server。
        printf '%s|%s|%s\\n' "$2" "$3" "$4" >> '\(trace.path)'
        # 由测试宿主提供的实际回环端口模拟 ADB 自动分配。
        if [ "$3" = forward ] && [ "$4" = tcp:0 ]; then printf '\(listener.port)\\n'; exit 0; fi
        # 返回已知物理尺寸，验证输入坐标与编码尺寸不同。
        if [ "$3" = shell ] && [ "$4" = wm ]; then printf 'Physical size: 1080x2400\\n'; exit 0; fi
        # 设备端进程由回环替身模拟；本地 sleep 作为可回收 shell 句柄。
        case "$4" in CLASSPATH=*) exec /bin/sleep 20 ;; esac
        # push、删除转发和删除临时文件仅返回成功，不做任何外部操作。
        exit 0
        """
        try script.write(to: tool, atomically: true, encoding: .utf8) // 只写本夹具。
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path) // 使测试脚本可执行。
        let served = expectation(description: "控制消息与清理完成") // 用真实结束事件而非固定等待断言。
        let sps = Data([0, 0, 0, 1, 0x67, 0x42, 0, 0x1f]) // 已知 Annex-B 配置载荷。
        let keyFrame = Data([0, 0, 0, 1, 0x65, 0x88]) // 以 IDR 的 NAL 头模拟首个媒体包。
        let keyFrameTime: UInt64 = 16_667 // 设备微秒值应经过会话原样交付。
        DispatchQueue.global().async { // 真正的两路 socket 握手在后台。
            defer { served.fulfill() } // 失败也结束 XCTest 等待。
            do {
                let video = try listener.acceptConnection() // 视频通道先连接。
                defer { Darwin.close(video) } // 服务端先后都清理。
                try listener.write(Data([0]), to: video) // dummy 必须在控制通道 accept 前发送。
                let control = try listener.acceptConnection() // 独立控制通道，不能误接在视频流中。
                defer { Darwin.close(control) } // 不泄漏测试端描述符。
                var name = Data("Fixture Phone".utf8); name.append(Data(repeating: 0, count: 64 - name.count)) // 固定六十四字节设备名称。
                let metadata = Data([0x80, 0, 0, 0, 0, 0, 2, 208, 0, 0, 6, 64]) // 物理 1080×2400，视频 720×1600。
                try listener.write(name + Data("h264".utf8) + metadata, to: video) // 发送真实 5.0.1 握手布局。
                try listener.write(Data([0x40, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8]) + sps, to: video) // 原样交付配置帧。
                let keyFrameHeader = AndroidWire.integer(keyFrameTime | (UInt64(1) << 61)) + AndroidWire.integer(UInt32(keyFrame.count))
                try listener.write(keyFrameHeader + keyFrame, to: video) // 配置包和关键帧连续到达。
                let keys = try listener.read(28, from: control) // Home 键 down/up 各十四字节。
                XCTAssertEqual(Array(keys.prefix(6)), [0, 0, 0, 0, 0, 3]) // 使用 Android HOME 3，而不是鸿蒙 HOME 1。
                XCTAssertEqual(Array(keys.dropFirst(14).prefix(6)), [0, 1, 0, 0, 0, 3]) // 完整抬起事件。
                let touch = try listener.read(32, from: control) // 触控携带位置和编码屏幕尺寸。
                XCTAssertEqual(Array(touch[10..<22]), [0, 0, 1, 104, 0, 0, 3, 32, 2, 208, 6, 64]) // 物理 (540,1200) 映射编码 (360,800)。
                let scroll = try listener.read(21, from: control) // 滚轮是独立协议消息。
                XCTAssertEqual(scroll[0], 3) // 不伪造触摸。
                XCTAssertEqual(Array(scroll[15..<17]), [0xf8, 0]) // -1 步的垂直轴定点值。
                let wake = try listener.read(4, from: control) // 右键由设备决定返回还是唤醒。
                XCTAssertEqual(wake, Data([4, 0, 4, 1])) // 独立于物理电源键。
                let rotation = try listener.read(1, from: control) // 同一旋转菜单。
                XCTAssertEqual(rotation, Data([11])) // 设备切换方向。
                let paste = try listener.read(20, from: control) // UTF-8 中文通过剪贴板发送。
                XCTAssertEqual(Array(paste.prefix(1)), [9]) // SET_CLIPBOARD，不能走只支持键盘字符的 input text。
                XCTAssertEqual(String(decoding: paste.suffix(6), as: UTF8.self), "中文") // 不截断多字节字符。
                XCTAssertEqual(try listener.read(2, from: control), Data([8, 0])) // 仅读取用户主动请求的设备剪贴板。
                try listener.write(Data([0, 0, 0, 0, 6]) + Data("已复制".utf8.prefix(6)), to: control) // 回应真实 UTF-8 文本“已复”。
                var byte: UInt8 = 0 // 确认停止实际关闭了通道，而非只修改 UI。
                XCTAssertEqual(Darwin.recv(control, &byte, 1, 0), 0) // EOF 表示清理完成。
            } catch { XCTFail("回环设备失败：\(error.localizedDescription)") } // 不吞掉假设备的断言或错误。
        }
        let attempt = ConnectionAttempt() // 与生产工作队列相同的取消语义。
        let session = try AndroidMirrorSession.open(device: AndroidDevice(serial: "fixture", state: "device", model: "Fallback"), directory: folder, frameRate: 30, bitrate: 8, scale: 0.75, autoQuality: false, attempt: attempt) { _ in } // 不访问真实手机。
        XCTAssertEqual(session.model, "Fixture Phone") // 标题读取设备协议提供的型号。
        XCTAssertEqual(session.deviceSize, CGSize(width: 1080, height: 2400)) // 窗口比例与物理坐标模型保留原尺寸。
        let receivedConfig = expectation(description: "先交付配置包")
        let receivedKeyFrame = expectation(description: "再交付带时间戳的关键帧")
        session.onFrame = { packet in
            if packet.timing == nil {
                XCTAssertEqual(packet.accessUnit, sps) // 包头不混入视频数据。
                receivedConfig.fulfill()
            } else {
                XCTAssertEqual(packet.accessUnit, keyFrame)
                XCTAssertEqual(packet.timing, .init(presentationTimeUs: Int64(keyFrameTime), isKeyFrame: true))
                receivedKeyFrame.fulfill()
            }
        }
        session.start() // 模拟 DeviceController 安装完回调后启动。
        wait(for: [receivedConfig, receivedKeyFrame], timeout: 3, enforceOrder: true)
        session.pressKey(KeyMap.home) // 标题桌面与中键走同一个协议入口。
        session.touch(.down, x: 540, y: 1200) // 验证缩放后的点击位置。
        XCTAssertTrue(session.scroll(x: 540, y: 1200, steps: -1)) // 滚轮直接使用控制通道。
        try session.backOrWake() // 右键使用官方语义。
        session.rotate(horizontal: true) // 原生菜单请求设备旋转。
        session.sendText("中文", x: 0, y: 0) // 用户粘贴文本不限 ASCII。
        XCTAssertEqual(session.deviceClipboardText(), "已复") // 响应来自当前请求，不是旧缓存。
        session.stop() // 真实释放进程、转发和临时文件。
        session.stop() // 重复清理必须无副作用。
        wait(for: [served], timeout: 5) // 确认远端观察到 EOF。
        let commands = try String(contentsOf: trace, encoding: .utf8) // 核查生产 ADB 参数。
        XCTAssertEqual(commands.components(separatedBy: "fixture|forward|--remove").count, 2) // 只清理自己一次。
        XCTAssertTrue(commands.contains("fixture|shell|rm -f '/data/local/tmp/hosmirror-")) // 只删除本会话自己的文件。
        XCTAssertFalse(commands.contains("kill-server")) // 共享服务不被停止。
    }

    func testPackageAndDirectoryRulesFollowTheSelectedDevice() throws { // 一套文件面板，按系统识别安装包。
        let apk = URL(fileURLWithPath: "/tmp/测试.APK") // 扩展名不区分大小写。
        XCTAssertEqual(FileDeliveryKind.classify(apk, platform: .android), .package) // Android 安装 APK。
        XCTAssertEqual(FileDeliveryKind.classify(apk, platform: .harmony), .unsupportedPackage) // 不交给鸿蒙安装器。
        XCTAssertEqual(try AndroidFileDelivery.directoryURI("/sdcard/Download/HosMirror"), "content://com.android.externalstorage.documents/document/primary%3ADownload%2FHosMirror") // 在手机打开同一个用户可见目录。
        XCTAssertThrowsError(try AndroidFileDelivery.directoryURI("/data/local/tmp")) // 不把私有路径当作公共目录。
        XCTAssertNotEqual(DevicePlatform.android.identifier(serial: "same"), DevicePlatform.harmony.identifier(serial: "same")) // 不会串用窗口或命令。
    }

    func testAPKIdentityComesFromBinaryManifestAndRejectsConcatenatedEntries() throws { // 安装后的启动身份不能由文件名或伪造第二份声明决定。
        func u16(_ value: UInt16) -> Data { var little = value.littleEndian; return withUnsafeBytes(of: &little) { Data($0) } } // AXML 十六位字段。
        func u32(_ value: UInt32) -> Data { var little = value.littleEndian; return withUnsafeBytes(of: &little) { Data($0) } } // AXML 三十二位字段。
        var payload = Data(), offsets = Data() // 独立构建标准 UTF-8 字符串池。
        for word in ["manifest", "package", "com.example.fixture"] { // 只提供解析包名所需的最小元素。
            offsets += u32(UInt32(payload.count)) // 偏移相对于字符串数据区。
            payload += Data([UInt8(word.utf16.count), UInt8(word.utf8.count)]) + Data(word.utf8) + Data([0]) // 两个长度、UTF-8 和零结尾。
        }
        while payload.count % 4 != 0 { payload.append(0) } // 对齐到 AXML chunk 边界。
        func joined(_ parts: [Data]) -> Data { parts.reduce(into: Data()) { $0.append($1) } } // 显式限定字段类型，避免较旧 Swift 编译器对长串加法的重载推断超时。
        let stringPool = joined([u16(1), u16(28), u32(UInt32(40 + payload.count)), u32(3), u32(0), u32(0x100), u32(40), u32(0), offsets, payload]) // 标准 RES_STRING_POOL。
        let node = joined([u16(0x102), u16(16), u32(56), u32(1), u32(.max)]) // 标准起始元素 chunk。
        let fields = joined([u32(.max), u32(0), u16(20), u16(20), u16(1), u16(0), u16(0), u16(0)]) // manifest 元素与一条属性。
        let attribute = joined([u32(.max), u32(1), u32(2), u16(8), Data([0, 3]), u32(2)]) // package 的原始及 typed string 均指向索引 2。
        let manifest = joined([u16(3), u16(8), u32(UInt32(8 + stringPool.count + node.count + fields.count + attribute.count)), stringPool, node, fields, attribute]) // 完整文档长度。
        XCTAssertEqual(try APKManifest.packageName(data: manifest), "com.example.fixture") // 必须使用包自身声明。
        XCTAssertThrowsError(try APKManifest.packageName(data: manifest + manifest)) // 不接受拼接或重复的 manifest。
        XCTAssertThrowsError(try APKManifest.packageName(data: Data(manifest.dropLast()))) // 不接受截断属性。
    }
}

private final class AndroidLoopback: @unchecked Sendable { // 只有测试后台线程接受连接。
    private let fd: Int32 // 监听描述符归夹具所有。
    let port: UInt16 // 系统分配，避免抢占已有服务。
    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0) // 仅回环 TCP。
        fd = descriptor // 监听描述符固定。
        guard descriptor >= 0 else { throw HdcError("无法创建回环夹具") } // 失败必须报告。
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1") // 不监听公网。
        let status = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } // 端口零由内核自动分配。
        guard status == 0, listen(fd, 2) == 0 else { Darwin.close(fd); throw HdcError("无法监听回环夹具") } // 沙盒限制不能假装通过。
        var length = socklen_t(MemoryLayout<sockaddr_in>.size) // 接收系统分配地址。
        let result = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } } // 读取准确端口。
        guard result == 0 else { Darwin.close(fd); throw HdcError("无法取得回环端口") } // 不猜测端口号。
        port = UInt16(bigEndian: address.sin_port) // 回到主机字节序。
    }
    deinit { Darwin.close(fd) } // 不影响其他监听器。
    func acceptConnection() throws -> Int32 {
        var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0) // 不能无限等待失败的客户端。
        guard poll(&event, 1, 6000) > 0 else { throw HdcError("夹具等待连接超时") } // 启动回归要有明确失败。
        let connection = accept(fd, nil, nil) // 接收隔离客户端。
        guard connection >= 0 else { throw HdcError("夹具连接失败") } // 不返回无效描述符。
        var timeout = timeval(tv_sec: 6, tv_usec: 0) // 消息缺失不能卡住测试。
        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) // 限时读取。
        var yes: Int32 = 1 // 测试失败关闭时不能触发 SIGPIPE。
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) // 保留真实失败信息。
        return connection // 调用者负责关闭。
    }
    func read(_ count: Int, from socket: Int32) throws -> Data {
        var bytes = Data(count: count); var offset = 0 // TCP 可能拆分字段。
        while offset < count {
            let amount = bytes.withUnsafeMutableBytes { Darwin.recv(socket, $0.baseAddress!.advanced(by: offset), count - offset, 0) } // 明确读取剩余字节。
            guard amount > 0 else { throw HdcError("夹具未收到完整消息") } // EOF 或超时都失败。
            offset += amount // 下一段继续读取。
        }
        return bytes // 用于核对协议字节。
    }
    func write(_ bytes: Data, to socket: Int32) throws {
        var offset = 0 // 处理部分发送。
        while offset < bytes.count {
            let amount = bytes.withUnsafeBytes { Darwin.send(socket, $0.baseAddress!.advanced(by: offset), bytes.count - offset, 0) } // 真正写入测试连接。
            guard amount > 0 else { throw HdcError("夹具发送失败") } // 不假设一定写入成功。
            offset += amount // 继续发送剩余数据。
        }
    }
}
