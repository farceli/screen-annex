import XCTest
@testable import HosMirrorCore

/// 回归验证取消、重连和输入的实际执行顺序，不依赖设备或本地 TCP 端口。
final class SessionLifecycleTests: XCTestCase {
    private final class Events {
        private let lock = NSLock() // 测试与工作队列共享日志，必须同步。
        private var entries: [String] = [] // 保存可断言的资源操作轨迹。
        func add(_ entry: String) {
            lock.lock() // 避免并发 append。
            entries.append(entry)
            lock.unlock()
        }
        var snapshot: [String] {
            lock.lock() // 在同一把锁下获取一致快照。
            defer { lock.unlock() }
            return entries
        }
    }

    private final class Resource: SessionResource {
        let name: String // 标识具体哪一次连接。
        let events: Events // 与测试共享可观察操作。
        init(_ name: String, events: Events) { self.name = name; self.events = events }
        func stop() { events.add("stop-\(name)") } // 重复 stop 会在断言中暴露出来。
    }

    func testCancelledQueuedConnectionNeverCreatesResource() {
        let worker = SessionWorker<Resource>() // 使用生产代码的串行工作队列。
        let attempt = ConnectionAttempt()
        attempt.cancel() // 模拟窗口在任务真正执行之前关闭。
        let finished = expectation(description: "cancelled completion")
        worker.start(attempt: attempt, create: {
            XCTFail("cancelled attempt accessed the device") // 已取消的任务不得执行工厂函数。
            return Resource("unexpected", events: Events())
        }, completion: { result in
            if case .failure(let error) = result { XCTAssertTrue(error is CancellationError) }
            else { XCTFail("cancelled connection adopted") }
            finished.fulfill() // 即使取消也要完成调用方的等待。
        })
        wait(for: [finished], timeout: 2) // 给调度器留出时间，但不依赖 sleep。
    }

    func testCancellationDuringStartupCleansBeforeReplacementAndDropsStaleInput() {
        let worker = SessionWorker<Resource>()
        let events = Events()
        let first = ConnectionAttempt()
        let second = ConnectionAttempt()
        let entered = DispatchSemaphore(value: 0) // 通知主测试：旧 bootstrap 已经开始。
        let resume = DispatchSemaphore(value: 0) // 精确控制旧 bootstrap 何时返回。
        let cancelled = expectation(description: "first cancelled")
        let replaced = expectation(description: "second active")
        let drained = expectation(description: "queue drained")
        worker.start(attempt: first, create: {
            events.add("create-first")
            entered.signal() // 让测试在连接过程中取消。
            XCTAssertEqual(resume.wait(timeout: .now() + 2), .success)
            return Resource("first", events: events)
        }, completion: { result in
            if case .failure(let error) = result { XCTAssertTrue(error is CancellationError) }
            else { XCTFail("stale resource adopted") }
            cancelled.fulfill()
        })
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        first.cancel() // 模拟用户关闭窗口后立即再次打开。
        worker.start(attempt: second, create: {
            events.add("create-second")
            return Resource("second", events: events)
        }, completion: { _ in replaced.fulfill() })
        worker.perform(attempt: first) { _ in events.add("stale-input") } // 旧连接的排队输入必须被丢弃。
        worker.perform(attempt: second) { _ in events.add("active-input") } // 新连接的输入正常执行。
        worker.stop() // 显式停止新资源。
        let barrier = ConnectionAttempt()
        barrier.cancel() // 再排一个不会访问设备的任务作为队列屏障。
        worker.start(attempt: barrier, create: { Resource("unexpected", events: events) }, completion: { _ in drained.fulfill() })
        resume.signal() // 允许旧 bootstrap 完成，验证取消后的回滚顺序。
        wait(for: [cancelled, replaced, drained], timeout: 3)
        XCTAssertEqual(events.snapshot, ["create-first", "stop-first", "create-second", "active-input", "stop-second"])
    }

    func testBootstrapCancelledBeforeDeviceAccess() throws {
        let attempt = ConnectionAttempt()
        attempt.cancel() // 在探测前取消。
        let bootstrapper = DeviceBootstrapper(hdc: Hdc(binary: URL(fileURLWithPath: "/nonexistent-hdc")), resources: URL(fileURLWithPath: "/nonexistent-resources"))
        XCTAssertThrowsError(try bootstrapper.bootstrap(serial: "test", attempt: attempt)) {
            XCTAssertTrue($0 is CancellationError) // 不应执行 hdc 并返回“找不到文件”。
        }
    }

    func testBootstrapRollsBackVideoForwardWhenControlForwardFails() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("devices"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("agents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) } // 测试不在仓库留下假组件。
        try Data().write(to: directory.appendingPathComponent("devices/libscrcpy_server_unix_6.5-device.z.so")) // 只验证资源生命周期。
        try Data().write(to: directory.appendingPathComponent("agents/uitest_agent_1.2.2.so"))
        let binary = directory.appendingPathComponent("fake-hdc")
        let script = """
        #!/bin/sh
        # 每次调用记入本地文件，不连接真实设备。
        printf '%s\\n' "$*" >> "$0.log"
        # 返回一台虚构设备及其系统参数。
        case "$*" in
          'list targets') echo 192.0.2.1:5555; exit 0 ;;
          *'echo __V__'*) printf '__V__\\n7.0.0.1\\n__MD__\\nTEST\\n__E__\\nNo such file\\n__M1__\\nmissing\\n__M2__\\nmissing\\n__S__\\n1216x2688 refreshRate=120\\n'; exit 0 ;;
          # 模拟旧版的 TCP 采集端和真机上省略前导零的 UNIX 控制端。
          *'grep -F'*'@scrcpy_grpc_socket'*) printf '__TCP__\\n  1: 00000000:1388 00000000:0000 0A 00000000:00000000 00:00000000 00000000 0 0 1234\\n'; exit 0 ;;
          *'grep -F'*'@uitest_socket'*) printf '__UNIX__\\n0: 00000002 0 10000 1 1 1234 @uitest_socket\\n'; exit 0 ;;
          # 两种控制转发都失败，触发已经成功的视频转发回滚。
          *'fport tcp:2222'*) echo '[Fail] Forward parament failed'; exit 0 ;;
        esac
        # 文件推送、视频转发和清理命令均模拟成功。
        exit 0
        """
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        var allocated = 0 // 固定端口注入避免测试需要 bind 权限。
        let bootstrapper = DeviceBootstrapper(hdc: Hdc(binary: binary), resources: directory, portAllocator: {
            allocated += 1
            return allocated == 1 ? 1111 : 2222 // 第二个端口由假 hdc 拒绝。
        })
        XCTAssertThrowsError(try bootstrapper.bootstrap(serial: "192.0.2.1:5555", frameRate: 15, bitRateMbps: 4, scale: 0.5)) // 模拟高刷设备经无线连接，控制转发仍按原规则失败。
        let calls = try String(contentsOf: binary.appendingPathExtension("log"), encoding: .utf8)
        XCTAssertTrue(calls.contains("-scale 2 -frameRate 15 -bitRate 4194304")) // 半分辨率要传设备识别的整数除数；无线连接不覆盖用户参数。
        XCTAssertTrue(calls.contains("fport tcp:1111 tcp:5000")) // 启动时直接选择已监听的旧版 TCP 端点。
        XCTAssertTrue(calls.contains("fport tcp:2222 localabstract:uitest_socket")) // 无前导零的 UNIX 标志也能识别。
        XCTAssertTrue(calls.contains("fport tcp:2222 tcp:8012")) // 零退出码的实际失败也尝试兼容转发。
        XCTAssertFalse(calls.contains("ps -ef")) // 采集端已经就绪，无需按旧流程检查守护进程。
        XCTAssertTrue(calls.contains("fport rm tcp:1111")) // 已成功的视频转发必须删除。
        XCTAssertEqual(calls.components(separatedBy: "pkill -9 -f singleness").count - 1, 2) // 启动前清理和失败回滚各一次。
    }
}
