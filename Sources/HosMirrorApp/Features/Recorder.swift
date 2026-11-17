import Foundation
import AVFoundation
import CoreMedia

enum RecorderError: Error, LocalizedError {
    case cannotAddInput
    case cannotStart(String)
    var errorDescription: String? {
        switch self {
        case .cannotAddInput: return "无法创建录制输入"
        case .cannotStart(let message): return message
        }
    }
}

/// Passthrough recorder: the H.264 samples are already encoded, so AVAssetWriter
/// only muxes them into MP4 (no re-encode).
final class Recorder {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var started = false
    private var finished = false
    private let lock = NSLock()

    init(url: URL, format: CMVideoFormatDescription) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecorderError.cannotAddInput }
        writer.add(input)
        guard writer.startWriting() else {
            throw RecorderError.cannotStart(writer.error?.localizedDescription ?? "AVAssetWriter 启动失败")
        }
    }

    func append(_ sample: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        if !started {
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sample))
            started = true
        }
        if input.isReadyForMoreMediaData {
            input.append(sample)
        }
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        input.markAsFinished()
        writer.finishWriting {}
    }
}
