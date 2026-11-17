import XCTest // 使用主机夹具验证实际生产传输流程，不连接手机。
@testable import HosMirrorCore // 测试文件分流、远端返回码和真实字节进度。

final class FileDeliveryTests: XCTestCase {
    private var root: URL! // 每项测试使用独立的假手机根目录。
    private var binary: URL! // 注入 FileDelivery 的假 hdc。
    private var delivery: FileDelivery! // 使用生产实现，不能用测试副本替代。

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("file-delivery-" + UUID().uuidString) // 路径不依赖用户数据。
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // 所有设备文件都映射在此目录。
        binary = root.appendingPathComponent("fake-hdc") // 替身只接受测试目标。
        let script = """
        #!/usr/bin/env python3
        import os, pathlib, subprocess, sys, time # 仅使用 Python 标准库模拟命令与手机存储。
        root = pathlib.Path(__file__).parent # 测试独占的虚拟根目录。
        args = sys.argv[1:] # Process.arguments 原样传入，验证空格与特殊字符不会拆分。
        assert args[:2] == ['-t', 'test'], args # 禁止夹具接触任何真实目标。
        with (root / 'calls').open('a') as log: log.write(repr(args) + '\\n') # 保存调用路径供安装与清理断言。
        if args[2] == 'shell': # 在本机执行生产生成的安全 shell 命令。
            command = args[3].replace('/phone', str(root / 'phone')).replace('/storage/media/100/local/files/Docs', str(root / 'phone')).replace('/data/local/tmp', str(root / 'staging')) # 重定向所有设备路径。
            command = command.replace('stat -c %s', 'stat -f %z') # macOS stat 的等价大小查询。
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH']) # bm 也只能找到本地替身。
            status = subprocess.call(['/bin/sh', '-c', command], env=env) # 保留远端标记协议的真实 shell 退出语义。
            if (root / 'late-stderr').exists(): # 模拟本地 stderr 晚于远端完成标记抵达。
                time.sleep(0.05); print('late diagnostic', file=sys.stderr, flush=True) # 诊断不能被当作退出码。
            sys.exit(status) # 无论是否有晚到诊断都保持真实进程状态。
        assert args[2:4] == ['file', 'send'], args # 不支持的设备命令立即失败。
        if (root / 'sendfail').exists(): # 模拟 hdc 退出为零但正文报告权限失败。
            print('[Fail] Permission denied [E005]') # 完整原因必须传到调用方。
            sys.exit(0) # 回归：不能仅依赖本地退出码。
        local, remote = pathlib.Path(args[4]), args[5] # 原文件名可能包含中文、空格和引号。
        remote = pathlib.Path(remote.replace('/phone', str(root / 'phone')).replace('/storage/media/100/local/files/Docs', str(root / 'phone')).replace('/data/local/tmp', str(root / 'staging'))) # 临时文件也必须在隔离根目录。
        if str(remote) == '/': remote = root # 虚拟手机根目录也必须映射到隔离路径。
        if local.is_dir(): # 模拟 hdc 原生目录发送，可在手机创建受 shell 限制的文档子目录。
            remote = remote / local.name / next(local.iterdir()).name # 目录封装中始终只有一个文件。
            local = next(local.iterdir()) # 保留原始字节作为本次发送内容。
            remote.parent.mkdir(parents=True, exist_ok=True) # hdc 创建目录不等同于 shell mkdir 的权限。
        data = local.read_bytes() # 保存原始字节，不对图片做重编码。
        if (root / 'badsize').exists(): data = data[:max(0, len(data) - 1)] # 模拟截断却报告成功。
        with remote.open('wb') as target: # 直接写生产指定的唯一中转路径。
            for start in range(0, len(data), 65536): # 分块写入，让生产轮询读到中间进度。
                target.write(data[start:start + 65536]); target.flush() # 文件大小变化可观察。
                if (root / 'slow').exists(): time.sleep(0.06) # 测试可控地延长传输，不生成虚假百分比。
        print('FileTransfer finish, Size:' + str(len(data)) + ', File count = 1') # 与 hdc 实际成功消息一致。
        """
        try executable(script, at: binary) // 写入可执行的假 hdc。
        let param = """
        #!/bin/sh
        # 默认模拟首次支持降级的 API，单个测试可改用旧固件。
        [ "$1" = get ] && [ "$2" = const.ohos.apiversion ] || exit 1
        if [ -f "$0.api" ]; then cat "$0.api"; else echo 23; fi
        """
        try executable(param, at: root.appendingPathComponent("param"))
        let bm = """
        #!/bin/sh
        # 安装失败与成功都由夹具控制，绝不触及系统包管理器。
        if [ "$1" = dump ]; then
          if [ "$3" = com.huawei.hmos.files ]; then cat "$0.files.json"; else cat "$0.json"; fi # 系统文件管理与被安装应用分别返回自己的包身份。
          exit 0 # 查询不能继续进入安装模拟。
        fi
        if [ -f "$0.fail" ]; then
          echo 'error: signature verification failed [9568257]' # 模拟手机返回的具体错误码。
          exit 1 # 远端非零退出，即使 hdc 本身退出为零也必须失败。
        fi
        echo 'Success' # 模拟 bm 的成功正文。
        """
        try executable(bm, at: root.appendingPathComponent("bm")) // PATH 只在夹具子进程内生效。
        let installed = #"{"name":"com.example.test","entryModuleName":"entry","hapModuleInfos":[{"moduleName":"entry","mainElementName":"LaunchPage","abilityInfos":[{"name":"LaunchPage","visible":true,"skills":[{"entities":["entity.system.home"]}]}]}]}"# // 不使用猜测的 EntryAbility。
        try installed.write(to: root.appendingPathComponent("bm.json"), atomically: true, encoding: .utf8) // 作为设备真实启动入口的替身。
        try installed.replacingOccurrences(of: "com.example.test", with: "com.huawei.hmos.files").write(to: root.appendingPathComponent("bm.files.json"), atomically: true, encoding: .utf8) // 文件管理也必须按实际声明启动。
        let aa = """
        #!/bin/sh
        # 只模拟启动确认，不打开主机或手机应用。
        if [ -f "$0.fail" ]; then echo 'error: failed to start ability. 10104001'; exit 0; fi
        echo 'start ability successfully.'
        """
        try executable(aa, at: root.appendingPathComponent("aa")) // 生产启动命令只会到达本地替身。
        delivery = FileDelivery(hdc: Hdc(binary: binary)) // 所有后续步骤均运行生产代码。
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root) // 移除所有本地源和虚拟设备文件。
    }

    private func executable(_ script: String, at url: URL) throws {
        try script.write(to: url, atomically: true, encoding: .utf8) // 保留可审查的脚本源码。
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) // 仅给本夹具执行权限。
    }

    private func file(_ name: String, size: Int = 100) throws -> URL {
        let url = root.appendingPathComponent(name) // 将输入也隔离到临时目录。
        try Data(repeating: 73, count: size).write(to: url) // 确定性内容方便逐字节比对。
        return url // 返回真实可读取的本地 URL。
    }

    private func send(_ url: URL, progress: @escaping (FileDeliveryProgress) -> Void = { _ in }) throws -> String? {
        try delivery.deliver(local: url, directory: "/phone/下载 空格'$(bad)", serial: "test", attempt: ConnectionAttempt(), progress: progress) // 特殊字符必须始终只是路径。
    }

    private var remoteFolder: URL { root.appendingPathComponent("phone/下载 空格'$(bad)") } // 映射手机保存目录。

    func testClassificationAndDirectoryValidation() throws {
        XCTAssertEqual(FileDeliveryKind.classify(URL(fileURLWithPath: "/a/包.HAP")), .package) // 支持大写鸿蒙扩展名。
        XCTAssertEqual(FileDeliveryKind.classify(URL(fileURLWithPath: "/a/photo.png")), .file) // 图片按普通文件分流。
        XCTAssertEqual(FileDeliveryKind.classify(URL(fileURLWithPath: "/a/test.apk")), .unsupportedPackage) // 不把 Android 包假报可安装。
        XCTAssertEqual(try FileDelivery.validateDirectory(" /phone//Download/ "), "/phone/Download") // 路径标准化。
        for invalid in ["relative", "/", "/phone/../tmp", "/phone/\nname"] {
            XCTAssertThrowsError(try FileDelivery.validateDirectory(invalid)) // 非法保存位置在设备 I/O 前被拒绝。
        }
    }

    func testCopiesSpecialFilenameAndPreservesExistingFile() throws {
        let local = try file("图片 ' $() ;.png") // 覆盖中文、空格、引号及 shell 元字符。
        let first = try XCTUnwrap(send(local)) // 首次保存保持原文件名。
        XCTAssertEqual(first, "/phone/下载 空格'$(bad)/" + local.lastPathComponent) // 返回完整真实手机路径。
        let second = try XCTUnwrap(send(local)) // 同名第二次不能覆盖第一次。
        XCTAssertNotEqual(first, second) // 冲突时生成独立文件名。
        let files = try FileManager.default.contentsOfDirectory(at: remoteFolder, includingPropertiesForKeys: nil) // 检查真实写出的目录内容。
        XCTAssertEqual(files.count, 2) // 没有多余临时中转文件。
        for output in files { XCTAssertEqual(try Data(contentsOf: output), try Data(contentsOf: local)) } // 图片字节完整保留。
    }

    func testRealByteProgressAndEmptyFile() throws {
        try Data().write(to: root.appendingPathComponent("slow")) // 让发送有足够时间报告中间字节。
        let local = try file("large.bin", size: 1_048_576) // 使用 1 MiB 固定内容。
        var bytes: [Int64] = [] // 回调运行在同步 deliver 所在测试线程。
        _ = try send(local) { if case .sending(let value?, _) = $0 { bytes.append(value) } } // 记录实际手机 stat 返回值。
        XCTAssertTrue(bytes.contains { $0 > 0 && $0 < 1_048_576 }) // 验证中间进度来自逐步落盘而非计时模拟。
        XCTAssertEqual(bytes, bytes.sorted()) // 已写字节不能倒退。
        XCTAssertNotNil(try send(file("empty.txt", size: 0))) // 空文件也能完成校验与保存。
    }

    func testZeroExitTransferFailureRetainsReasonAndCleansStaging() throws {
        try Data().write(to: root.appendingPathComponent("sendfail")) // 使 hdc 正文失败但进程成功退出。
        XCTAssertThrowsError(try send(file("a.txt"))) { XCTAssertTrue($0.localizedDescription.contains("Permission denied [E005]")) } // 精确保留用户需要的原因和错误码。
        XCTAssertFalse(FileManager.default.fileExists(atPath: remoteFolder.appendingPathComponent("a.txt").path)) // 未开始写入的失败不得留下文件。
    }

    func testSizeMismatchNeverPublishesSuccess() throws {
        try Data().write(to: root.appendingPathComponent("badsize")) // 发送少一个字节。
        XCTAssertThrowsError(try send(file("broken.txt"))) { XCTAssertTrue($0.localizedDescription.contains("大小校验失败")) } // hdc 成功消息不能跳过大小校验。
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: remoteFolder.path).isEmpty) // 残缺中转文件已清理。
    }

    func testPackageInstallSuccessAndSignatureFailure() throws {
        var stages: [FileDeliveryProgress] = [] // 记录真实发送到系统安装的阶段转换。
        XCTAssertNil(try send(file("signed.HAP")) { stages.append($0) }) // 大写扩展名也可进入系统安装流程。
        XCTAssertTrue(stages.contains(.installing)) // 必须先传输完成再安装。
        let calls = try String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8) // 查看实际执行的生产命令。
        XCTAssertTrue(calls.contains("bm install -r -d -p")) // 支持降级时默认请求覆盖和降级。
        try Data().write(to: root.appendingPathComponent("bm.fail")) // 第二次模拟签名不匹配。
        XCTAssertThrowsError(try send(file("bad.hap"))) { XCTAssertTrue($0.localizedDescription.contains("signature verification failed [9568257]")) } // 即使 hdc shell 零退出也能抓住系统失败。
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("staging").path).isEmpty) // 成功与失败都删除包中转文件。
    }

    func testPackageInstallOnOlderHarmonyOSStillReplaces() throws {
        try "22\n".write(to: root.appendingPathComponent("param.api"), atomically: true, encoding: .utf8)
        XCTAssertNil(try send(file("older-system.hap")))
        let calls = try String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8)
        XCTAssertTrue(calls.contains("bm install -r -p")) // 旧版 bm 仍使用其支持的覆盖参数。
        XCTAssertFalse(calls.contains("bm install -r -d"))
    }

    func testAndroidPackageInstallRequestsReplaceAndDowngrade() throws {
        let adb = """
        #!/bin/sh
        # 仅模拟本次 APK 的发送、大小校验、安装和清理。
        [ "$1" = -s ] && [ "$2" = test ] || exit 1
        if [ "$3" = push ]; then exit 0; fi
        [ "$3" = shell ] || exit 1
        case "$4" in
          'mkdir -p '*|'rm -f '*) exit 0 ;;
          'stat -c %s '*) echo 100 ;;
          'pm install -r -d '*) echo Success ;;
          *) exit 1 ;;
        esac
        """
        try executable(adb, at: root.appendingPathComponent("adb"))
        let local = try file("previous-version.APK")
        let result = try AndroidFileDelivery(directory: root).deliverAndOpen(
            local: local, directory: "/sdcard/Download/HosMirror", serial: "test", attempt: ConnectionAttempt(), progress: { _ in }
        )
        XCTAssertNil(result.destination) // 只有系统确认安装成功才返回已安装结果。
    }

    func testOnlyHapIsSupportedAndOtherPackagesNeverReachDevice() throws {
        for name in ["shared.hsp", "archive.app", "android.apk", "ios.ipa", "bundle.aab", "archive.XAPK"] {
            XCTAssertEqual(FileDeliveryKind.classify(URL(fileURLWithPath: name)), .unsupportedPackage) // 用户明确要求非 HAP 安装包均不支持。
            XCTAssertThrowsError(try send(file(name))) { XCTAssertTrue($0.localizedDescription.contains("仅支持安装 .hap")) } // 明确拒绝，不能回退为普通文件传输。
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("calls").path)) // 拒绝格式不执行任何设备命令。
        XCTAssertThrowsError(try send(root)) { XCTAssertTrue($0.localizedDescription.contains("文件夹")) } // 文件夹不会被误安装为应用。
    }

    func testFileSuccessAutomaticallyOpensPhoneDirectory() throws {
        let local = try file("saved.txt") // 普通文件使用真实生产发送流程。
        var states: [FileDeliveryProgress] = [] // 检查打开操作在主任务成功之后发生。
        let result = try delivery.deliverAndOpen(local: local, directory: FileDelivery.defaultDirectory, serial: "test", attempt: ConnectionAttempt()) { states.append($0) }
        XCTAssertNotNil(result.destination) // 保存位置仍然返回给提示与记录。
        XCTAssertNil(result.openingError) // 正常启动确认被识别。
        XCTAssertEqual(states.last, .opening) // 后续打开有独立阶段，不伪装为仍在发送。
        let calls = try String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8) // 验证真实执行的命令参数。
        XCTAssertTrue(calls.contains("filemanager://openDirectory")) // 打开系统文件管理目录。
        XCTAssertTrue(calls.contains("file://docs/storage/Users/currentUser/Download/HosMirror")) // 使用手机公共文档 URI，不能打开 Mac Finder。
    }

    func testHapSuccessOpensItsActualInstalledEntry() throws {
        let manifestFolder = root.appendingPathComponent("manifest", isDirectory: true) // 创建隔离 HAP 内容。
        try FileManager.default.createDirectory(at: manifestFolder, withIntermediateDirectories: true) // 不访问真实应用。
        let manifest = manifestFolder.appendingPathComponent("module.json") // Stage HAP 中的标准配置条目。
        try #"{"app":{"bundleName":"com.example.test"},"module":{"name":"feature"}}"#.write(to: manifest, atomically: true, encoding: .utf8) // 安装的是 feature 也应启动已安装应用的真正入口。
        let hap = root.appendingPathComponent("different-file-name.HAP") // 文件名不能代替应用包名。
        _ = try Hdc(binary: URL(fileURLWithPath: "/usr/bin/zip")).run(["-q", "-j", hap.path, manifest.path]) // 构造可读取 module.json 的真实 ZIP/HAP 文件。
        let result = try delivery.deliverAndOpen(local: hap, directory: "/phone", serial: "test", attempt: ConnectionAttempt()) { _ in }
        XCTAssertNil(result.destination) // 应用不返回普通文件目录。
        XCTAssertNil(result.openingError) // 启动成功有明确确认。
        let calls = try String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8) // 检查生产调用顺序与目标。
        XCTAssertTrue(calls.contains("bm dump -n")) // 必须查询本次包的已安装入口。
        XCTAssertTrue(calls.contains("com.example.test")) // 包名来自 HAP 元数据。
        XCTAssertTrue(calls.contains("LaunchPage")) // 使用设备声明的入口，而非硬编码 EntryAbility。
        XCTAssertFalse(calls.contains("-a EntryAbility")) // 不能误启动猜测的页面。
    }

    func testOpeningFailureKeepsSuccessfulTransferAndItsReason() throws {
        try Data().write(to: root.appendingPathComponent("aa.fail")) // aa 以零退出但正文报告失败。
        let result = try delivery.deliverAndOpen(local: file("saved.txt"), directory: FileDelivery.defaultDirectory, serial: "test", attempt: ConnectionAttempt()) { _ in }
        XCTAssertNotNil(result.destination) // 文件已经成功，不能改报发送失败。
        XCTAssertTrue(result.openingError?.contains("10104001") == true) // 自动打开错误码完整保留。
        let saved = root.appendingPathComponent("phone/Download/HosMirror/saved.txt") // 映射真实保存位置。
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path)) // 后续失败不能删除已经发送成功的文件。
    }

    func testDirectoryUriEncodingAndUnsupportedLocations() throws {
        let path = "/storage/media/101/local/files/Docs/Download/中文 空格#%/a.txt" // 覆盖多用户路径与 URI 特殊字符。
        let uri = try FileDelivery.directoryURI(containing: path) // 使用生产路径映射。
        let parsed = try XCTUnwrap(URLComponents(string: uri)) // 解码检查原始路径不被截断。
        XCTAssertEqual(parsed.host, "docs") // 使用文档服务 authority。
        XCTAssertEqual(parsed.path, "/storage/Users/currentUser/Download/中文 空格#%") // 正确定位文件的父目录。
        XCTAssertNil(parsed.fragment) // # 必须属于文件夹名，不能成为 URI 锚点。
        XCTAssertTrue(uri.contains("%23") && uri.contains("%25") && uri.contains("%20")) // 特殊字符严格编码。
        XCTAssertThrowsError(try FileDelivery.directoryURI(containing: "/data/local/tmp/a.txt")) // 不伪称系统文件管理器能够浏览受限临时目录。
    }

    func testInstalledEntryValidationRejectsAnotherBundleAndHiddenAbility() throws {
        let other = #"{"name":"other.bundle","hapModuleInfos":[]}"# // 模拟设备返回不匹配的应用信息。
        XCTAssertThrowsError(try InstalledApplication.resolve(bundle: "com.example.test", dump: other)) // 不允许打开另一个应用。
        let hidden = #"{"name":"com.example.test","hapModuleInfos":[{"moduleName":"entry","mainElementName":"Secret","abilityInfos":[{"name":"Secret","visible":false}]}]}"# // 私有页面不能用 aa 启动。
        XCTAssertThrowsError(try InstalledApplication.resolve(bundle: "com.example.test", dump: hidden)) // 不回退猜测入口。
    }

    func testFaEntryCanUseMainAbilityWhenStageNameIsEmpty() throws {
        let dump = #"{"name":"com.example.test","hapModuleInfos":[{"moduleName":"entry","mainElementName":"","mainAbility":"MainPage","abilityInfos":[{"name":"MainPage","visible":true}]}]}"# // 兼容空 Stage 字段与有效 FA 主页面。
        let target = try InstalledApplication.resolve(bundle: "com.example.test", dump: dump) // 不需要猜测 EntryAbility。
        XCTAssertEqual(target.ability, "MainPage") // 空字段不得遮住有效主入口。
    }

    func testLateStderrDoesNotCorruptRemoteExitStatus() throws {
        try Data().write(to: root.appendingPathComponent("late-stderr")) // 为这个测试打开晚到 stderr 模拟。
        let output = try delivery.checkedShell("printf confirmed", serial: "test") // 生产执行器必须识别真实零退出。
        XCTAssertTrue(output.contains("confirmed") && output.contains("late diagnostic")) // 退出确认与诊断内容都不能丢失。
        XCTAssertThrowsError(try delivery.checkedShell("echo actual-error; exit 7", serial: "test")) { XCTAssertTrue($0.localizedDescription.contains("actual-error")) } // 真正的非零退出仍然报错。
    }

    func testCancellationStopsProcessAndDoesNotPublishFile() throws {
        try Data().write(to: root.appendingPathComponent("slow")) // 延长发送，确保取消发生在过程中。
        let local = try file("cancel.bin", size: 2_097_152) // 不依赖外部大文件。
        let attempt = ConnectionAttempt() // 与生产取消按钮使用相同凭据。
        var cancelled = false // 同步进度回调内只取消一次。
        XCTAssertThrowsError(try delivery.deliver(local: local, directory: "/phone", serial: "test", attempt: attempt) { state in
            if case .sending(let bytes?, _) = state, bytes > 0, !cancelled {
                cancelled = true // 确认已经写入过部分内容。
                attempt.cancel() // 主动触发生产回收与清理路径。
            }
        }) { XCTAssertTrue($0 is CancellationError) } // 取消不能变成成功或超时。
        XCTAssertTrue(cancelled) // 防止测试在传输结束后才“取消”。
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("phone").path).isEmpty) // 不留下半截文件。
    }

    func testHdcTimeoutAndBothOutputPipes() throws {
        let hdc = Hdc(binary: URL(fileURLWithPath: "/bin/sh")) // 独立测试实际子进程管理。
        let started = Date() // 验证超时不会等待原始进程自然退出。
        XCTAssertThrowsError(try hdc.run(["-c", "exec sleep 5"], timeout: 0.1)) { XCTAssertTrue($0.localizedDescription.contains("超时")) } // 超时明确回报。
        XCTAssertLessThan(Date().timeIntervalSince(started), 2) // 卡死客户端被及时回收。
        let output = try hdc.run(["-c", "head -c 1048576 /dev/zero; head -c 1048576 /dev/zero >&2; echo END >&2"], timeout: 5) // 两个管道均超过系统缓冲大小。
        XCTAssertTrue(output.contains("END")) // 没有管道死锁，最后的诊断仍被保留。
    }
}
