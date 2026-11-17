import Foundation // 仅提取 APK 自身的 AndroidManifest.xml，不执行包内代码。

public enum APKManifest {
    public static func packageName(in archive: URL, attempt: ConnectionAttempt) throws -> String { // 使用系统 unzip 解出单个条目到独占临时文件。
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".axml") // 二进制 manifest 不能经 String 管道读取。
        defer { try? FileManager.default.removeItem(at: output) } // 成功失败都清理临时数据。
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else { throw HdcError("无法创建 APK 声明的临时文件") } // 不解压用户控制的路径。
        let handle = try FileHandle(forWritingTo: output) // 输出目标由本程序生成。
        defer { try? handle.close() } // 不遗留文件句柄。
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); process.arguments = ["-p", archive.path, "AndroidManifest.xml"] // 不执行 shell 或解压目录。
        process.standardOutput = handle; process.standardError = FileHandle.nullDevice // 错误只以退出状态返回。
        try process.run() // 只运行系统工具。
        let deadline = Date().addingTimeInterval(10) // 畸形 APK 不能无限占用队列。
        let limit = 16 * 1024 * 1024 // 限制畸形包的解压输出。
        while process.isRunning && Date() < deadline && !attempt.isCancelled { // 仅在文件队列等待。
            if let size = try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > limit { break } // 超大 manifest 不进入内存。
            Thread.sleep(forTimeInterval: 0.02) // 不进行忙等。
        }
        if process.isRunning { process.terminate() } // 超时或取消时停止解压。
        process.waitUntilExit(); try attempt.checkCancellation() // 取消不继续安装。
        guard process.terminationStatus == 0 else { throw HdcError("无法读取 APK 的应用声明") } // 没有 manifest 不能猜测包身份。
        guard let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= limit else { throw HdcError("APK 声明过大") } // 读取前再次验证真实大小。
        return try packageName(data: Data(contentsOf: output)) // 解析受限的字符串池和 manifest 属性。
    }
    public static func packageName(data: Data) throws -> String { // 仅实现读取包名所需的 Android 二进制 XML 字段。
        let bytes = [UInt8](data) // 避免未对齐加载。
        func number(_ offset: Int, _ count: Int = 4) throws -> Int { // 每次读取检查边界。
            guard offset >= 0, count > 0, offset <= bytes.count - count else { throw HdcError("APK 声明已损坏") } // 拒绝越界。
            return (0..<count).reduce(0) { $0 | Int(bytes[offset + $1]) << (8 * $1) } // AXML 使用小端整数。
        }
        guard bytes.count >= 8, bytes.count <= 16 * 1024 * 1024, try number(0, 2) == 3, try number(4) == bytes.count else { throw HdcError("APK 声明格式无效") } // 拒绝截断或拼接的多份声明。
        var strings: [String] = []; var position = 8 // 文档头后依次读取 chunk。
        while position <= bytes.count - 8 {
            let type = try number(position, 2), header = try number(position + 2, 2), size = try number(position + 4) // 标准 chunk 头。
            guard header >= 8, size >= header, size <= bytes.count - position else { throw HdcError("APK 声明区块无效") } // 防止无穷循环或越界。
            if type == 1 { // RES_STRING_POOL_TYPE。
                guard header >= 28 else { throw HdcError("APK 字符串池无效") } // 固定字段必须完整。
                let count = try number(position + 8), flags = try number(position + 16), start = try number(position + 20) // 字符串数量、编码和数据偏移。
                guard strings.isEmpty, count <= 100000, header + count * 4 <= start, start <= size else { throw HdcError("APK 字符串数量或偏移无效") } // 只允许标准的单一字符串池。
                var decodedBytes = 0 // 阻止重复字符串偏移放大内存占用。
                for index in 0..<count {
                    var cursor = position + start + (try number(position + header + index * 4)) // 字符串偏移表相对于字符串数据区。
                    func length(_ wide: Bool) throws -> Int { // 两种编码都使用可扩展长度格式。
                        let first = try number(cursor, wide ? 2 : 1); cursor += wide ? 2 : 1 // 先读取短长度。
                        let mask = wide ? 0x8000 : 0x80 // 最高位指示后续长度。
                        if first & mask == 0 { return first } // 短字符串无需扩展。
                        let next = try number(cursor, wide ? 2 : 1); cursor += wide ? 2 : 1 // 扩展低位。
                        return ((first & (mask - 1)) << (wide ? 16 : 8)) | next // 得到完整字符/字节长度。
                    }
                    let utf8 = flags & 0x100 != 0 // Android 支持 UTF-8 或 UTF-16LE 池。
                    let byteCount: Int // 以字节边界检查实际内容。
                    if utf8 { _ = try length(false); byteCount = try length(false) } else { byteCount = try length(true) * 2 } // UTF-8 首项是 UTF-16 字符数，第二项才是字节数。
                    guard cursor >= position, byteCount >= 0, cursor + byteCount <= position + size else { throw HdcError("APK 字符串越界") } // 不读取下一个 chunk。
                    decodedBytes += byteCount // 按实际解码开销累计。
                    guard decodedBytes <= 16 * 1024 * 1024 else { throw HdcError("APK 字符串池过大") } // 有界处理畸形重复偏移。
                    guard let text = String(data: Data(bytes[cursor..<cursor + byteCount]), encoding: utf8 ? .utf8 : .utf16LittleEndian) else { throw HdcError("APK 字符串编码无效") } // 不悄悄替换损坏字符。
                    strings.append(text) // 后续属性只引用本池索引。
                }
            } else if type == 0x102 { // RES_XML_START_ELEMENT_TYPE。
                let extensionStart = position + header // XML node 头之后是 attribute extension。
                let nameIndex = try number(extensionStart + 4) // element 名字索引。
                let attributeStart = try number(extensionStart + 8, 2), attributeSize = try number(extensionStart + 10, 2), count = try number(extensionStart + 12, 2) // 属性表布局。
                if strings.indices.contains(nameIndex), strings[nameIndex] == "manifest" {
                    guard attributeSize >= 20 else { throw HdcError("APK 属性表无效") } // 每项包含 namespace/name/raw/typed value。
                    for index in 0..<count {
                        let attribute = extensionStart + attributeStart + index * attributeSize // 跳到当前属性。
                        guard attribute + 20 <= position + size else { throw HdcError("APK 属性越界") } // 不能读取其他区块。
                        let key = try number(attribute + 4), raw = try number(attribute + 8), valueType = try number(attribute + 15, 1), typed = try number(attribute + 16) // 原值与 typed string 都支持。
                        let value = strings.indices.contains(raw) ? raw : (valueType == 3 ? typed : -1) // 只接受字符串包名。
                        if strings.indices.contains(key), strings[key] == "package", strings.indices.contains(value) {
                            let package = strings[value] // 包名来自 APK 自身，不依赖文件名。
                            guard !package.isEmpty, package.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_") }) else { throw HdcError("APK 包名无效") } // 不允许 shell 元字符或组件路径。
                            return package // 仅用于解析该包的真实 launcher 活动。
                        }
                    }
                }
            }
            position += size // 继续下一个独立 chunk。
        }
        throw HdcError("APK 未声明有效的应用包名") // 不猜测待启动应用。
    }
}
