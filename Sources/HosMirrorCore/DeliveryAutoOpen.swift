import Foundation // 解析 HAP 元数据、手机应用声明与目录 URI。

/// 发送或安装成功后，打开操作失败也不能把已经成功的主任务改报失败。
public struct FileDeliveryOutcome: Sendable {
    public let destination: String? // 普通文件的实际保存位置；安装应用时为 nil。
    public let openingError: String? // 仅记录自动打开失败的原因，成功时为 nil。
    public init(destination: String?, openingError: String? = nil) {
        self.destination = destination // 保留已经确认的主任务结果。
        self.openingError = openingError // UI 分别表达主任务成功和后续打开结果。
    }
}

/// 仅从刚安装 HAP 的包名解析其已安装入口，不猜测 EntryAbility 或启动其他应用。
public struct InstalledApplication: Equatable, Sendable {
    public let bundle: String // 来自 HAP 自身的 bundleName。
    public let module: String // 来自设备 bm dump 返回的模块名称。
    public let ability: String // 来自设备声明的主页面 Ability。

    public static func resolve(bundle: String, dump: String) throws -> Self {
        guard let first = dump.firstIndex(of: "{"), let last = dump.lastIndex(of: "}"), first <= last,
              let root = try JSONSerialization.jsonObject(with: Data(dump[first...last].utf8)) as? [String: Any],
              let modules = root["hapModuleInfos"] as? [[String: Any]] else {
            throw HdcError("无法读取已安装应用的启动入口") // 不把普通文本或截断输出当作成功信息。
        }
        let declaredBundle = root["name"] as? String ?? (root["applicationInfo"] as? [String: Any])?["bundleName"] as? String // 交叉核对设备返回的包身份。
        guard declaredBundle == nil || declaredBundle == bundle else { throw HdcError("设备返回的应用信息与 HAP 不一致") } // 禁止误启动其他包。
        let entry = root["entryModuleName"] as? String // 多 HAP 应用优先启动真正的入口模块。
        let ordered = modules.filter { ($0["moduleName"] as? String ?? $0["name"] as? String) == entry }
            + modules.filter { ($0["moduleName"] as? String ?? $0["name"] as? String) != entry } // 保持模块原有顺序作为后备。
        for info in ordered {
            let abilities = info["abilityInfos"] as? [[String: Any]] ?? [] // 不从 ExtensionAbility 中选应用页面。
            let main = [info["mainElementName"] as? String, info["mainAbility"] as? String].compactMap { $0 }.first { !$0.isEmpty } // 空 Stage 字段不能遮住 FA 的有效主页面。
            let visible = abilities.filter { ($0["exported"] as? Bool) != false && ($0["visible"] as? Bool) != false } // aa 不能启动不对外公开的组件。
            let home = visible.first { ability in
                (ability["skills"] as? [[String: Any]] ?? []).contains { skill in
                    (skill["entities"] as? [String] ?? []).contains("entity.system.home") // 优先选择应用桌面入口。
                }
            }
            let selected = home ?? visible.first { ($0["name"] as? String) == main } // 没有 home 声明时只采用明确主页面。
            if let selected, let ability = selected["name"] as? String, !ability.isEmpty,
               let module = info["moduleName"] as? String ?? info["name"] as? String, !module.isEmpty {
                return Self(bundle: bundle, module: module, ability: ability) // 使用设备真实入口，不依赖文件名。
            }
        }
        throw HdcError("应用没有可自动打开的页面入口") // 服务型 HAP 安装成功仍然保留成功状态。
    }

    public static func bundleName(in manifest: String) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: Data(manifest.utf8)) as? [String: Any],
              let app = root["app"] as? [String: Any], let bundle = app["bundleName"] as? String,
              !bundle.isEmpty, !bundle.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw HdcError("HAP 未提供有效的应用包名") // 文件名不能代替 bundleName。
        }
        return bundle // 后续参数仍按 shell 字面值转义。
    }
}

extension FileDelivery {
    /// 普通文件完成后在手机定位目录；HAP 完成后启动对应应用。
    public func deliverAndOpen(local: URL, directory: String, serial: String, attempt: ConnectionAttempt,
                               progress: @escaping (FileDeliveryProgress) -> Void) throws -> FileDeliveryOutcome {
        let destination = try deliver(local: local, directory: directory, serial: serial, attempt: attempt, progress: progress) // 主任务失败时绝不启动后续操作。
        progress(.opening) // 主任务已经成功，单独显示打开阶段。
        do {
            if let destination { try openDirectory(containing: destination, serial: serial, attempt: attempt) } // 打开手机保存目录，不打开 Mac Finder。
            else { // 只有成功安装的 HAP 才读取其身份并启动。
                let extractor = Hdc(binary: URL(fileURLWithPath: "/usr/bin/unzip")) // 使用 macOS 内置解压工具，只读取文本条目。
                var manifest: String? // Stage 模型优先读取 module.json，FA 模型读取 config.json。
                for entry in ["module.json", "config.json"] {
                    if let text = try? extractor.run(["-p", local.path, entry], timeout: 10, attempt: attempt), !text.isEmpty { manifest = text; break } // 不解压目录，不执行包内代码。
                }
                guard let manifest else { throw HdcError("无法读取 HAP 的应用信息，应用已安装，请在手机手动打开") } // 已安装结果不会被元数据读取失败推翻。
                let bundle = try InstalledApplication.bundleName(in: manifest) // 必须使用 HAP 中的真实包名。
                try openApplication(bundle: bundle, serial: serial, attempt: attempt) // 设备中已安装的声明决定实际入口。
            }
            return FileDeliveryOutcome(destination: destination) // 主任务和自动打开均已成功。
        } catch {
            return FileDeliveryOutcome(destination: destination, openingError: error.localizedDescription) // 只附加打开失败信息，不重复安装或发送。
        }
    }

    /// 将共享文档物理路径映射为系统文件管理器接受的公共文档 URI。
    public static func directoryURI(containing path: String) throws -> String {
        let folder = (path as NSString).deletingLastPathComponent // 跳转到文件所在目录，而非尝试打开文件内容。
        let validated = try validateDirectory(folder) // 用户目录必须是合法手机绝对路径。
        var components = URLComponents() // 交由 URL 编码处理中文、空格、#、% 等字符。
        components.scheme = "file" // 与系统文件管理器 fileUri 格式保持一致。
        components.host = "docs" // 公共文档服务的 authority。
        let pieces = validated.split(separator: "/").map(String.init) // 物理路径中的用户 ID 不写死为 100。
        if pieces.count >= 6, Array(pieces.prefix(2)) == ["storage", "media"], pieces[3..<6].elementsEqual(["local", "files", "Docs"]) {
            components.path = "/storage/Users/currentUser/" + pieces.dropFirst(6).joined(separator: "/") // Docs/Download 映射为文件管理中的 Download。
        } else if validated == "/storage/Users/currentUser" || validated.hasPrefix("/storage/Users/currentUser/") {
            components.path = validated // 已是公共文档路径时保持原意。
        } else {
            throw HdcError("该目录不属于手机公共文档区，无法在文件管理中打开：\(validated)") // 不把临时目录或应用沙箱误映射到其他位置。
        }
        guard let uri = components.string else { throw HdcError("无法生成手机目录地址") } // URI 编码失败必须明确返回。
        return uri // 路径通过参数传递，不拼接进 deep link 查询字符串。
    }

    public func openDirectory(containing path: String, serial: String, attempt: ConnectionAttempt) throws {
        let uri = try Self.directoryURI(containing: path) // 目录 URI 来自已成功返回的实际保存路径。
        let bundle = "com.huawei.hmos.files" // 华为官方公开的系统文件管理包名，使用其声明的实际入口。
        let dump = try checkedShell("bm dump -n \(Self.quote(bundle))", serial: serial, attempt: attempt) // 明确定位系统文件管理，避免隐式 home 匹配到其他组件。
        let target = try InstalledApplication.resolve(bundle: bundle, dump: dump) // 不硬编码文件管理 Ability 名称。
        let result = try checkedShell("aa start -b \(Self.quote(target.bundle)) -m \(Self.quote(target.module)) -a \(Self.quote(target.ability)) -U 'filemanager://openDirectory' --ps fileUri \(Self.quote(uri))", serial: serial, timeout: 20, attempt: attempt) // 启动真实入口并传递官方目录路由和实际文件夹 URI。
        try requireStartSuccess(result) // aa 有时以零退出并在正文报告启动失败。
    }

    public func openApplication(bundle: String, serial: String, attempt: ConnectionAttempt) throws {
        let dump = try checkedShell("bm dump -n \(Self.quote(bundle))", serial: serial, attempt: attempt) // 只查询本次 HAP 的包，不枚举用户应用。
        let target = try InstalledApplication.resolve(bundle: bundle, dump: dump) // 采用实际安装的主页面声明。
        let result = try checkedShell("aa start -b \(Self.quote(target.bundle)) -m \(Self.quote(target.module)) -a \(Self.quote(target.ability))", serial: serial, timeout: 20, attempt: attempt) // 完整参数均严格转义。
        try requireStartSuccess(result) // 保留系统错误码和权限拒绝原因。
    }

    private func requireStartSuccess(_ text: String) throws {
        guard text.lowercased().contains("start ability successfully"), !text.lowercased().contains("error:") else {
            throw HdcError(text.isEmpty ? "手机未确认打开成功" : text) // 正常复制或安装成功不代表已经打开成功。
        }
    }
}
