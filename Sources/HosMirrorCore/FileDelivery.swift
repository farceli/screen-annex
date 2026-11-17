import Foundation // 提供本地文件信息、路径与 UUID。

/// 拖入文件的分流规则；HarmonyOS NEXT 不支持直接安装 APK/IPA。
public enum FileDeliveryKind: Equatable, Sendable {
    case file // 普通文件（包括图片）发送到配置目录。
    case package // 仅 HAP 文件交给系统包管理器安装。
    case unsupportedPackage // 其他安装包明确拒绝，不回退为普通文件发送。

    public static func classify(_ url: URL, platform: DevicePlatform = .harmony) -> Self { // 默认保持现有鸿蒙分类兼容。
        if url.pathExtension.lowercased() == platform.packageExtension { return .package } // 两个平台同样支持拖入本系统安装包。
        switch url.pathExtension.lowercased() { // 扩展名匹配不区分大小写。
        case "hap", "hsp", "app", "apk", "aab", "ipa", "apks", "xapk": return .unsupportedPackage // 非本系统安装包仍然明确拒绝。
        default: return .file // 图片无需特殊编码，按原文件传输。
        }
    }
}

/// UI 可显示真实字节比例；系统安装没有公开百分比时使用不定进度。
public enum FileDeliveryProgress: Equatable, Sendable {
    case preparing // 检查文件、创建目标目录。
    case sending(completed: Int64?, total: Int64) // nil 表示当前固件无法读取字节数。
    case installing // 文件发送完毕，等待系统安装结果。
    case finishing // 校验完成，正在保存最终文件名。
    case opening // 文件或 HAP 已成功，正在打开手机目录或应用。
}

/// 每次只处理一个文件；调用方在独立串行队列运行，不阻塞投屏输入。
public final class FileDelivery: Sendable { // 无共享可变状态，可安全移交独立传输队列。
    public static let defaultDirectory = "/storage/media/100/local/files/Docs/Download/HosMirror" // 手机“下载”内的独立目录。
    private let hdc: Hdc // 使用当前应用内置的工具版本。
    public init(hdc: Hdc) { self.hdc = hdc } // 测试可注入本地 hdc 替身。

    public static func validateDirectory(_ raw: String) throws -> String {
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines) // 忽略输入框两端空白。
        guard path.hasPrefix("/"), path != "/",
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !path.split(separator: "/").contains("..") else { // 禁止相对路径和上级跳转。
            throw HdcError("保存目录必须是手机上的绝对路径，不能为根目录或包含 ..、控制字符")
        }
        return "/" + path.split(separator: "/").joined(separator: "/") // 统一重复与末尾斜线。
    }

    public static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" // 始终按远端 shell 字面参数处理。
    }

    /// 同时检查远端退出码；hdc shell 自身退出为零不代表手机命令成功。
    @discardableResult
    public func checkedShell(_ command: String, serial: String, timeout: TimeInterval = 20,
                             attempt: ConnectionAttempt? = nil) throws -> String {
        let marker = "__HOSMIRROR_EXIT_" + UUID().uuidString.replacingOccurrences(of: "-", with: "") + "__" // 每次命令独立标记。
        let wrapped = "( \(command) ); result=$?; printf '\\n\(marker)%s\\n' \"$result\"" // 在子 shell 内执行，exit 不会跳过标记。
        let output = try hdc.run(["-t", serial, "shell", wrapped], timeout: timeout, attempt: attempt) // 执行过程可取消。
        guard let range = output.range(of: marker, options: .backwards) else {
            throw HdcError("未收到手机命令完成确认：\(output.trimmingCharacters(in: .whitespacesAndNewlines))") // 断线时不假报成功。
        }
        let tail = output[range.upperBound...] // stderr 可能晚于 stdout 的完成标记抵达。
        let statusLine = tail.prefix { !$0.isNewline } // 只将完成标记同一行的内容作为退出码。
        guard let code = Int(statusLine.trimmingCharacters(in: .whitespaces)) else { throw HdcError("手机命令完成状态无效：\(output)") } // 无效状态仍必须失败。
        let prefix = output[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines) // 移除内部标记前的空白。
        let suffix = tail.dropFirst(statusLine.count).trimmingCharacters(in: .whitespacesAndNewlines) // 保留晚到的诊断，不把它误读成退出码。
        let message = [prefix, suffix].filter { !$0.isEmpty }.joined(separator: "\n") // 返回完整可读输出。
        guard code == 0 else { throw HdcError(message.isEmpty ? "手机命令失败（退出码 \(code)）" : message) } // 保留权限/空间/安装错误原文。
        return message // 只有手机命令确实成功才返回。
    }

    /// 返回普通文件的完整保存位置；安装成功返回 nil。
    public func deliver(local: URL, directory: String, serial: String, attempt: ConnectionAttempt,
                        progress: @escaping (FileDeliveryProgress) -> Void) throws -> String? {
        try attempt.checkCancellation() // 已取消任务不能接触本地或手机文件。
        progress(.preparing) // 接收拖放后立刻给出可观察状态。
        let kind = FileDeliveryKind.classify(local) // 安装包和普通文件使用不同后续步骤。
        guard kind != .unsupportedPackage else { throw HdcError("仅支持安装 .hap，暂不支持 .\(local.pathExtension) 格式") }
        let values = try local.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) // 不递归读取目录或 macOS 应用包。
        guard values.isRegularFile == true, FileManager.default.isReadableFile(atPath: local.path) else {
            throw HdcError("只支持可读取的文件；文件夹和 macOS .app 应用不能拖入安装") // 明确拒绝不支持的输入。
        }
        let total = Int64(values.fileSize ?? 0) // 空文件也允许发送，完成后同样校验大小。
        let name = local.lastPathComponent // 仅用文件名拼接目标，不能把电脑路径带到手机。
        guard !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw HdcError("文件名不能包含换行或控制字符") // 避免设备工具对特殊文件名解析不一致。
        }
        let folder = kind == .package ? "/data/local/tmp" : try Self.validateDirectory(directory) // 安装不受普通文件目录设置影响。
        let token = UUID().uuidString.lowercased() // 每个任务独立标识，避免读取旧文件的进度。
        var destination = folder + "/" + name // 普通文件优先保留原名。
        var sendSource = local // 安装包直接发送到私有中转路径。
        var sendTarget = folder + "/.hosmirror-" + token + "." + local.pathExtension.lowercased() // 系统按扩展名识别包类型。
        var localContainer: URL? // 普通文件目录封装的生命周期限定到本次发送。
        var succeeded = false // 失败时清理部分文件，成功文件必须保留。
        if kind == .file {
            let exists = try checkedShell("if [ -e \(Self.quote(destination)) ]; then printf yes; fi", serial: serial, attempt: attempt) // 查询存在性不要求目录写权限。
            if exists == "yes" {
                let stem = local.deletingPathExtension().lastPathComponent // 冲突时保留原扩展名。
                let ext = local.pathExtension.isEmpty ? "" : "." + local.pathExtension // 无扩展名时不添加句点。
                destination = folder + "/" + stem + " (" + String(token.prefix(8)) + ")" + ext // 同名文件另存，不覆盖用户数据。
            }
            let targetFolder = URL(fileURLWithPath: folder) // 用最后一层目录名封装待发送文件。
            let container = FileManager.default.temporaryDirectory.appendingPathComponent("hosmirror-send-" + token) // 主机独占临时根目录。
            let leaf = container.appendingPathComponent(targetFolder.lastPathComponent, isDirectory: true) // hdc 会按本地目录名创建手机子目录。
            try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true) // 不依赖受限的手机 shell mkdir。
            localContainer = container // 建立清理所有权。
            let named = leaf.appendingPathComponent((destination as NSString).lastPathComponent) // 文件名保持最终保存名。
            do { try FileManager.default.linkItem(at: local, to: named) } // 同磁盘硬链接避免复制大文件，不修改源文件内容。
            catch { // 外置磁盘等跨卷情况退回本地复制。
                do { try FileManager.default.copyItem(at: local, to: named) } // 文件读取/空间错误原样报告。
                catch { try? FileManager.default.removeItem(at: container); throw error } // 复制失败也清理部分主机副本。
            }
            sendSource = leaf // 一次只封装一个文件，字节进度仍对应单个目标。
            let parent = targetFolder.deletingLastPathComponent().path // 根目录不能被拼成双斜线。
            sendTarget = parent == "/" ? "/" : parent + "/" // hdc 原生目录发送拥有文档目录创建权限。
        } else {
            destination = sendTarget // 包进度只读取本任务的唯一中转文件。
            try checkedShell("mkdir -p \(Self.quote(folder))", serial: serial, attempt: attempt) // 安装中转目录允许 shell 操作。
        }
        let temporary = Self.quote(destination) // shell 查询与清理路径都严格转义。
        defer {
            if let localContainer { try? FileManager.default.removeItem(at: localContainer) } // 只删除本应用创建的硬链接/副本。
            if kind == .package || !succeeded {
                _ = try? checkedShell("rm -f \(temporary)", serial: serial, timeout: 5) // 当前手机允许 unlink；不删除任何其他文件。
            }
        }
        var lastBytes: Int64? // nil 时 UI 使用不定进度，不用时间猜测比例。
        progress(.sending(completed: nil, total: total)) // 首次 stat 前不声称已经读取到字节。
        let output = try hdc.run(["-t", serial, "file", "send", sendSource.path, sendTarget], timeout: 3600, attempt: attempt) {
            guard !attempt.isCancelled else { return } // 取消后不再发起轮询。
            if let text = try? self.checkedShell("stat -c %s \(temporary)", serial: serial, timeout: 3, attempt: attempt),
               let bytes = Int64(text), bytes >= 0, bytes <= total {
                lastBytes = max(lastBytes ?? 0, bytes) // 同一临时文件的已写字节保持单调。
                progress(.sending(completed: lastBytes, total: total)) // 至多每半秒报告实际设备字节。
            }
        }
        guard output.contains("FileTransfer finish"), !output.lowercased().contains("[fail]") else {
            throw HdcError(output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "文件传输未收到成功确认" : output) // hdc 可能以零退出但正文报告失败。
        }
        if kind == .file { progress(.finishing) } // 字节发送完成后仍需通过手机文件大小校验。
        let size = try checkedShell("stat -c %s \(temporary)", serial: serial, attempt: attempt) // 结束后必须独立确认手机实际大小。
        guard Int64(size) == total else { throw HdcError("文件大小校验失败：本地 \(total) 字节，手机 \(size) 字节") }
        try attempt.checkCancellation() // 传输取消后不能继续启动安装或发布文件。
        if kind == .package {
            progress(.installing) // 只有完整包已到手机才进入系统安装阶段。
            let apiLevel = try checkedShell("param get const.ohos.apiversion || true", serial: serial, attempt: attempt)
            // bm 从 API 23 支持 -d。已确认的旧版继续覆盖安装，无法识别的版本按默认请求降级。
            let legacy = Int(apiLevel).map { (1..<23).contains($0) } ?? false
            let options = legacy ? "-r" : "-r -d"
            let result = try checkedShell("bm install \(options) -p \(temporary)", serial: serial, timeout: 600, attempt: attempt)
            guard result.lowercased().contains("success"), !result.lowercased().contains("failed"), !result.lowercased().contains("error:") else {
                throw HdcError(result.isEmpty ? "未收到系统安装成功确认" : result) // 签名、版本和权限错误原样展示。
            }
            return nil // 系统管理应用存储位置，不伪造普通文件保存路径。
        }
        succeeded = true // 只在传输确认、远端字节校验和取消检查都通过后保留普通文件。
        return destination // 提示显示手机上的最终完整位置。
    }
}
