import Foundation
import AVFoundation
import VideoToolbox
import CoreImage
import AppKit
import HosMirrorCore

/// Headless end-to-end probe: bootstrap a device, capture H.264, decode the first
/// frame with VideoToolbox and write a PNG for manual device verification.
enum Probe {
    static func run(serial: String, seconds: Double, outputDirectory: URL) throws {
        let hdc = Hdc(binary: AppResources.hdcBinary)
        let bootstrapper = DeviceBootstrapper(hdc: hdc, resources: AppResources.harmonyRoot, log: { print("· \($0)") })
        let started = try bootstrapper.bootstrap(serial: serial)
        defer { started.cleanup() }

        let client = try ScrcpyClient(port: started.videoPort)
        let lock = NSLock()
        var frames: [Data] = []
        var errorMessage: String?

        client.onFrame = { frame in
            lock.lock(); frames.append(frame); lock.unlock()
        }
        client.onError = { message in
            lock.lock() // 与主线程读取错误消息保持同步。
            errorMessage = message
            lock.unlock()
        }
        client.start() // 所有回调设置完成后开始接收，避免丢失首帧。

        print("· 采集 \(Int(seconds)) 秒，期间触发滑动以产生帧…")
        let deadline = Date().addingTimeInterval(seconds)
        var tick = 0
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 1.0)
            tick += 1
            _ = try? hdc.shell("uinput -T -m 600 1800 600 1100 120", serial: serial)
        }
        client.stop()

        lock.lock()
        let captured = frames
        let capturedError = errorMessage // 同步获取接收线程写入的错误。
        lock.unlock()

        print("· 收到 \(captured.count) 帧，\(captured.reduce(0) { $0 + $1.count }) 字节")
        if let capturedError { print("· 流错误: \(capturedError)") }
        guard !captured.isEmpty else { throw HdcError("没有收到视频帧") }

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let h264URL = outputDirectory.appendingPathComponent("probe.h264")
        try captured.reduce(into: Data()) { $0.append($1) }.write(to: h264URL)
        print("· 已写入 \(h264URL.path)")

        guard let png = decodeFirstFrame(frames: captured) else {
            throw HdcError("VideoToolbox 解码失败")
        }
        let pngURL = outputDirectory.appendingPathComponent("probe-first-frame.png")
        try png.write(to: pngURL)
        print("· 首帧解码成功：\(pngURL.path)")
    }

    private static func decodeFirstFrame(frames: [Data]) -> Data? {
        let nals = frames.flatMap { H264.split($0) }
        guard let sets = H264.parameterSets(nals) else { return nil }

        var description: CMVideoFormatDescription?
        let created = sets.sps.withUnsafeBufferPointer { sps in
            sets.pps.withUnsafeBufferPointer { pps in
                var pointers: [UnsafePointer<UInt8>] = [sps.baseAddress!, pps.baseAddress!]
                var sizes: [Int] = [sets.sps.count, sets.pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil,
                    parameterSetCount: 2,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            }
        }
        guard created == noErr, let description else { return nil }

        var session: VTDecompressionSession?
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let sessionStatus = VTDecompressionSessionCreate(
            allocator: nil,
            formatDescription: description,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        guard sessionStatus == noErr, let session else { return nil }

        var result: Data?
        for frame in frames {
            let frameNals = H264.split(frame)
            guard frameNals.contains(where: { H264.type(of: $0) == .idr }) else { continue }
            let avcc = H264.avcc(frameNals)

            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: avcc.count,
                blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                dataLength: avcc.count, flags: 0, blockBufferOut: &block
            )
            guard let block else { continue }
            _ = avcc.withUnsafeBytes {
                CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count)
            }

            var sample: CMSampleBuffer?
            var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
            var size = avcc.count
            CMSampleBufferCreateReady(
                allocator: nil, dataBuffer: block, formatDescription: description,
                sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample
            )
            guard let sample else { continue }

            VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil) { status, _, imageBuffer, _, _ in
                guard status == noErr, let imageBuffer, result == nil else { return }
                let image = CIImage(cvPixelBuffer: imageBuffer)
                let context = CIContext()
                guard let cgImage = context.createCGImage(image, from: image.extent) else { return }
                let rep = NSBitmapImageRep(cgImage: cgImage)
                result = rep.representation(using: .png, properties: [:])
            }
            if result != nil { break }
        }

        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return result
    }
}

let arguments = CommandLine.arguments
guard arguments.count > 1, !arguments[1].isEmpty else { // 仅在调用者明确指定设备时发送测试滑动。
    FileHandle.standardError.write(Data("Usage: HosMirrorProbe <device-serial> [seconds] [output-directory]\n".utf8))
    exit(2)
}
let serial = arguments[1] // 调用者从自己的 HDC 设备列表中取得标识。
let seconds = arguments.count > 2 ? (Double(arguments[2]) ?? 8) : 8
let output = URL(fileURLWithPath: arguments.count > 3 ? arguments[3] : "/tmp/hosmirror-probe")

do {
    try Probe.run(serial: serial, seconds: seconds, outputDirectory: output)
} catch {
    FileHandle.standardError.write(Data("probe failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
