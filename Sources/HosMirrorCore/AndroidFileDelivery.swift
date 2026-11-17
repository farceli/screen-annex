import Foundation // 文件和 APK 使用与鸿蒙相同的排队、进度与结果模型。

public protocol FileDelivering: Sendable { // UI 只依赖统一交付能力。
    func deliverAndOpen(local: URL, directory: String, serial: String, attempt: ConnectionAttempt, progress: @escaping (FileDeliveryProgress) -> Void) throws -> FileDeliveryOutcome // 成功与自动打开失败分开返回。
}
extension FileDelivery: FileDelivering {} // 原有鸿蒙实现保持原样。

public final class AndroidFileDelivery: FileDelivering {
    private let adb: Adb // 与设备发现和 scrcpy 启动共用 ADB 查找规则。
    public init(directory: URL = AndroidRuntime.directory) { adb = Adb(directory: directory) } // 可注入隔离替身。
    @discardableResult
    private func shell(_ command: String, serial: String, timeout: TimeInterval = 15, attempt: ConnectionAttempt? = nil) throws -> String { // ADB shell v2 传回设备命令退出码。
        try adb.run(["-s", serial, "shell", command], timeout: timeout, attempt: attempt) // 所有动态路径均由调用处 quote。
    }
    public func deliverAndOpen(local: URL, directory: String, serial: String, attempt: ConnectionAttempt, progress: @escaping (FileDeliveryProgress) -> Void) throws -> FileDeliveryOutcome {
        try attempt.checkCancellation() // 排队期间取消不会访问手机。
        progress(.preparing) // 对应真实文件检查。
        let kind = FileDeliveryKind.classify(local, platform: .android) // Android 只安装 APK，不把 HAP 当作普通文件。
        guard kind != .unsupportedPackage else { throw HdcError("当前设备仅支持安装 .apk，暂不支持 .\(local.pathExtension)") } // 不默默改变安装意图。
        let values = try local.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) // 先检查拖入文件的类型和大小。
        guard values.isRegularFile == true, FileManager.default.isReadableFile(atPath: local.path),
              let size = values.fileSize else { throw HdcError("请拖入可读取的普通文件，暂不支持文件夹") } // 与鸿蒙采用相同的文件检查。
        let total = Int64(size) // 空文件同样需要校验大小。
        guard local.lastPathComponent.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { throw HdcError("文件名不能包含换行或控制字符") } // 避免设备工具对这些字符解析不一致。
        let folder = kind == .package ? "/data/local/tmp" : try FileDelivery.validateDirectory(directory) // 安装中转与用户下载目录分离。
        let token = UUID().uuidString // 本任务独占中转名。
        let staging = folder + "/.hosmirror-" + token + (kind == .package ? ".apk" : ".part") // 不直接覆盖用户目标文件。
        var destination = folder + "/" + local.lastPathComponent // 默认保留原名。
        try shell("mkdir -p \(FileDelivery.quote(folder))", serial: serial, attempt: attempt) // 确认目录可用后才发送。
        if kind == .file, try shell("if [ -e \(FileDelivery.quote(destination)) ] || [ -L \(FileDelivery.quote(destination)) ]; then printf yes; fi", serial: serial, attempt: attempt).trimmingCharacters(in: .whitespacesAndNewlines) == "yes" {
            let ext = local.pathExtension.isEmpty ? "" : "." + local.pathExtension // 冲突时保留扩展名。
            destination = folder + "/" + local.deletingPathExtension().lastPathComponent + " (" + token.prefix(8) + ")" + ext // 与鸿蒙一样另存、不覆盖。
        }
        defer { _ = try? shell("rm -f \(FileDelivery.quote(staging))", serial: serial, timeout: 5) } // 成功、失败和取消后只清理本任务中转文件。
        var lastBytes: Int64? // 进度采样不会因为迟到的查询回退。
        progress(.sending(completed: nil, total: total)) // 不以时间猜测比例。
        try adb.run(["-s", serial, "push", local.path, staging], timeout: 3600, attempt: attempt) { // 传输在文件专用后台队列中可取消。
            if let value = try? self.shell("stat -c %s \(FileDelivery.quote(staging))", serial: serial, timeout: 3, attempt: attempt),
               let bytes = Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)), bytes >= 0, bytes <= total, bytes != lastBytes {
                lastBytes = max(lastBytes ?? 0, bytes) // 仅发布手机实际已写入字节。
                progress(.sending(completed: lastBytes, total: total))
            }
        }
        let received = try shell("stat -c %s \(FileDelivery.quote(staging))", serial: serial, attempt: attempt).trimmingCharacters(in: .whitespacesAndNewlines) // 结束后独立核验手机文件大小。
        guard Int64(received) == total else { throw HdcError("文件大小校验失败：本地 \(total) 字节，手机 \(received) 字节") } // 传输成功字符串不能替代数据校验。
        try attempt.checkCancellation() // 取消后不能继续安装或发布。
        if kind == .package {
            progress(.installing) // 只有完整 APK 已到手机才进入安装。
            // -r 原位覆盖，-d 请求系统允许降级，最终结果由设备包管理器决定。
            let result = try shell("pm install -r -d \(FileDelivery.quote(staging))", serial: serial, timeout: 600, attempt: attempt)
            guard result.split(whereSeparator: \.isNewline).contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "Success" }) else { throw HdcError(result) } // 非零和正文失败都不能报告成功。
        } else {
            progress(.finishing) // 文件完整后才发布最终名字。
            let source = FileDelivery.quote(staging) // 远端 shell 按字面路径处理。
            let target = FileDelivery.quote(destination) // 保留中文、空格、引号等文件名。
            try shell("test ! -d \(target) && mv -n \(source) \(target) && test ! -e \(source) && test -f \(target)", serial: serial, attempt: attempt) // 确认最终文件就位且同名文件未被覆盖。
            let mediaURI = URL(fileURLWithPath: destination).absoluteString // 将路径编码为单个媒体扫描 URI。
            _ = try? shell("am broadcast --user current -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d \(FileDelivery.quote(mediaURI))", serial: serial, timeout: 5, attempt: attempt) // 保留 scrcpy 原有的媒体索引行为。
        }
        progress(.opening) // 已成功任务的自动打开单独计状态。
        do {
            if kind == .package {
                let package = try APKManifest.packageName(in: local, attempt: attempt) // 仅在已安装后读取自身真实包名，解析失败只影响自动打开。
                let resolved = try shell("cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER \(FileDelivery.quote(package))", serial: serial, attempt: attempt) // 只解析这次 APK 的桌面入口。
                guard let component = resolved.split(whereSeparator: \.isNewline).last.map(String.init), component.hasPrefix(package + "/"), !component.contains(where: \.isWhitespace) else { throw HdcError("应用已安装，但没有可自动打开的桌面入口") } // 不启动其他包或猜测活动名。
                let result = try shell("am start --user current -n \(FileDelivery.quote(component))", serial: serial, attempt: attempt) // 在当前用户空间打开对应应用。
                try Self.requireStarted(result) // 正文中的错误也视为打开失败。
            } else {
                let path = try Self.directoryURI(folder) // 根据实际成功目录生成标准文档 URI。
                let picker = try shell("cmd package resolve-activity --brief --user current -a android.intent.action.OPEN_DOCUMENT_TREE", serial: serial, attempt: attempt) // 通过系统文档选择器确定文件管理器的包名。
                guard let component = Self.resolvedComponent(picker) else { throw HdcError("手机没有可用的系统文件管理器") } // 不把目录交给第三方分享应用或系统选择弹窗。
                let package = String(component.prefix(while: { $0 != "/" })) // 同一文件管理器可能用不同活动显示目录。
                let request = "-a android.intent.action.VIEW -p \(FileDelivery.quote(package)) -d \(FileDelivery.quote(path)) -t vnd.android.document/directory" // 只匹配系统文档应用的目录查看入口。
                let resolved = try shell("cmd package resolve-activity --brief --user current \(request)", serial: serial, attempt: attempt) // 验证当前 ROM 对该目录 URI 的支持。
                guard let viewer = Self.resolvedComponent(resolved), viewer.hasPrefix(package + "/") else { throw HdcError("手机的文件管理器暂不支持直接打开此目录") } // 保留发送成功与实际路径。
                let result = try shell("am start --user current \(request) --grant-read-uri-permission", serial: serial, attempt: attempt) // 避免其他声明通配类型的应用接收文件 URI。
                try Self.requireStarted(result) // 设备启动失败时在传输记录保留原因。
            }
            return FileDeliveryOutcome(destination: kind == .package ? nil : destination) // 两个平台采用相同结果模型。
        } catch { return FileDeliveryOutcome(destination: kind == .package ? nil : destination, openingError: error.localizedDescription) } // 自动打开失败不推翻已经成功的安装或发送。
    }
    public static func directoryURI(_ folder: String) throws -> String { // Android 公共下载目录使用 DocumentsProvider。
        let validated = try FileDelivery.validateDirectory(folder) // 不接受相对路径和 ..。
        let relative: String // primary 卷不硬编码用户数字 ID。
        if validated.hasPrefix("/sdcard/") { relative = String(validated.dropFirst(8)) } // 常用公共存储别名。
        else if validated.hasPrefix("/storage/emulated/0/") { relative = String(validated.dropFirst(20)) } // 同一公共存储的规范路径。
        else { throw HdcError("文件已保存，但该目录不属于可打开的公共存储区") } // 私有目录不能伪造公共文档链接。
        let encoded = ("primary:" + relative).addingPercentEncoding(withAllowedCharacters: .alphanumerics) // 把斜线、中文和冒号作为单个文档 ID 编码。
        guard let encoded else { throw HdcError("无法生成手机目录地址") } // 不拼接未编码路径。
        return "content://com.android.externalstorage.documents/document/" + encoded // 标准外部存储 DocumentsProvider。
    }
    private static func requireStarted(_ value: String) throws { // am 可能零退出但在正文报告错误。
        guard value.contains("Starting:"), !value.lowercased().contains("error:") else { throw HdcError(value.isEmpty ? "手机未确认打开成功" : value) } // 保留真实系统错误。
    }

    private static func resolvedComponent(_ output: String) -> String? { // 解析包管理器 --brief 返回的末行组件。
        guard let line = output.split(whereSeparator: \.isNewline).last, !line.contains(where: \.isWhitespace),
              line.split(separator: "/").count == 2, !line.hasPrefix("android/") else { return nil } // 跳过系统选择器、错误文案和空结果。
        return String(line) // 原样用于确定应用包名。
    }
}
