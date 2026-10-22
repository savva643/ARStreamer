import Foundation
import VideoToolbox
import CoreMedia

/// Аппаратный H.264 / HEVC энкодер с низкой задержкой.
/// - на вход сразу CVPixelBuffer с камеры (без UIImage/CIImage копий)
/// - без B-кадров, keyframe раз в секунду, low-latency rate control
/// - на выходе Annex-B (start codes), на keyframe перед кадром идут VPS/SPS/PPS
final class VideoEncoder {
    enum Codec {
        case h264
        case hevc

        var streamCodec: StreamVideoCodec { self == .h264 ? .h264 : .hevc }
        var cmType: CMVideoCodecType { self == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC }
    }

    /// (annexB, isKeyframe, meta)
    var onEncoded: ((Data, Bool, VideoFrameMeta) -> Void)?

    let codec: Codec
    private let bitrate: Int
    private let fps: Int
    private var session: VTCompressionSession?
    private var width = 0
    private var height = 0

    private let lock = NSLock()
    private var pending = 0
    private var forceKeyframeNext = true

    private final class MetaBox {
        let meta: VideoFrameMeta
        init(_ meta: VideoFrameMeta) { self.meta = meta }
    }

    init(codec: Codec, bitrate: Int, fps: Int) {
        self.codec = codec
        self.bitrate = bitrate
        self.fps = fps
    }

    deinit {
        invalidate()
    }

    /// Кадры, отданные энкодеру, но ещё не вышедшие из него
    var pendingFrames: Int {
        lock.lock(); defer { lock.unlock() }
        return pending
    }

    func requestKeyframe() {
        lock.lock(); forceKeyframeNext = true; lock.unlock()
    }

    func encode(_ pixelBuffer: CVPixelBuffer, meta: VideoFrameMeta) {
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        if session == nil || w != width || h != height {
            invalidate()
            guard createSession(width: w, height: h) else { return }
        }
        guard let session = session else { return }

        lock.lock()
        let forceKey = forceKeyframeNext
        forceKeyframeNext = false
        pending += 1
        lock.unlock()

        let props: CFDictionary? = forceKey
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil
        let pts = CMTime(value: meta.ptsNs, timescale: 1_000_000_000)
        let box = Unmanaged.passRetained(MetaBox(meta)).toOpaque()

        let status = VTCompressionSessionEncodeFrame(session,
                                                     imageBuffer: pixelBuffer,
                                                     presentationTimeStamp: pts,
                                                     duration: .invalid,
                                                     frameProperties: props,
                                                     sourceFrameRefcon: box,
                                                     infoFlagsOut: nil)
        if status != noErr {
            // Колбэк не будет вызван — освобождаем сами
            Unmanaged<MetaBox>.fromOpaque(box).release()
            lock.lock(); pending -= 1; forceKeyframeNext = true; lock.unlock()
            logToFile("❌ VTCompressionSessionEncodeFrame error \(status)")
        }
    }

    func invalidate() {
        if let s = session {
            VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(s)
        }
        session = nil
    }

    // MARK: - Session

    private func createSession(width: Int, height: Int) -> Bool {
        var spec: [CFString: Any] = [:]
        if codec == .h264 {
            spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true
        }

        let callback: VTCompressionOutputCallback = { refcon, frameRefcon, status, flags, sampleBuffer in
            guard let refcon = refcon else { return }
            let encoder = Unmanaged<VideoEncoder>.fromOpaque(refcon).takeUnretainedValue()
            var meta: VideoFrameMeta?
            if let frameRefcon = frameRefcon {
                meta = Unmanaged<MetaBox>.fromOpaque(frameRefcon).takeRetainedValue().meta
            }
            encoder.handleOutput(status: status, flags: flags, sampleBuffer: sampleBuffer, meta: meta)
        }

        var newSession: VTCompressionSession?
        var status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
                                                width: Int32(width),
                                                height: Int32(height),
                                                codecType: codec.cmType,
                                                encoderSpecification: spec as CFDictionary,
                                                imageBufferAttributes: nil,
                                                compressedDataAllocator: nil,
                                                outputCallback: callback,
                                                refcon: Unmanaged.passUnretained(self).toOpaque(),
                                                compressionSessionOut: &newSession)
        if status != noErr {
            // Low-latency режим поддерживается не всеми кодеками/устройствами — пробуем без него
            logToFile("⚠️ Encoder with low-latency spec failed (\(status)), retrying without")
            status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
                                                width: Int32(width),
                                                height: Int32(height),
                                                codecType: codec.cmType,
                                                encoderSpecification: nil,
                                                imageBufferAttributes: nil,
                                                compressedDataAllocator: nil,
                                                outputCallback: callback,
                                                refcon: Unmanaged.passUnretained(self).toOpaque(),
                                                compressionSessionOut: &newSession)
        }
        guard status == noErr, let s = newSession else {
            logToFile("❌ Failed to create \(codec) encoder: \(status)")
            return false
        }

        func set(_ key: CFString, _ value: CFTypeRef) {
            let st = VTSessionSetProperty(s, key: key, value: value)
            if st != noErr { logToFile("⚠️ VTSessionSetProperty \(key) failed: \(st)") }
        }

        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_ProfileLevel,
            codec == .h264 ? kVTProfileLevel_H264_High_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: fps))
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 1.0))
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps))
        set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate))
        // DataRateLimits — в БАЙТАХ за период в секундах
        let bytesPerSecondCap = Double(bitrate) / 8.0 * 1.5
        set(kVTCompressionPropertyKey_DataRateLimits, [NSNumber(value: bytesPerSecondCap), NSNumber(value: 1.0)] as CFArray)
        if codec == .h264 {
            set(kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CABAC)
        }

        VTCompressionSessionPrepareToEncodeFrames(s)
        session = s
        self.width = width
        self.height = height
        lock.lock(); forceKeyframeNext = true; lock.unlock()
        logToFile("✅ \(codec) encoder: \(width)x\(height) @\(fps) \(bitrate / 1_000_000) Mbit/s")
        return true
    }

    // MARK: - Output

    private func handleOutput(status: OSStatus, flags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?, meta: VideoFrameMeta?) {
        lock.lock(); pending = max(0, pending - 1); lock.unlock()

        guard status == noErr, let sampleBuffer = sampleBuffer, let meta = meta,
              !flags.contains(.frameDropped) else {
            requestKeyframe()
            return
        }

        var isKeyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first,
           let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKeyframe = !notSync
        }

        var annexB = Data()
        let startCode: [UInt8] = [0, 0, 0, 1]

        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            for ps in parameterSets(format) {
                annexB.append(contentsOf: startCode)
                annexB.append(ps)
            }
        }

        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(block)
        var avcc = Data(count: length)
        let copyStatus = avcc.withUnsafeMutableBytes { ptr -> OSStatus in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: ptr.baseAddress!)
        }
        guard copyStatus == noErr else { return }

        // AVCC (4-байтная длина) -> Annex-B
        annexB.reserveCapacity(annexB.count + length + 16)
        avcc.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: UInt8.self)
            var offset = 0
            while offset + 4 <= length {
                let nalLen = Int(base[offset]) << 24 | Int(base[offset + 1]) << 16 |
                             Int(base[offset + 2]) << 8 | Int(base[offset + 3])
                offset += 4
                guard nalLen > 0, offset + nalLen <= length else { break }
                annexB.append(contentsOf: startCode)
                annexB.append(UnsafeBufferPointer(rebasing: base[offset..<(offset + nalLen)]))
                offset += nalLen
            }
        }

        onEncoded?(annexB, isKeyframe, meta)
    }

    private func parameterSets(_ format: CMFormatDescription) -> [Data] {
        var result: [Data] = []
        var count = 0
        if codec == .h264 {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0,
                                                               parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                                                               parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i,
                                                                      parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                                                                      parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                   let ptr = ptr {
                    result.append(Data(bytes: ptr, count: size))
                }
            }
        } else {
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0,
                                                               parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                                                               parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: i,
                                                                      parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                                                                      parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                   let ptr = ptr {
                    result.append(Data(bytes: ptr, count: size))
                }
            }
        }
        return result
    }
}
