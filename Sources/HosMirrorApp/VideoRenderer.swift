import Foundation
import AVFoundation
import VideoToolbox
import CoreMedia
import CoreImage // 只为连接显影生成一张小尺寸内存预览。
import HosMirrorCore

/// Turns device H.264 access units into `CMSampleBuffer`s for an
/// `AVSampleBufferDisplayLayer`, using VideoToolbox's H.264 decoder.
@MainActor
public final class VideoRenderer { // 渲染参数、录制回调和图层都由主线程独占。
    public let layer = AVSampleBufferDisplayLayer()

    public var onSize: ((CGSize) -> Void)?
    public var onFirstFrame: (() -> Void)? // 有效首帧入队时通知连接界面。
    public var onKeyFrameNeeded: (() -> Void)? // 显示层丢失参考帧后，请设备补发独立画面。
    /// Called with every encoded sample buffer (used by the recorder).
    public var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    private(set) var formatDescription: CMVideoFormatDescription?
    private var activeParameterSets: (sps: [UInt8], pps: [UInt8])? // 相同的参数集复用解码格式。
    private var waitingForIDR = true
    private var recovering = false
    private var lastKeyFrameRequest: TimeInterval = -.infinity
    private var lastDeltaTime: TimeInterval = 0
    private var idleRefresh: Task<Void, Never>?
    private var deviceClockOffset = CMTime.invalid // Android 的编码时钟到 Mac 主机时钟的偏移。
    private var lastScheduledTime = CMTime.invalid // 送显与录制共用单调递增的时间戳。
    public private(set) var currentSnapshot: CGImage? // 首帧显影图，不写入文件或相册。
    private var readyObserver: NSObjectProtocol? // 监听真正可显示，而非仅完成编码包入队。
    private var snapshotDecoder: VTDecompressionSession? // 显示层不能复制像素时，只解码首帧作为后备。
    private var snapshotRequested = false
    private var snapshotFinished = false
    private var submittedFrame = false
    private var generation = 0 // 旧连接解码回调不可进入新会话。
    private var announcedFirstFrame = false // 每次 reset 后仅通知一次。

    public init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1)
        if #available(macOS 14.4, *) {
            readyObserver = NotificationCenter.default.addObserver(forName: .AVSampleBufferDisplayLayerReadyForDisplayDidChange, object: layer, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.announceFirstFrameIfReady() } // 不在通知回调内跨线程读写渲染状态。
            }
        }
    }

    deinit {
        idleRefresh?.cancel()
        if let readyObserver { NotificationCenter.default.removeObserver(readyObserver) } // 释放生命周期观察。
        if let snapshotDecoder { VTDecompressionSessionInvalidate(snapshotDecoder) } // 不遗留辅助解码器。
    }

    public func reset() {
        generation += 1 // 首先使正在回来的旧预览解码失效。
        releaseSnapshotDecoder()
        currentSnapshot = nil
        snapshotRequested = false
        snapshotFinished = false
        submittedFrame = false
        formatDescription = nil
        activeParameterSets = nil
        waitingForIDR = true
        recovering = false
        lastKeyFrameRequest = -.infinity
        idleRefresh?.cancel()
        idleRefresh = nil
        deviceClockOffset = .invalid
        lastScheduledTime = .invalid
        announcedFirstFrame = false // 重新连接必须重新等到有效关键帧。
        layer.sampleBufferRenderer.flush()
    }

    public func consume(_ packet: VideoPacket) {
        let nals = H264.split(packet.accessUnit)
        guard !nals.isEmpty else { return }

        if let sets = H264.parameterSets(nals),
           sets.sps != activeParameterSets?.sps || sets.pps != activeParameterSets?.pps,
           let description = makeFormatDescription(sps: sets.sps, pps: sets.pps) {
            activeParameterSets = sets // 服务端重发相同配置时无需刷新解码格式。
            formatDescription = description
            waitingForIDR = true // 新编码配置从能独立解码的一帧开始。
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            onSize?(CGSize(width: Int(dimensions.width), height: Int(dimensions.height))) // 旋转或改画质时同步实际编码尺寸。
        }

        let hasSlice = nals.contains { nal in
            guard let type = H264.type(of: nal) else { return false }
            return type == .slice || type == .idr
        }
        guard hasSlice, let formatDescription else { return }

        let isKeyFrame = packet.timing?.isKeyFrame == true || nals.contains { H264.type(of: $0) == .idr }
        let decoder = layer.sampleBufferRenderer
        if decoder.status == .failed || decoder.requiresFlushToResumeDecoding {
            decoder.flush() // 保留现有画面，并在收到可解码帧后恢复。
            deviceClockOffset = .invalid // 根据恢复后第一帧重新对齐主机时钟。
            waitingForIDR = true
            recovering = true
        }
        if waitingForIDR, !isKeyFrame {
            let now = ProcessInfo.processInfo.systemUptime
            if recovering, now - lastKeyFrameRequest >= 1 {
                lastKeyFrameRequest = now
                onKeyFrameNeeded?() // 解码失败时最多每秒请求一次，不等待静止画面自然刷新。
            }
            return
        }

        let avcc = H264.avcc(nals)
        let now = CMClockGetTime(CMClockGetHostTimeClock()) // 直接对应显示图层的默认时间基准。
        let pts = packet.timing.map { schedule(deviceTimeUs: $0.presentationTimeUs, now: now) } ?? now
        guard let sample = makeSampleBuffer(avcc: avcc, format: formatDescription, pts: pts,
                                            displayImmediately: packet.timing == nil, isKeyFrame: isKeyFrame) else { return }
        waitingForIDR = false
        recovering = false
        onSampleBuffer?(sample)

        submittedFrame = true // 参数集或关键帧之前的增量帧不会到达这里。
        decoder.enqueue(sample) // 当前执行器就是主线程，避免旧帧在 reset 后再次入队。
        if packet.timing == nil, onKeyFrameNeeded != nil {
            scheduleIdleRefresh(afterKeyFrame: isKeyFrame)
        }
        if !snapshotRequested, isKeyFrame {
            prepareSnapshot(sample: sample, format: formatDescription) // 只额外解码第一张关键帧，不进行持续二次解码。
        }
        announceFirstFrameIfReady()
    }

    private func scheduleIdleRefresh(afterKeyFrame: Bool) {
        if afterKeyFrame {
            idleRefresh?.cancel() // 编码器已经生成独立画面，无需补发。
            idleRefresh = nil
            return
        }
        lastDeltaTime = ProcessInfo.processInfo.systemUptime
        guard idleRefresh == nil else { return }
        idleRefresh = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let deltaTime = self?.lastDeltaTime, let lastRequest = self?.lastKeyFrameRequest else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let remaining = max(deltaTime + 0.16, lastRequest + 0.75) - now
                if remaining > 0 {
                    try? await Task.sleep(for: .seconds(remaining))
                    continue
                }
                self?.idleRefresh = nil
                self?.lastKeyFrameRequest = now
                self?.onKeyFrameNeeded?() // 补一次独立画面，避免列表停在丢失浅色细节的增量帧。
                return
            }
        }
    }

    private func schedule(deviceTimeUs: Int64, now: CMTime) -> CMTime {
        let deviceTime = CMTime(value: deviceTimeUs, timescale: 1_000_000) // 保留设备的帧间隔。
        var time = deviceTime + deviceClockOffset
        if !time.isNumeric || time < now - CMTime(value: 50, timescale: 1_000) ||
            time > now + CMTime(value: 250, timescale: 1_000) {
            // 起播或时钟跳变时重新对齐，留 32 毫秒给解码和传输抖动。
            time = now + CMTime(value: 32, timescale: 1_000)
            deviceClockOffset = time - deviceTime
        }
        if lastScheduledTime.isNumeric, time <= lastScheduledTime {
            time = lastScheduledTime + CMTime(value: 1, timescale: 1_000_000) // 重复时间戳也须满足录制的单调顺序。
        }
        lastScheduledTime = time
        return time
    }

    public func captureCurrentFrame() -> CGImage? {
        if #available(macOS 14.4, *), layer.isReadyForDisplay,
           let buffer = layer.sampleBufferRenderer.displayedPixelBuffer() {
            return Self.makeSnapshot(buffer) // 采用官方显示像素复制接口，不截取用户桌面。
        }
        return currentSnapshot // 不支持复制时保留本会话自己的首帧预览。
    }

    private func announceFirstFrameIfReady() {
        guard submittedFrame, !announcedFirstFrame, layer.sampleBufferRenderer.status != .failed else { return }
        if #available(macOS 14.4, *), !layer.isReadyForDisplay { return } // 编码数据已收到也可能还无法显示。
        currentSnapshot = captureCurrentFrame() ?? currentSnapshot
        guard currentSnapshot != nil || snapshotFinished else { return } // 等待首帧的模糊显影素材。
        announcedFirstFrame = true
        onFirstFrame?() // 画面和预览都准备好后，界面才开始变清晰。
    }

    private func prepareSnapshot(sample: CMSampleBuffer, format: CMVideoFormatDescription) {
        snapshotRequested = true
        let token = generation // 捕获当前渲染会话版本。
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let created = VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &snapshotDecoder)
        guard created == noErr, let snapshotDecoder else {
            snapshotFinished = true // 预览失败不能阻断本来可以显示的实时视频。
            return
        }
        let decoded = VTDecompressionSessionDecodeFrame(snapshotDecoder, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil) { [weak self] status, _, buffer, _, _ in
            let image = status == noErr ? buffer.flatMap(Self.makeSnapshot) : nil // 图片转换在解码回调线程执行。
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return } // 丢弃已取消或已重置连接的画面。
                self.snapshotFinished = true
                if let image { self.currentSnapshot = image }
                self.announceFirstFrameIfReady()
                self.releaseSnapshotDecoder() // 只做一次首帧提取，随后释放额外解码资源。
            }
        }
        if decoded != noErr {
            snapshotFinished = true // 异常解码仍允许系统显示层独立完成播放。
            releaseSnapshotDecoder()
        }
    }

    private func releaseSnapshotDecoder() {
        if let snapshotDecoder { VTDecompressionSessionInvalidate(snapshotDecoder) }
        snapshotDecoder = nil
    }

    private nonisolated static func makeSnapshot(_ buffer: CVPixelBuffer) -> CGImage? {
        let image = CIImage(cvPixelBuffer: buffer)
        let factor = min(1, 720 / max(image.extent.width, image.extent.height)) // 预览只需最长边 720，限制内存与模糊开销。
        let scaled = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        return CIContext(options: [.cacheIntermediates: false]).createCGImage(scaled, from: scaled.extent) // 不缓存中间画面，不访问任何磁盘路径。
    }

    private func makeFormatDescription(sps: [UInt8], pps: [UInt8]) -> CMVideoFormatDescription? {
        var description: CMVideoFormatDescription?
        let status = sps.withUnsafeBufferPointer { spsBuffer in
            pps.withUnsafeBufferPointer { ppsBuffer in
                var pointers: [UnsafePointer<UInt8>] = [spsBuffer.baseAddress!, ppsBuffer.baseAddress!]
                var sizes: [Int] = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            }
        }
        guard status == noErr, let description else { return nil }
        // Mate 70 码流使用矩阵码点 5。它与 BT.601 的转换系数相同，用系统可识别的标签表达。
        guard var extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any],
              extensions[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String == "YCbCrMatrix#5" else { return description }
        extensions[kCMFormatDescriptionExtension_YCbCrMatrix as String] = kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        var normalized: CMVideoFormatDescription?
        let created = CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_H264,
            width: dimensions.width, height: dimensions.height, extensions: extensions as CFDictionary,
            formatDescriptionOut: &normalized)
        return created == noErr ? normalized ?? description : description // 保留原码流、色域、传递函数和亮度范围。
    }

    private func makeSampleBuffer(avcc: Data, format: CMVideoFormatDescription, pts: CMTime,
                                  displayImmediately: Bool, isKeyFrame: Bool) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        let copied = avcc.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: avcc.count
            )
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleSize = avcc.count
        let created = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard created == noErr, let sampleBuffer else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            if displayImmediately { // 无设备时间戳的鸿蒙流继续使用原有送显方式。
                CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
            if !isKeyFrame { // Core Media 默认认为样本是同步帧，需要显式标记有参考依赖的帧。
                CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return sampleBuffer
    }
}
