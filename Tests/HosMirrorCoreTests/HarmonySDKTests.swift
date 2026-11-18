import Foundation
import XCTest
@testable import HosMirrorCore

final class HarmonySDKTests: XCTestCase {
    func testImportsLocalInstallerAndBuildsVersionedCache() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resources = directory.appendingPathComponent("resources")
        let cache = directory.appendingPathComponent("cache")
        let hdc = resources.appendingPathComponent("bin/hdc")
        try write("fixture", to: hdc)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hdc.path)
        try write("usb", to: resources.appendingPathComponent("bin/libusb_shared.dylib"))
        let files = directory.appendingPathComponent("unpacked")
        let video = "libscrcpy_server_unix_6.4-20260113.z.so"
        let control = "uitest_agent_1.2.2.so"
        try write("video", to: files.appendingPathComponent("libscrcpy/\(video)"))
        try write("other", to: files.appendingPathComponent("libscrcpy/unrelated.so"))
        let outer = directory.appendingPathComponent("outer")
        let nested = outer.appendingPathComponent("lib/hosScrcpy-test-shaded.jar")
        let archive = resources.appendingPathComponent("tools/demoWithoutRecord.jar")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        try zip(["libscrcpy"], at: files, to: nested)
        try zip(["lib"], at: outer, to: archive)

        // 不完整的安装须回滚暂存目录，安装完成后同一入口可以重试。
        XCTAssertThrowsError(try HarmonySDK.importResources(from: resources, cache: cache))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path), [])
        try write("control", to: files.appendingPathComponent(control))
        try zip(["libscrcpy", control], at: files, to: nested)
        try zip(["lib"], at: outer, to: archive)

        let result = try HarmonySDK.importResources(from: resources, cache: cache)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: result.appendingPathComponent("tools/hdc").path))
        XCTAssertEqual(try String(contentsOf: result.appendingPathComponent("devices/\(video)"), encoding: .utf8), "video")
        XCTAssertEqual(try String(contentsOf: result.appendingPathComponent("agents/\(control)"), encoding: .utf8), "control")
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.appendingPathComponent("devices/unrelated.so").path))
        XCTAssertEqual(try HarmonySDK.importResources(from: resources, cache: cache), result)
        try write("updated HDC", to: hdc)
        XCTAssertNotEqual(try HarmonySDK.importResources(from: resources, cache: cache), result)
    }

    private func write(_ value: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: file)
    }

    private func zip(_ entries: [String], at source: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        let process = Process()
        process.currentDirectoryURL = source
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-qr", destination.path] + entries
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
