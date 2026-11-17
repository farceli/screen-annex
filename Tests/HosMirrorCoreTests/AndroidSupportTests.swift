import XCTest // 使用现有 XCTest 测试目标，无需真机或系统 ADB 服务。
@testable import HosMirrorCore // 测试真实生产解析器、地址验证和参数构造。

final class AndroidSupportTests: XCTestCase {
    func testDiscoveryPreservesAuthorizationAndDeduplicatesDevices() { // 未授权不能误报成连接成功。
        let devices = AndroidDevice.parse("""
            List of devices attached\r
            * daemon started successfully
            ready\tdevice usb:123 product:test model:Pixel_9 transport_id:1
            locked\tunauthorized
            off\toffline
            ready\tdevice model:duplicate
            adb: transport error
            192.0.2.8:5555\tdevice model:Wireless
            adb-test._adb-tls-connect._tcp.\tdevice model:Paired
            """)
        XCTAssertEqual(devices.map(\.serial), ["ready", "locked", "off", "192.0.2.8:5555", "adb-test._adb-tls-connect._tcp."])
        XCTAssertEqual(devices.map(\.transport), [.usb, nil, nil, .wireless, .wireless])
        XCTAssertEqual(devices[0].model, "Pixel 9") // 型号下划线转换为空格。
        XCTAssertTrue(devices[0].canConnect) // 已授权设备才允许启动。
        XCTAssertFalse(devices[1].canConnect) // 用户必须在手机确认授权。
        XCTAssertFalse(devices[2].canConnect) // 离线设备不得启动。
        XCTAssertTrue(devices[1].statusText.contains("允许 USB 调试")) // 提供用户可以执行的下一步。
    }

    func testWirelessInputRejectsMalformedPortsAndCommandText() throws { // 地址校验不接受任意命令文本。
        XCTAssertEqual(try Adb.validateAddress(" 192.168.1.2:37891 "), "192.168.1.2:37891") // 接受手机给出的动态端口。
        XCTAssertEqual(try Adb.validateAddress("[fe80::1]:5555"), "[fe80::1]:5555") // 支持方括号 IPv6。
        for value in ["", "host", "host:0", "host:65536", "-bad:5555", "a b:5555", "host:5555;touch /tmp/unsafe", "host\nother:5555"] { // 覆盖错误端口、选项和 shell 文本。
            XCTAssertThrowsError(try Adb.validateAddress(value), value) // 错误发生在启动任何外部程序之前。
        }
    }

    func testLaunchBindsSerialAndOverridesInheritedExternalTools() {
        let serial = "odd ; --no-control" // 即使输入包含选项样式文本也只能作为单个值。
        let arguments = AndroidRuntime.arguments(serial: serial, title: "手机 A", fps: 60, bitrate: 16, maxSize: 1920, onTop: true) // 使用与真实启动相同的构造器。
        XCTAssertEqual(arguments[0], "--serial=\(serial)") // 不经 shell，不拆分序列号。
        XCTAssertTrue(arguments.contains("--window-title=手机 A")) // 带空格标题保持单个参数。
        XCTAssertTrue(arguments.contains("--max-size=1920")) // 画质选项确实传给上游。
        XCTAssertTrue(arguments.contains("--always-on-top")) // 保留用户置顶偏好。
        let directory = URL(fileURLWithPath: "/tmp/HosMirror with spaces") // 覆盖路径包含空格的安装位置。
        let environment = AndroidRuntime.environment(directory: directory, inherited: ["HOSMIRROR_ADB": "/sdk with spaces/adb", "ADB": "/external/adb", "SCRCPY_SERVER_PATH": "/external/server", "PATH": "/bin"]) // 模拟显式设置和继承的外部工具值。
        XCTAssertEqual(environment["ADB"], "/sdk with spaces/adb") // 将明确选择的 Platform Tools 路径传给 scrcpy。
        XCTAssertEqual(environment["SCRCPY_SERVER_PATH"], directory.appendingPathComponent("scrcpy-server").path) // client/server 不混用版本。
        XCTAssertEqual(environment["PATH"], "/bin") // 不修改系统环境或调用者进程。
    }

    func testAdbZeroExitFailuresAndDisplayOverride() throws { // ADB 的失败文案可能伴随零退出码。
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) // 所有设备工具均为隔离替身。
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // 不触碰真实 ADB 或设备。
        defer { try? FileManager.default.removeItem(at: root) } // 测试成功和失败均清理。
        let binary = root.appendingPathComponent("adb") // 路径与生产代码完全一致。
        let script = """
        #!/bin/sh
        # 按真实 ADB 参数返回受控结果，不执行设备或网络操作。
        case "$1" in
          connect) echo 'failed to connect: connection refused' ;; # 零退出码也必须视为失败。
          pair) echo 'Failed: wrong password' ;; # 错误配对码不能被当作配对成功。
          -s) printf 'Physical size: 1080x2400\\nOverride size: 720x1600\\n' ;; # 有覆盖尺寸时使用最后一项。
        esac
        """ // 每个分支只产生文本，不访问真实设备。
        try script.write(to: binary, atomically: true, encoding: .utf8) // 创建独占替身。
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path) // 仅测试文件获得执行权限。
        let adb = Adb(directory: root) // 生产调用器直接运行替身，无需模拟其内部实现。
        XCTAssertThrowsError(try adb.connect("127.0.0.1:5555")) // 不能只看进程退出码。
        XCTAssertThrowsError(try adb.pair("127.0.0.1:5555", code: "123456")) // 错误配对必须可见。
        XCTAssertThrowsError(try adb.pair("127.0.0.1:5555", code: "12a456")) // 错误格式在启动前拒绝。
        XCTAssertEqual(try adb.longEdge(serial: "fixture"), 1600) // Override size 优先于物理尺寸。
    }
}
