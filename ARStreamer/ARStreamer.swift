import Foundation
import AVFoundation
import Network
import UIKit
import VideoToolbox
import CoreMedia
import CoreImage
import CoreVideo
import ImageIO

// MARK: - Настройки потока

struct StreamSettings {
    /// "USB", "TCP_H264" (Wi-Fi), "TCP_JPEG" (отладка)
    var streamMode: String = "USB"
    /// "H264" или "HEVC"
    var codec: String = "H264"
    /// "4K", "1440p", "1080p", "720p"
    var resolution: String = "1440p"
    var targetFPS: Int = 60
    var bitrateMbps: Int = 30
    var useLiDAR: Bool = false
    var jpegQuality: CGFloat = 0.8

    var preferredDimensions: (width: Int32, height: Int32) {
        switch resolution.uppercased() {
        case "4K": return (3840, 2160)
        case "1080P": return (1920, 1080)
        case "720P": return (1280, 720)
        default: return (1920, 1440)   // 4:3 — полный кадр сенсора, лучший FOV для трекинга
        }
    }

    var isJPEG: Bool { streamMode.uppercased() == "TCP_JPEG" }
}

// MARK: - Захват камеры (без ARKit)

/// Камера, настроенная под трекинг и passthrough:
/// - один физический объектив (wide), без переключения линз
/// - фиксированный формат и FPS, стабилизация выключена (иначе плывут интринсики)
/// - короткая выдержка против смаза, фокус фиксируется после автофокуса
/// - интринсики для каждого кадра
final class CameraCapture {
    let session = AVCaptureSession()
    let videoOutput = AVCaptureVideoDataOutput()
    private(set) var depthOutput: AVCaptureDepthDataOutput?
    private(set) var device: AVCaptureDevice?
    private(set) var activeFPS: Double = 0
    private(set) var horizontalFOV: Float = 0

    struct Result {
        let width: Int32
        let height: Int32
        let fps: Double
        let depth: Bool
    }

    func configure(settings: StreamSettings) -> Result? {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .inputPriority

        let wantDepth = settings.useLiDAR
        let chosen: AVCaptureDevice?
        if wantDepth, let lidar = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) {
            chosen = lidar
        } else {
            chosen = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        }
        guard let device = chosen else {
            logToFile("❌ No back camera")
            return nil
        }
        self.device = device

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                logToFile("❌ Cannot add camera input")
                return nil
            }
            session.addInput(input)
        } catch {
            logToFile("❌ Camera input error: \(error)")
            return nil
        }

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(videoOutput) else {
            logToFile("❌ Cannot add video output")
            return nil
        }
        session.addOutput(videoOutput)

        let target = settings.preferredDimensions
        guard let format = Self.pickFormat(device: device,
                                           width: target.width, height: target.height,
                                           fps: Double(settings.targetFPS),
                                           requireDepth: wantDepth) else {
            logToFile("❌ No suitable camera format")
            return nil
        }

        var hasDepth = false
        if wantDepth && !format.supportedDepthDataFormats.isEmpty {
            let output = AVCaptureDepthDataOutput()
            output.isFilteringEnabled = false        // сырые данные, без сглаживания Apple
            output.alwaysDiscardsLateDepthData = true
            if session.canAddOutput(output) {
                session.addOutput(output)
                depthOutput = output
                hasDepth = true
            }
        }

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            device.activeFormat = format
            let maxFps = format.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 30
            let fps = min(Double(settings.targetFPS), maxFps)
            let duration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            activeFPS = fps.rounded()

            if hasDepth {
                let f16 = format.supportedDepthDataFormats.filter {
                    CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat16
                }
                // ≤320 px по ширине — родное разрешение LiDAR (256x192 / 320x240), больше — апсемплинг Apple
                let all = f16.isEmpty ? format.supportedDepthDataFormats : f16
                let native = all.filter { CMVideoFormatDescriptionGetDimensions($0.formatDescription).width <= 320 }
                let candidates = native.isEmpty ? all : native
                if let best = candidates.max(by: {
                    CMVideoFormatDescriptionGetDimensions($0.formatDescription).width <
                    CMVideoFormatDescriptionGetDimensions($1.formatDescription).width
                }) {
                    device.activeDepthDataFormat = best
                }
            }

            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
                // Короткая выдержка (≤ 1/240 с) — меньше смаза при поворотах головы
                var maxExposure = CMTime(value: 1, timescale: 240)
                maxExposure = CMTimeMaximum(maxExposure, format.minExposureDuration)
                maxExposure = CMTimeMinimum(maxExposure, format.maxExposureDuration)
                device.activeMaxExposureDuration = maxExposure
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            device.isSubjectAreaChangeMonitoringEnabled = false
        } catch {
            logToFile("❌ lockForConfiguration failed: \(error)")
            return nil
        }

        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .off
            }
            if connection.isCameraIntrinsicMatrixDeliverySupported {
                connection.isCameraIntrinsicMatrixDeliveryEnabled = true
            }
        }

        horizontalFOV = format.videoFieldOfView
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        logToFile("✅ Camera \(device.localizedName): \(dims.width)x\(dims.height) @\(Int(activeFPS)) fps, depth=\(hasDepth), HFOV=\(format.videoFieldOfView)°")
        return Result(width: dims.width, height: dims.height, fps: activeFPS, depth: hasDepth)
    }

    /// Фиксирует фокус после того как автофокус сошёлся: при изменении фокуса меняются интринсики.
    func lockFocus() {
        guard let device = device else { return }
        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.locked) {
                device.focusMode = .locked
            }
            device.unlockForConfiguration()
            logToFile("🔒 Focus locked at lensPosition=\(device.lensPosition)")
        } catch {
            logToFile("⚠️ lockFocus failed: \(error)")
        }
    }

    var exposureMicroseconds: UInt32 {
        guard let d = device else { return 0 }
        let s = CMTimeGetSeconds(d.exposureDuration)
        return s.isFinite ? UInt32(clamping: Int(s * 1_000_000)) : 0
    }

    private static func pickFormat(device: AVCaptureDevice, width: Int32, height: Int32,
                                   fps: Double, requireDepth: Bool) -> AVCaptureDevice.Format? {
        let targetPixels = Double(width) * Double(height)
        let targetAspect = Double(width) / Double(height)

        func score(_ f: AVCaptureDevice.Format) -> Double {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let pixels = Double(d.width) * Double(d.height)
            let aspect = Double(d.width) / Double(d.height)
            let maxFps = f.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
            var s = abs(pixels - targetPixels) / targetPixels
            s += abs(aspect - targetAspect) * 2
            if maxFps + 0.5 < fps { s += 10 + (fps - maxFps) / 10 }
            if requireDepth && f.supportedDepthDataFormats.isEmpty { s += 100 }
            if CMFormatDescriptionGetMediaSubType(f.formatDescription) != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange { s += 0.05 }
            if f.isVideoBinned { s += 0.02 }
            return s
        }
        return device.formats.min(by: { score($0) < score($1) })
    }
}

// MARK: - ARStreamer

class ARStreamer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureDepthDataOutputDelegate {

    enum DisplayMode {
        case rgbOnly
        case depthOnly
        case both
    }

    var imuUpdateCallback: ((String, String) -> Void)?

    private var settings: StreamSettings
    private var sender: PacketSender
    private let previewCallback: (UIImage, UIImage?) -> Void
    private let fpsCallback: ((Int, Int) -> Void)?

    private let camera = CameraCapture()
    private let imu = RawIMUStreamer()
    private var encoder: VideoEncoder?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private let sessionQueue = DispatchQueue(label: "glaski.session", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "glaski.video", qos: .userInteractive)
    private let depthQueue = DispatchQueue(label: "glaski.depth", qos: .userInitiated)

    // Только из videoQueue
    private var framesThisSecond = 0
    private var droppedThisSecond = 0
    private var statsWindowStart = CACurrentMediaTime()
    private var lastPreviewTime: CFTimeInterval = 0

    // Только из depthQueue
    private var lastDepthPreviewTime: CFTimeInterval = 0

    private let stateLock = NSLock()
    private var currentDisplayMode: DisplayMode = .rgbOnly
    private var lastRGBPreview: UIImage?
    private var uiOrientation: UIDeviceOrientation = .landscapeRight
    private var running = false

    init(connection: NWConnection,
         settings: StreamSettings,
         previewCallback: @escaping (UIImage, UIImage?) -> Void,
         fpsCallback: ((Int, Int) -> Void)? = nil,
         usbManager: USBEthernetManager? = nil) {
        self.settings = settings
        self.previewCallback = previewCallback
        self.fpsCallback = fpsCallback
        self.sender = ARStreamer.makeSender(streamMode: settings.streamMode, connection: connection, usbManager: usbManager)
        super.init()
    }

    /// Совместимость со старым вызовом
    convenience init(connection: NWConnection,
                     useLiDAR: Bool = false,
                     streamMode: String = "TCP_H264",
                     compressionQuality: CGFloat = 0.8,
                     targetFPS: Int = 60,
                     previewCallback: @escaping (UIImage, UIImage?) -> Void,
                     fpsCallback: ((Int, Int) -> Void)? = nil,
                     usbManager: USBEthernetManager? = nil) {
        var s = StreamSettings()
        s.streamMode = streamMode
        s.useLiDAR = useLiDAR
        s.jpegQuality = compressionQuality
        s.targetFPS = targetFPS
        self.init(connection: connection, settings: s, previewCallback: previewCallback,
                  fpsCallback: fpsCallback, usbManager: usbManager)
    }

    private static func makeSender(streamMode: String, connection: NWConnection, usbManager: USBEthernetManager?) -> PacketSender {
        if streamMode.uppercased() == "USB", let usb = usbManager {
            return PacketSender { packet, done in usb.sendPacket(packet, completion: done) }
        }
        return PacketSender { packet, done in
            connection.send(content: packet, completion: .contentProcessed { done($0) })
        }
    }

    // MARK: - Управление

    @MainActor func startStreaming() {
        stateLock.lock()
        guard !running else { stateLock.unlock(); return }
        running = true
        uiOrientation = UIDevice.current.orientation
        stateLock.unlock()

        logToFile("🎬 startStreaming mode=\(settings.streamMode) codec=\(settings.codec) res=\(settings.resolution) fps=\(settings.targetFPS) bitrate=\(settings.bitrateMbps)Mbit LiDAR=\(settings.useLiDAR)")

        sender.send(.hello, payload: StreamPacketBuilder.hello())

        imu.onPacket = { [weak self] payload in
            self?.sender.send(.imu, payload: payload)
        }
        imu.onDebugText = { [weak self] a, b in self?.imuUpdateCallback?(a, b) }
        imu.start(rateHz: 100)

        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            guard let result = self.camera.configure(settings: self.settings) else { return }

            if !self.settings.isJPEG {
                let codec: VideoEncoder.Codec = self.settings.codec.uppercased() == "HEVC" ? .hevc : .h264
                let enc = VideoEncoder(codec: codec, bitrate: self.settings.bitrateMbps * 1_000_000, fps: Int(result.fps))
                enc.onEncoded = { [weak self] annexB, key, meta in
                    self?.sender.send(.video, payload: StreamPacketBuilder.video(codec: codec.streamCodec, keyframe: key,
                                                                                meta: meta, bitstream: annexB))
                }
                self.encoder = enc
            }

            self.camera.videoOutput.setSampleBufferDelegate(self, queue: self.videoQueue)
            self.camera.depthOutput?.setDelegate(self, callbackQueue: self.depthQueue)
            self.camera.session.startRunning()
            logToFile("✅ Capture running: \(self.camera.session.isRunning)")

            // Даём автофокусу сойтись, затем фиксируем фокус (стабильные интринсики)
            self.sessionQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.camera.lockFocus()
            }
        }
    }

    func stopStreaming() {
        stateLock.lock()
        running = false
        stateLock.unlock()
        imu.stop()
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.camera.session.isRunning { self.camera.session.stopRunning() }
            self.videoQueue.sync { self.encoder?.invalidate() }
        }
    }

    func switchDisplayMode(_ mode: DisplayMode) {
        stateLock.lock(); currentDisplayMode = mode; stateLock.unlock()
        logToFile("🔄 Display mode switched: \(mode)")
    }

    func switchToUSBMode(usbManager: USBEthernetManager) {
        settings.streamMode = "USB"
        sender = PacketSender { packet, done in usbManager.sendPacket(packet, completion: done) }
        encoder?.requestKeyframe()
    }

    func switchToNetworkMode(mode: String, connection: NWConnection) {
        settings.streamMode = mode
        sender = PacketSender { packet, done in
            connection.send(content: packet, completion: .contentProcessed { done($0) })
        }
        encoder?.requestKeyframe()
    }

    /// Legacy: угол ориентации устройства (градусы) — ПК больше не зависит от него (ориентация по гравитации)
    func sendOrientation(degrees: Double) {
        stateLock.lock(); uiOrientation = UIDevice.current.orientation; stateLock.unlock()
        var w = PacketWriter(capacity: 8)
        w.i64(Int64(bitPattern: degrees.bitPattern))
        sender.send(.deviceOrientation, payload: w.data)
    }

    // MARK: - Время

    private func hostNs(_ t: CMTime) -> Int64 {
        var host = t
        if let clock = camera.session.synchronizationClock {
            host = CMSyncConvertTime(t, from: clock, to: CMClockGetHostTimeClock())
        }
        return secondsToNs(CMTimeGetSeconds(host))
    }

    // MARK: - Видео

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ptsNs = hostNs(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var meta = VideoFrameMeta(ptsNs: ptsNs, width: width, height: height,
                                  fx: 0, fy: 0, cx: Float(width) / 2, cy: Float(height) / 2,
                                  exposureUs: camera.exposureMicroseconds)
        if let att = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
                                     attachmentModeOut: nil) as? Data,
           att.count >= MemoryLayout<matrix_float3x3>.size {
            let k = att.withUnsafeBytes { $0.loadUnaligned(as: matrix_float3x3.self) }
            meta.fx = k.columns.0.x
            meta.fy = k.columns.1.y
            meta.cx = k.columns.2.x
            meta.cy = k.columns.2.y
        } else {
            // Фолбэк по паспортному FOV формата
            let hfov = camera.horizontalFOV > 1 ? camera.horizontalFOV : 70
            let f = Float(width) / 2 / tan(hfov * .pi / 360)
            meta.fx = f
            meta.fy = f
        }

        // Backpressure: если транспорт не успевает — пропускаем кадр ДО кодирования.
        // Так задержка не копится, а цепочка P-кадров не ломается.
        let fps = max(1, Int(camera.activeFPS))
        let frameBudget = settings.bitrateMbps * 1_000_000 / 8 / fps
        let maxInFlight = max(512 * 1024, frameBudget * 4)
        let congested = sender.bytesInFlight > maxInFlight || (encoder?.pendingFrames ?? 0) > 2

        if congested {
            droppedThisSecond += 1
        } else if settings.isJPEG {
            sendJPEG(pixelBuffer, meta: meta)
            framesThisSecond += 1
        } else {
            encoder?.encode(pixelBuffer, meta: meta)
            framesThisSecond += 1
        }

        updatePreview(pixelBuffer)
        updateStats()
    }

    private func sendJPEG(_ pixelBuffer: CVPixelBuffer, meta: VideoFrameMeta) {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): settings.jpegQuality
        ]
        guard let jpeg = ciContext.jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB(), options: options) else { return }
        sender.send(.video, payload: StreamPacketBuilder.video(codec: .jpeg, keyframe: true, meta: meta, bitstream: jpeg))
    }

    private func updateStats() {
        let now = CACurrentMediaTime()
        guard now - statsWindowStart >= 1.0 else { return }
        let fps = framesThisSecond
        let dropped = droppedThisSecond
        let bytes = sender.takeSentBytes()
        framesThisSecond = 0
        droppedThisSecond = 0
        statsWindowStart = now
        fpsCallback?(fps, bytes)
        if dropped > 0 {
            logToFile("⚠️ \(dropped) frames skipped (transport congested), in-flight \(sender.bytesInFlight / 1024) KB")
        }
    }

    // MARK: - Превью на телефоне (≈8 Гц, уменьшенное, не влияет на поток)

    private func updatePreview(_ pixelBuffer: CVPixelBuffer) {
        let now = CACurrentMediaTime()
        guard now - lastPreviewTime >= 0.125 else { return }
        lastPreviewTime = now

        stateLock.lock()
        let mode = currentDisplayMode
        let orientation = uiOrientation
        let lidarOn = settings.useLiDAR
        stateLock.unlock()

        guard let image = makePreview(pixelBuffer, orientation: orientation) else { return }
        stateLock.lock(); lastRGBPreview = image; stateLock.unlock()

        // Если LiDAR включён и режим не rgbOnly — превью отдаёт depth-колбэк
        if !lidarOn || mode == .rgbOnly {
            DispatchQueue.main.async { [weak self] in self?.previewCallback(image, nil) }
        }
    }

    private func makePreview(_ pixelBuffer: CVPixelBuffer, orientation: UIDeviceOrientation) -> UIImage? {
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        switch orientation {
        case .portrait:
            image = image.transformed(by: CGAffineTransform(rotationAngle: -.pi / 2))
        case .portraitUpsideDown:
            image = image.transformed(by: CGAffineTransform(rotationAngle: .pi / 2))
        case .landscapeLeft:
            image = image.transformed(by: CGAffineTransform(rotationAngle: .pi))
        default:
            break
        }
        let longSide = max(image.extent.width, image.extent.height)
        let scale = 720 / max(longSide, 1)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.origin.x, y: -image.extent.origin.y))
        guard let cg = ciContext.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: - LiDAR

    func depthDataOutput(_ output: AVCaptureDepthDataOutput, didOutput depthData: AVDepthData,
                         timestamp: CMTime, connection: AVCaptureConnection) {
        let tNs = hostNs(timestamp)
        let depth = depthData.depthDataType == kCVPixelFormatType_DepthFloat16
            ? depthData
            : depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat16)
        let map = depth.depthDataMap

        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return }
        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        let packedRow = width * 2

        var packed = Data(count: packedRow * height)
        packed.withUnsafeMutableBytes { dst in
            guard let dstBase = dst.baseAddress else { return }
            for y in 0..<height {
                memcpy(dstBase + y * packedRow, base + y * rowBytes, packedRow)
            }
        }

        // Интринсики глубины = интринсики видео, отмасштабированные под разрешение depth
        var fx = Float(width), fy = Float(width), cx = Float(width) / 2, cy = Float(height) / 2
        if let cal = depth.cameraCalibrationData {
            let k = cal.intrinsicMatrix
            let ref = cal.intrinsicMatrixReferenceDimensions
            if ref.width > 0 {
                let s = Float(width) / Float(ref.width)
                fx = k.columns.0.x * s
                fy = k.columns.1.y * s
                cx = k.columns.2.x * s
                cy = k.columns.2.y * s
            }
        }

        let fps = max(1, Int(camera.activeFPS))
        let maxInFlight = max(1024 * 1024, settings.bitrateMbps * 1_000_000 / 8 / fps * 8)
        if sender.bytesInFlight < maxInFlight {
            sender.send(.depth, payload: StreamPacketBuilder.depth(tNs: tNs, width: width, height: height,
                                                                   fx: fx, fy: fy, cx: cx, cy: cy,
                                                                   float16Depth: packed))
        }

        updateDepthPreview(packed, width: width, height: height)
    }

    private func updateDepthPreview(_ packed: Data, width: Int, height: Int) {
        let now = CACurrentMediaTime()
        guard now - lastDepthPreviewTime >= 0.2 else { return }
        lastDepthPreviewTime = now

        stateLock.lock()
        let mode = currentDisplayMode
        let rgb = lastRGBPreview
        stateLock.unlock()
        guard mode != .rgbOnly else { return }

        var gray = [UInt8](repeating: 0, count: width * height)
        packed.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Float16.self)
            for i in 0..<(width * height) {
                let d = Float(src[i])
                // 0.2 м → белый, 5 м → чёрный
                let t = d.isFinite ? min(max((5.0 - d) / 4.8, 0), 1) : 0
                gray[i] = UInt8(t * 255)
            }
        }
        guard let provider = CGDataProvider(data: Data(gray) as CFData),
              let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                               bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                               bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                               decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return }
        let depthImage = UIImage(cgImage: cg)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            switch mode {
            case .rgbOnly: break
            case .depthOnly: self.previewCallback(UIImage(), depthImage)
            case .both: self.previewCallback(rgb ?? UIImage(), depthImage)
            }
        }
    }

    deinit {
        imu.stop()
        encoder?.invalidate()
    }
}
