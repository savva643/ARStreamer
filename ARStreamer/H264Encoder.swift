import VideoToolbox
import CoreMedia

class H264Encoder {
    private var encodingSession: VTCompressionSession?
    private var hasSPSPPS = false
    private var spsData: Data?
    private var ppsData: Data?
    
    // 🔹 ДОБАВЬТЕ СВОЙСТВО ДЛЯ СИНХРОНИЗАЦИИ
    var currentFrameSequence: UInt64 = 0
    var encodedDataCallback: ((Data, Bool, UInt64) -> Void)? // 🔹 ИЗМЕНИЛОСЬ: добавлен sequence
    
    func setupEncoder(width: Int, height: Int, bitrate: Int, fps: Int32) {
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: { (outputCallbackRefCon, sourceFrameRefCon, status, infoFlags, sampleBuffer) in
                guard let sampleBuffer = sampleBuffer else { return }
                
                let encoder = Unmanaged<H264Encoder>.fromOpaque(outputCallbackRefCon!).takeUnretainedValue()
                encoder.handleEncodedFrame(sampleBuffer)
            },
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &encodingSession
        )
        
        guard status == noErr, let session = encodingSession else {
            print("❌ Failed to create H264 encoding session")
            return
        }
        
        // 🔹 УЛУЧШЕННЫЕ НАСТРОЙКИ КОДИРОВАНИЯ
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: fps * 2))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: 2))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrate))
        
        // 🔹 НАСТРОЙКИ ДЛЯ НИЗКОЙ ЗАДЕРЖКИ
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: [NSNumber(value: bitrate * 2), NSNumber(value: 1)] as CFArray)
        
        // 🔹 ВКЛЮЧАЕМ ПРЕДСКАЗАНИЕ ДВИЖЕНИЯ ДЛЯ ЛУЧШЕГО КАЧЕСТВА
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_H264EntropyMode, value: kVTH264EntropyMode_CABAC)
        
        VTCompressionSessionPrepareToEncodeFrames(session)
        print("✅ H.264 encoder initialized: \(width)x\(height) @ \(fps)fps, \(bitrate/1000)kbps")
    }
    
    func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard let session = encodingSession else { return }
        
        var flags: VTEncodeInfoFlags = []
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: CMTime.invalid,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: &flags
        )
        
        if status != noErr {
            print("H264 encoding error: \(status)")
        }
    }
    
    private func handleEncodedFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let encodedDataCallback = encodedDataCallback else { return }
        
        let isKeyframe = isKeyFrame(sampleBuffer)
        
        // 🔹 ОБРАБОТКА SPS И PPS ТОЛЬКО ДЛЯ КЛЮЧЕВЫХ КАДРОВ
        if isKeyframe {
            if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
                var parameterSetCount: Int = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    formatDescription,
                    parameterSetIndex: 0,
                    parameterSetPointerOut: nil,
                    parameterSetSizeOut: nil,
                    parameterSetCountOut: &parameterSetCount,
                    nalUnitHeaderLengthOut: nil
                )
                
                if parameterSetCount >= 2 {
                    for i in 0..<parameterSetCount {
                        var parameterSetPointer: UnsafePointer<UInt8>?
                        var parameterSetSize: Int = 0
                        
                        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                            formatDescription,
                            parameterSetIndex: i,
                            parameterSetPointerOut: &parameterSetPointer,
                            parameterSetSizeOut: &parameterSetSize,
                            parameterSetCountOut: nil,
                            nalUnitHeaderLengthOut: nil
                        )
                        
                        if let parameterSetPointer = parameterSetPointer, parameterSetSize > 0 {
                            let parameterSetData = Data(bytes: parameterSetPointer, count: parameterSetSize)
                            
                            // 🔹 ДОБАВЛЯЕМ START CODE ПЕРЕД NAL UNIT
                            var nalUnitData = Data()
                            nalUnitData.append(contentsOf: [0x00, 0x00, 0x00, 0x01]) // Start code
                            nalUnitData.append(parameterSetData)
                            
                            print("📦 Sending SPS/PPS NAL unit, size: \(nalUnitData.count)")
                            encodedDataCallback(nalUnitData, true, currentFrameSequence) // 🔹 ИСПРАВЛЕНО: добавлен sequence
                        }
                    }
                }
            }
        }
        
        // 🔹 ОБРАБОТКА ДАННЫХ КАДРА
        if let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
            var totalLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            
            let status = CMBlockBufferGetDataPointer(
                dataBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &totalLength,
                dataPointerOut: &dataPointer
            )
            
            if status == noErr, let dataPointer = dataPointer {
                var offset = 0
                while offset < totalLength {
                    var nalUnitLength: UInt32 = 0
                    memcpy(&nalUnitLength, dataPointer + offset, 4)
                    nalUnitLength = CFSwapInt32BigToHost(nalUnitLength)
                    
                    if nalUnitLength > 0 {
                        let nalUnitData = Data(bytes: dataPointer + offset + 4, count: Int(nalUnitLength))
                        
                        // 🔹 ДОБАВЛЯЕМ START CODE ПЕРЕД КАЖДЫМ NAL UNIT
                        var framedData = Data()
                        framedData.append(contentsOf: [0x00, 0x00, 0x00, 0x01]) // Start code
                        framedData.append(nalUnitData)
                        
                        print("📦 Sending frame NAL unit, size: \(framedData.count), keyframe: \(isKeyframe)")
                        encodedDataCallback(framedData, isKeyframe, currentFrameSequence) // 🔹 ИСПРАВЛЕНО: добавлен sequence
                    }
                    
                    offset += Int(nalUnitLength) + 4
                }
            }
        }
    }
    
    private func isKeyFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let attachment = attachments.first else {
            return false
        }
        
        if let dependsOnOthers = attachment[kCMSampleAttachmentKey_DependsOnOthers] as? Bool {
            return !dependsOnOthers
        }
        
        if let notSync = attachment[kCMSampleAttachmentKey_NotSync] as? Bool {
            return !notSync
        }
        
        return false
    }
    
    func stopEncoding() {
        if let session = encodingSession {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: CMTime.invalid)
            VTCompressionSessionInvalidate(session)
            encodingSession = nil
        }
    }
    
    deinit {
        stopEncoding()
    }
}
