import AppKit
import CryptoKit
import Foundation

enum HarmonySDK {
    private static let bundleIdentifier = "com.huawei.devecotesting.app"
    private static let preparation = NSLock()
    private static let selection = NSLock()
    private static var selectedRoot: URL?

    static var preparedRoot: URL? { selection.withLock { selectedRoot } }

    static func prepare() throws -> URL? {
        try preparation.withLock {
            if let preparedRoot { return preparedRoot }
            let files = FileManager.default
            let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            let standard = files.urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask])
                .map { $0.appendingPathComponent("DevEco_Testing_for_App.app") }
            guard let bundle = ([registered].compactMap { $0 } + standard).first(where: {
                $0.pathExtension == "app" && Bundle(url: $0)?.bundleIdentifier == bundleIdentifier
            }) else { return nil }
            let cache = files.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Screen Annex/DevEco Testing")
            let root = try importResources(from: bundle.appendingPathComponent("Contents/Resources/app/resources"), cache: cache)
            selection.withLock { selectedRoot = root }
            return root
        }
    }

    static func importResources(from resources: URL, cache: URL) throws -> URL {
        let files = FileManager.default
        let tools = ["hdc", "libusb_shared.dylib"].map { resources.appendingPathComponent("bin/\($0)") }
        let archive = resources.appendingPathComponent("tools/demoWithoutRecord.jar")
        guard files.isExecutableFile(atPath: tools[0].path),
              files.fileExists(atPath: tools[1].path), files.fileExists(atPath: archive.path)
        else { throw HdcError("已安装的 DevEco Testing 缺少鸿蒙调试组件，请检查安装是否完整。") }

        // 以本机安装内容区分版本，正在使用的组件不会被另一个实例替换。
        var digest = SHA256()
        for file in tools + [archive] {
            digest.update(data: try Data(contentsOf: file, options: .mappedIfSafe))
        }
        let version = digest.finalize().map { String(format: "%02x", $0) }.joined()
        let root = cache.appendingPathComponent("v1-\(version)", isDirectory: true)
        if files.fileExists(atPath: root.path) { return root }

        let stage = cache.appendingPathComponent(UUID().uuidString)
        let directories = ["tools", "devices", "agents"].map { stage.appendingPathComponent($0) }
        defer { try? files.removeItem(at: stage) }
        for directory in directories { try files.createDirectory(at: directory, withIntermediateDirectories: true) }
        for tool in tools { try files.copyItem(at: tool, to: directories[0].appendingPathComponent(tool.lastPathComponent)) }
        guard let member = try entries(in: archive).first(where: {
            $0.hasPrefix("lib/hosScrcpy-") && $0.hasSuffix("-shaded.jar") && $0.split(separator: "/").count == 2
                && $0.utf8.allSatisfy { (45...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
        }) else { throw HdcError("DevEco Testing 安装中找不到投屏组件。") }
        let inner = stage.appendingPathComponent("components.jar")
        try extract(member, from: archive, to: inner)
        let entries = Set(try entries(in: inner))
        let capture = [
            "libscrcpy_server3.z.so", "libscrcpy_server_5.10-20260114.z.so",
            "libscrcpy_server_unix_6.4-20260113.z.so", "libscrcpy_server_unix_6.5-device.z.so",
            "libscrcpy_server_emulator.z.so",
        ].filter { entries.contains("libscrcpy/\($0)") }
        let control = ["uitest_agent_1.1.10.so", "uitest_agent_1.2.2.so"].filter(entries.contains)
        guard !capture.isEmpty, !control.isEmpty else { throw HdcError("此 DevEco Testing 版本缺少 Screen Annex 支持的投屏或控制组件。") }
        // 只写入已知文件名，归档里的目录和其他内容不会进入运行目录。
        for file in capture { try extract("libscrcpy/\(file)", from: inner, to: directories[1].appendingPathComponent(file)) }
        for file in control { try extract(file, from: inner, to: directories[2].appendingPathComponent(file)) }
        try files.removeItem(at: inner)
        do { try files.moveItem(at: stage, to: root) }
        catch where files.fileExists(atPath: root.path) { /* 另一个实例已提交同一份缓存。 */ }
        return root
    }

    private static func entries(in archive: URL) throws -> [String] {
        let output = Pipe()
        let unzip = try startUnzip(["-Z1", archive.path], output: output)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw HdcError("无法读取 DevEco Testing 的组件归档。") }
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
    }

    private static func extract(_ entry: String, from archive: URL, to destination: URL) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw HdcError("无法写入鸿蒙组件缓存。")
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        let unzip = try startUnzip(["-p", archive.path, entry], output: output)
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0, try output.seekToEnd() > 0 else {
            throw HdcError("无法从 DevEco Testing 读取 \(entry)。")
        }
    }

    private static func startUnzip(_ arguments: [String], output: Any) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }
}
