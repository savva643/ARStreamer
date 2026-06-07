import Foundation
import AVFoundation
import Network
import UIKit
import VideoToolbox
import CoreMedia
import CoreMotion
import CoreVideo

// 🔹 ЛОГИРОВАНИЕ В ФАЙЛ (из NetworkConnectViewModel)
func logToFile(_ message: String) {
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "HH:mm:ss.SSS"
    let timestamp = dateFormatter.string(from: Date())
    let logMessage = "[\(timestamp)] \(message)\n"
    
    if let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
        let logFilePath = documentsPath.appendingPathComponent("ARStreamer.log")
        
        if FileManager.default.fileExists(atPath: logFilePath.path) {
            if let fileHandle = FileHandle(forWritingAtPath: logFilePath.path) {
                fileHandle.seekToEndOfFile()
                if let data = logMessage.data(using: .utf8) {
                    fileHandle.write(data)
                }
                fileHandle.closeFile()
            }
        } else {
            try? logMessage.write(toFile: logFilePath.path, atomically: true, encoding: .utf8)
        }
    }
    
    // Также выводим в консоль
    print(message)
}

// MARK: - Extensions
extension CMDeviceMotion {
    var eulerAngles: (pitch: Double, yaw: Double, roll: Double) {
        let attitude = self.attitude
        return (attitude.pitch, attitude.yaw, attitude.roll)
    }
    
    var userAccel: (x: Double, y: Double, z: Double) {
        return (userAcceleration.x, userAcceleration.y, userAcceleration.z)
    }
    
    var gravityVec: (x: Double, y: Double, z: Double) {
        return (gravity.x, gravity.y, gravity.z)
    }
    
    var rotationRateVec: (x: Double, y: Double, z: Double) {
        return (rotationRate.x, rotationRate.y, rotationRate.z)
    }
    
    var magneticFieldVec: (x: Double, y: Double, z: Double) {
        return (magneticField.field.x, magneticField.field.y, magneticField.field.z)
    }
}

extension Float {
    func fixed(_ digits: Int) -> String {
        return String(format: "% .\(digits)f", self)
    }
}

// MARK: - Camera Data Structure
struct CameraData {
    var transform: simd_float4x4 = matrix_identity_float4x4
    var intrinsics: simd_float3x3 = matrix_identity_float3x3
    var imageResolution: CGSize = CGSize(width: 1920, height: 1080)
    var timestamp: TimeInterval = 0
}

// MARK: - LiDAR Depth Manager
class LiDARDepthManager: NSObject {
    private var captureSession: AVCaptureSession?
    private var depthOutput: AVCaptureDepthDataOutput?
    private var videoOutput: AVCaptureVideoDataOutput?
    
    var depthDataCallback: ((AVDepthData) -> Void)?
    var videoDataCallback: ((CVPixelBuffer) -> Void)?
    
    func startSession() {
        logToFile("🎥 LiDARDepthManager.startSession() called")
        captureSession = AVCaptureSession()
        guard let session = captureSession else { 
            logToFile("❌ Failed to create AVCaptureSession")
            return 
        }
        logToFile("✅ AVCaptureSession created")
        
        session.beginConfiguration()
        session.sessionPreset = .inputPriority
        logToFile("✅ Session configuration started")
        
        guard let device = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) ??
                         AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back) ??
                         AVCaptureDevice.default(for: .video) else {
            logToFile("❌ Camera not available - no device found")
            return
        }
        
        logToFile("✅ Camera device found: \(device.localizedName)")
        
        do {
            let input = try AVCaptureDeviceInput(device: device)
            logToFile("✅ AVCaptureDeviceInput created")
            
            if session.canAddInput(input) { 
                session.addInput(input)
                logToFile("✅ Camera input added to session")
            } else {
                logToFile("❌ Cannot add camera input - session.canAddInput returned false")
                return
            }
            
            videoOutput = AVCaptureVideoDataOutput()
            videoOutput?.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            videoOutput?.alwaysDiscardsLateVideoFrames = true
            logToFile("✅ AVCaptureVideoDataOutput created")
            
            if let videoOut = videoOutput, session.canAddOutput(videoOut) {
                session.addOutput(videoOut)
                logToFile("✅ Video output added to session")
            } else {
                logToFile("❌ Cannot add video output - session.canAddOutput returned false")
                return
            }
            
            // Check if depth is supported by looking at supported depth formats
            logToFile("🔍 Checking depth support - supportedDepthDataFormats count: \(device.activeFormat.supportedDepthDataFormats.count)")
            
            if !device.activeFormat.supportedDepthDataFormats.isEmpty {
                depthOutput = AVCaptureDepthDataOutput()
                depthOutput?.isFilteringEnabled = true
                depthOutput?.alwaysDiscardsLateDepthData = true
                logToFile("✅ AVCaptureDepthDataOutput created")
                
                if let depthOut = depthOutput, session.canAddOutput(depthOut) {
                    session.addOutput(depthOut)
                    logToFile("✅ Depth output added (LiDAR supported)")
                } else {
                    logToFile("⚠️ Cannot add depth output - session.canAddOutput returned false")
                }
            } else {
                logToFile("⚠️ Depth not supported by this device - supportedDepthDataFormats is empty")
            }
            
            try device.lockForConfiguration()
            logToFile("✅ Device locked for configuration")
            
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
                logToFile("✅ Continuous autofocus enabled")
            } else {
                logToFile("⚠️ Continuous autofocus not supported")
            }
            device.unlockForConfiguration()
            logToFile("✅ Device unlocked")
            
            session.commitConfiguration()
            logToFile("✅ Session configuration committed")
            
            // 🔹 ВАЖНО: запускаем сессию синхронно чтобы убедиться что она запустилась
            DispatchQueue.global(qos: .userInitiated).async { 
                session.startRunning()
                logToFile("✅ Camera session running (isRunning: \(session.isRunning))")
            }
            logToFile("🎥 Camera session started (LiDAR: \(depthOutput != nil))")
        } catch {
            logToFile("❌ Camera init error: \(error.localizedDescription)")
            logToFile("❌ Error details: \(error)")
        }
    }
    
    func stopSession() {
        captureSession?.stopRunning()
        captureSession = nil
    }
    
    func setVideoDelegate(_ delegate: AVCaptureVideoDataOutputSampleBufferDelegate, queue: DispatchQueue) {
        if videoOutput != nil {
            videoOutput?.setSampleBufferDelegate(delegate, queue: queue)
            logToFile("✅ Video delegate set successfully")
        } else {
            logToFile("❌ Cannot set video delegate - videoOutput is nil")
        }
    }
    
    func setDepthDelegate(_ delegate: AVCaptureDepthDataOutputDelegate, queue: DispatchQueue) {
        if depthOutput != nil {
            depthOutput?.setDelegate(delegate, callbackQueue: queue)
            logToFile("✅ Depth delegate set successfully")
        } else {
            logToFile("⚠️ Cannot set depth delegate - depthOutput is nil (LiDAR not available)")
        }
    }
    
    // 🔹 НОВЫЙ МЕТОД: установить делегаты после инициализации
    func setDelegates(_ videoDelegate: AVCaptureVideoDataOutputSampleBufferDelegate?, 
                     _ depthDelegate: AVCaptureDepthDataOutputDelegate?,
                     videoQueue: DispatchQueue,
                     depthQueue: DispatchQueue) {
        if let videoDelegate = videoDelegate {
            setVideoDelegate(videoDelegate, queue: videoQueue)
        }
        if let depthDelegate = depthDelegate {
            setDepthDelegate(depthDelegate, queue: depthQueue)
        }
    }
}

// MARK: - ARStreamer Main Class
class ARStreamer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureDepthDataOutputDelegate {
    private var connection: NWConnection
    private let previewCallback: (UIImage, UIImage?) -> Void
    private let fpsCallback: ((Int, Int) -> Void)?
    private var lidarManager: LiDARDepthManager?
    private let context = CIContext()
    private var useLiDAR: Bool = false
    private var streamMode: String = "TCP_H264"
    private var compressionQuality: CGFloat = 0.8
    
    enum DisplayMode {
        case rgbOnly
        case depthOnly
        case both
    }
    private var currentDisplayMode: DisplayMode = .rgbOnly
    
    private var encoder: H264Encoder?
    private var usbManager: USBEthernetManager?
    
    private var lastFrameTime = Date()
    private var frameCount = 0
    private var bytesSent = 0
    private var lidarBytesSent = 0
    private var lastSentTime: TimeInterval = 0
    private var targetFPS: Int = 60
    
    private var lastDepthMap: CVPixelBuffer?
    private var lastConfidenceMap: CVPixelBuffer?
    private var lidarStreamEnabled: Bool = false
    private var lastLidarSentTime: TimeInterval = 0
    private var lidarFrameCount: Int = 0
    
    private var frameInterval: TimeInterval {
        return 1.0 / Double(targetFPS)
    }
    
    private var lidarFrameInterval: TimeInterval {
        return 1.0 / Double(targetFPS)
    }
    
    private var usbCompressionQuality: CGFloat {
        return streamMode == "USB" ? 0.95 : compressionQuality
    }
    
    private var frameSequence: UInt64 = 0
    private var lastSentFrameTime: TimeInterval = 0
    private var frameTimestamps: [UInt64: TimeInterval] = [:]
    
    private let motionManager = CMMotionManager()
    private var lastSensorData: (pitch: Float, yaw: Float, roll: Float, accelX: Float, accelY: Float, accelZ: Float, gyroX: Float, gyroY: Float, gyroZ: Float, gravityX: Float, gravityY: Float, gravityZ: Float, magX: Float, magY: Float, magZ: Float)?
    private var sensorSequence: UInt64 = 0
    private var lastSensorSentTime: TimeInterval = 0
    private var sensorInterval: TimeInterval {
        return 1.0 / Double(targetFPS)
    }
    
    // MARK: - Initialization
    init(connection: NWConnection,
         useLiDAR: Bool = false,
         streamMode: String = "TCP_H264",
         compressionQuality: CGFloat = 0.8,
         targetFPS: Int = 60,
         previewCallback: @escaping (UIImage, UIImage?) -> Void,
         fpsCallback: ((Int, Int) -> Void)? = nil,
         usbManager: USBEthernetManager? = nil) {
        
        self.connection = connection
        self.previewCallback = previewCallback
        self.fpsCallback = fpsCallback
        self.useLiDAR = useLiDAR
        self.streamMode = streamMode
        self.compressionQuality = compressionQuality
        self.targetFPS = targetFPS
        self.usbManager = usbManager
        
        super.init()
        setupSensors()
        
        if streamMode == "TCP_H264" || streamMode == "UDP_H264" {
            setupH264Encoder()
        }
    }
    
    // MARK: - Sensor Setup
    private func setupSensors() {
        guard motionManager.isDeviceMotionAvailable else {
            print("Motion sensors unavailable")
            return
        }
        
        motionManager.deviceMotionUpdateInterval = sensorInterval
        motionManager.showsDeviceMovementDisplay = true
        
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] (motion, error) in
            guard let self = self, let motion = motion else { return }
            
            let euler = motion.eulerAngles
            let accel = motion.userAccel
            let gyro = motion.rotationRateVec
            let gravity = motion.gravityVec
            let mag = motion.magneticFieldVec
            
            self.lastSensorData = (
                pitch: Float(euler.pitch),
                yaw: Float(euler.yaw),
                roll: Float(euler.roll),
                accelX: Float(accel.x),
                accelY: Float(accel.y),
                accelZ: Float(accel.z),
                gyroX: Float(gyro.x),
                gyroY: Float(gyro.y),
                gyroZ: Float(gyro.z),
                gravityX: Float(gravity.x),
                gravityY: Float(gravity.y),
                gravityZ: Float(gravity.z),
                magX: Float(mag.x),
                magY: Float(mag.y),
                magZ: Float(mag.z)
            )
        }
        
        print("Motion sensors active (60 Hz)")
    }
    
    // MARK: - Send Sensor Data (104 bytes format for ARLauncher compatibility)
    private func sendSensorData(cameraData: CameraData, frameSequence: UInt64) {
        let now = Date().timeIntervalSince1970
        guard now - lastSensorSentTime >= sensorInterval else { return }
        lastSensorSentTime = now
        
        var data = Data()
        
        // 1. Timestamp (UInt64, 8 bytes)
        var timestamp = UInt64(now * 1000)
        withUnsafeBytes(of: timestamp) { data.append(contentsOf: $0) }
        
        // 2-5. IMU Data (12 x Double = 96 bytes) - accel, gyro, gravity, mag
        if let sensor = lastSensorData {
            var values: [Double] = [
                Double(sensor.accelX), Double(sensor.accelY), Double(sensor.accelZ),
                Double(sensor.gyroX), Double(sensor.gyroY), Double(sensor.gyroZ),
                Double(sensor.gravityX), Double(sensor.gravityY), Double(sensor.gravityZ),
                Double(sensor.magX), Double(sensor.magY), Double(sensor.magZ)
            ]
            for value in values {
                withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
            }
        } else {
            let zero: Double = 0.0
            for _ in 0..<12 {
                withUnsafeBytes(of: zero) { data.append(contentsOf: $0) }
            }
        }
        
        guard data.count == 104 else {
            print("Sensor data size error: \(data.count)")
            return
        }
        
        switch streamMode {
        case "USB":
            sendUSBSensorData(data, frameSequence: frameSequence)
        case "TCP_JPEG", "TCP_H264":
            sendTCPSensorData(data, frameSequence: frameSequence)
        case "UDP_H264":
            sendUDPSensorData(data, frameSequence: frameSequence)
        default:
            sendTCPSensorData(data, frameSequence: frameSequence)
        }
    }
    
    private func sendTCPSensorData(_ data: Data, frameSequence: UInt64) {
        var dataType: UInt8 = 0x03
        var sequenceBigEndian = frameSequence.bigEndian
        var size = UInt32(data.count).bigEndian
        
        let headerData = Data(bytes: &dataType, count: 1) +
                        Data(bytes: &sequenceBigEndian, count: 8) +
                        Data(bytes: &size, count: 4)
        let fullData = headerData + data
        
        connection.send(content: fullData, completion: .contentProcessed({ err in
            if let e = err {
                print("TCP sensor send error:", e)
            } else if frameSequence % 60 == 0 {
                print("TCP sensors #\(frameSequence) sent")
            }
        }))
    }
    
    private func sendUDPSensorData(_ data: Data, frameSequence: UInt64) {
        var dataType: UInt8 = 0x03
        var sequenceBigEndian = frameSequence.bigEndian
        var size = UInt32(data.count).bigEndian
        
        let headerData = Data(bytes: &dataType, count: 1) +
                        Data(bytes: &sequenceBigEndian, count: 8) +
                        Data(bytes: &size, count: 4)
        let fullData = headerData + data
        
        connection.send(content: fullData, completion: .contentProcessed({ err in
            if let e = err {
                print("UDP sensor send error:", e)
            } else if frameSequence % 60 == 0 {
                print("UDP sensors #\(frameSequence) sent")
            }
        }))
    }
    
    private func sendUSBSensorData(_ data: Data, frameSequence: UInt64) {
        guard let usbManager = usbManager, usbManager.isConnected else { return }
        
        var dataType: UInt8 = 0x03
        var sequenceBigEndian = frameSequence.bigEndian
        var size = UInt32(data.count).bigEndian
        
        let headerData = Data(bytes: &dataType, count: 1) +
                        Data(bytes: &sequenceBigEndian, count: 8) +
                        Data(bytes: &size, count: 4)
        let fullData = headerData + data
        
        usbManager.sendData(fullData)
        
        if frameSequence % 60 == 0 {
            print("USB sensors #\(frameSequence) sent")
        }
    }
    
    // MARK: - Send LiDAR Data
    private func sendLiDARData(_ depthData: AVDepthData, frameSequence: UInt64) {
        let depthMap = depthData.depthDataMap
        
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return }
        let height = CVPixelBufferGetHeight(depthMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        
        let dataSize = height * bytesPerRow
        let rawData = Data(bytes: baseAddress, count: dataSize)
        
        sendData(rawData, frameSequence: frameSequence, dataType: 0x02)
    }
    
    // MARK: - Send Point Cloud (0x08)
    private func sendPointCloudData(_ depthData: AVDepthData, frameSequence: UInt64) {
        let depthMap = depthData.depthDataMap
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        
        // Convert depth map to point cloud (simplified - XYZ for each pixel)
        var pointCloudData = Data()
        
        // Add header: width, height (4 bytes each)
        var w = UInt32(width).bigEndian
        var h = UInt32(height).bigEndian
        withUnsafeBytes(of: w) { pointCloudData.append(contentsOf: $0) }
        withUnsafeBytes(of: h) { pointCloudData.append(contentsOf: $0) }
        
        // Add depth data as point cloud (can be processed by Lidar3DProcessor)
        let dataSize = height * bytesPerRow
        let rawData = Data(bytes: baseAddress, count: dataSize)
        pointCloudData.append(rawData)
        
        sendData(pointCloudData, frameSequence: frameSequence, dataType: 0x08)
    }
    
    // MARK: - Send Confidence Map (0x09)
    private func sendConfidenceMapData(_ depthData: AVDepthData, frameSequence: UInt64) {
        // AVDepthData may have confidence map available
        // For now, send placeholder or derived confidence from depth data
        let depthMap = depthData.depthDataMap
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return }
        
        var confidenceData = Data()
        
        // Header: width, height
        var w = UInt32(width).bigEndian
        var h = UInt32(height).bigEndian
        withUnsafeBytes(of: w) { confidenceData.append(contentsOf: $0) }
        withUnsafeBytes(of: h) { confidenceData.append(contentsOf: $0) }
        
        // Generate confidence values based on depth validity
        // 0 = low confidence, 255 = high confidence
        for y in 0..<height {
            for x in 0..<width {
                let byteIndex = y * CVPixelBufferGetBytesPerRow(depthMap) + x * MemoryLayout<Float32>.size
                let depthPtr = baseAddress.advanced(by: byteIndex)
                let depth = depthPtr.load(as: Float32.self)
                
                // Simple confidence: valid depth = high confidence
                let confidence: UInt8 = (depth > 0 && depth < 10.0) ? 255 : 0
                confidenceData.append(confidence)
            }
        }
        
        sendData(confidenceData, frameSequence: frameSequence, dataType: 0x09)
    }
    
    private func sendData(_ data: Data, frameSequence: UInt64, dataType: UInt8) {
        switch streamMode {
        case "USB":
            sendUSBData(data, frameSequence: frameSequence, dataType: dataType)
        case "TCP_JPEG", "TCP_H264":
            sendTCPData(data, frameSequence: frameSequence, dataType: dataType)
        case "UDP_H264":
            sendUDPData(data, frameSequence: frameSequence, dataType: dataType)
        default:
            sendTCPData(data, frameSequence: frameSequence, dataType: dataType)
        }
    }
    
    private func sendTCPData(_ data: Data, frameSequence: UInt64, dataType: UInt8) {
        var seq = frameSequence.bigEndian
        var size = UInt32(data.count).bigEndian
        
        let header = Data([dataType]) +
                     Data(bytes: &seq, count: 8) +
                     Data(bytes: &size, count: 4)
        let packet = header + data
        
        connection.send(content: packet, completion: .contentProcessed({ err in
            if let e = err {
                print("TCP send error:", e)
            }
        }))
    }
    
    private func sendUDPData(_ data: Data, frameSequence: UInt64, dataType: UInt8) {
        var seq = frameSequence.bigEndian
        var size = UInt32(data.count).bigEndian
        
        let header = Data([dataType]) +
                     Data(bytes: &seq, count: 8) +
                     Data(bytes: &size, count: 4)
        let packet = header + data
        
        connection.send(content: packet, completion: .contentProcessed({ err in
            if let e = err {
                print("UDP send error:", e)
            }
        }))
    }
    
    private func sendUSBData(_ data: Data, frameSequence: UInt64, dataType: UInt8) {
        guard let usbManager = usbManager, usbManager.isConnected else { return }
        
        var seq = frameSequence.bigEndian
        var size = UInt32(data.count).bigEndian
        
        let header = Data([dataType]) +
                     Data(bytes: &seq, count: 8) +
                     Data(bytes: &size, count: 4)
        let packet = header + data
        
        usbManager.sendData(packet)
    }
    
    // MARK: - Video Frame Processing
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // 🔹 ЛОГИРОВАНИЕ ПЕРВОГО ФРЕЙМА
        if frameSequence == 0 {
            logToFile("🎥 captureOutput called for FIRST TIME! - frames are being captured!")
        }
        
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { 
            logToFile("❌ captureOutput: no pixelBuffer - CMSampleBufferGetImageBuffer returned nil")
            return 
        }
        
        let now = Date().timeIntervalSince1970
        guard now - lastSentTime >= frameInterval else { return }
        lastSentTime = now
        
        guard let uiImage = imageFromPixelBuffer(pixelBuffer) else { 
            logToFile("❌ captureOutput: failed to create UIImage from pixelBuffer")
            return 
        }
        
        frameSequence += 1
        frameTimestamps[frameSequence] = now
        
        // Create camera data from video output
        var cameraData = CameraData()
        cameraData.timestamp = now
        if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
            let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
            cameraData.imageResolution = CGSize(width: CGFloat(dimensions.width), height: CGFloat(dimensions.height))
        }
        
        // 🔹 ЛОГИРОВАНИЕ ВИДЕО ФРЕЙМОВ
        if frameSequence <= 5 || frameSequence % 30 == 0 {
            print("📹 Video frame #\(frameSequence): \(cameraData.imageResolution) @ \(Int(1.0/frameInterval)) FPS, streamMode=\(streamMode)")
        }
        
        // Send sensor data synchronized with frame
        sendSensorData(cameraData: cameraData, frameSequence: frameSequence)
        
        // Process and send frame
        processFrame(pixelBuffer, uiImage: uiImage, depthImage: nil, frameSequence: frameSequence)
        updateStats()
        
        // Preview callback
        DispatchQueue.main.async { [weak self] in
            self?.previewCallback(uiImage, nil)
        }
        
        cleanupOldTimestamps(currentTime: now)
    }
    
    // MARK: - Depth Data Processing
    func depthDataOutput(_ output: AVCaptureDepthDataOutput, didOutput depthData: AVDepthData, timestamp: CMTime, connection: AVCaptureConnection) {
        let now = Date().timeIntervalSince1970
        guard useLiDAR, now - lastLidarSentTime >= lidarFrameInterval else { return }
        lastLidarSentTime = now
        
        sendLiDARData(depthData, frameSequence: frameSequence)
        sendPointCloudData(depthData, frameSequence: frameSequence)
        sendConfidenceMapData(depthData, frameSequence: frameSequence)
        lidarFrameCount += 1
        
        // Count all LiDAR data sizes
        let depthSize = CVPixelBufferGetDataSize(depthData.depthDataMap)
        let width = CVPixelBufferGetWidth(depthData.depthDataMap)
        let height = CVPixelBufferGetHeight(depthData.depthDataMap)
        let confidenceSize = 8 + (width * height) // header + confidence bytes
        let pointCloudSize = 8 + depthSize // header + depth data
        lidarBytesSent += depthSize + pointCloudSize + confidenceSize
    }
    
    // MARK: - Frame Processing
    private func processFrame(_ pixelBuffer: CVPixelBuffer, uiImage: UIImage, depthImage: UIImage?, frameSequence: UInt64) {
        print("🎬 processFrame called: frameSequence=\(frameSequence), streamMode=\(streamMode)")
        switch streamMode {
        case "TCP_JPEG":
            sendTCPJPEG(uiImage, frameSequence: frameSequence)
        case "TCP_H264":
            encodeH264Frame(pixelBuffer, frameSequence: frameSequence)
        case "UDP_H264":
            encodeH264Frame(pixelBuffer, frameSequence: frameSequence)
        case "USB":
            sendUSBFrame(uiImage, frameSequence: frameSequence)
        default:
            sendTCPJPEG(uiImage, frameSequence: frameSequence)
        }
    }
    
    private func encodeH264Frame(_ pixelBuffer: CVPixelBuffer, frameSequence: UInt64) {
        guard let encoder = encoder else { return }
        let presentationTime = CMTimeMake(value: Int64(lastSentTime * 1000), timescale: 1000)
        encoder.currentFrameSequence = frameSequence
        encoder.encode(pixelBuffer, presentationTime: presentationTime)
    }
    
    private func sendH264Data(_ data: Data, isKeyframe: Bool, frameSequence: UInt64) {
        bytesSent += data.count
        
        var sequenceBigEndian = frameSequence.bigEndian
        let sequenceData = Data(bytes: &sequenceBigEndian, count: 8)
        let fullData = sequenceData + data
        
        if streamMode == "UDP_H264" {
            connection.send(content: fullData, completion: .contentProcessed({ err in
                if let e = err { print("UDP H.264 send error:", e) }
            }))
        } else {
            var size = UInt32(fullData.count).bigEndian
            let sizeData = Data(bytes: &size, count: 4)
            let finalData = sizeData + fullData
            
            connection.send(content: finalData, completion: .contentProcessed({ err in
                if let e = err { print("TCP H.264 send error:", e) }
            }))
        }
    }
    
    private func sendTCPJPEG(_ image: UIImage, frameSequence: UInt64) {
        guard let jpegData = image.jpegData(compressionQuality: compressionQuality) else { return }
        
        var dataType: UInt8 = 0x01
        var sequenceBigEndian = frameSequence.bigEndian
        var size = UInt32(jpegData.count).bigEndian
        
        let headerData = Data(bytes: &dataType, count: 1) +
                        Data(bytes: &sequenceBigEndian, count: 8) +
                        Data(bytes: &size, count: 4)
        let fullData = headerData + jpegData
        
        bytesSent += fullData.count
        
        connection.send(content: fullData, completion: .contentProcessed({ err in
            if let e = err {
                print("TCP JPEG send error:", e)
            } else if frameSequence % 60 == 0 {
                print("RGB frame #\(frameSequence) sent")
            }
        }))
    }
    
    private func sendUSBFrame(_ image: UIImage, frameSequence: UInt64) {
        guard let usbManager = usbManager else {
            print("❌ sendUSBFrame: usbManager is nil")
            return
        }
        guard usbManager.isConnected else {
            print("❌ sendUSBFrame: usbManager not connected")
            return
        }
        guard let jpegData = image.jpegData(compressionQuality: usbCompressionQuality) else {
            print("❌ sendUSBFrame: failed to create JPEG data")
            return
        }
        
        var dataType: UInt8 = 0x01
        var sequenceBigEndian = frameSequence.bigEndian
        var frameSize = UInt32(jpegData.count).bigEndian
        
        let headerData = Data(bytes: &dataType, count: 1) +
                        Data(bytes: &sequenceBigEndian, count: 8) +
                        Data(bytes: &frameSize, count: 4)
        let packetData = headerData + jpegData
        
        print("📤 sendUSBFrame: frameSequence=\(frameSequence), jpegSize=\(jpegData.count), totalSize=\(packetData.count)")
        usbManager.sendData(packetData)
        bytesSent += packetData.count
    }
    
    // MARK: - Image Processing
    private func imageFromPixelBuffer(_ buffer: CVPixelBuffer) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        
        let deviceOrientation = UIDevice.current.orientation
        var transformedImage = ciImage
        
        switch deviceOrientation {
        case .portrait:
            transformedImage = ciImage.transformed(by: CGAffineTransform(rotationAngle: -.pi/2))
        case .portraitUpsideDown:
            transformedImage = ciImage.transformed(by: CGAffineTransform(rotationAngle: .pi/2))
        case .landscapeLeft:
            transformedImage = ciImage.transformed(by: CGAffineTransform(rotationAngle: .pi))
        case .landscapeRight:
            break
        default:
            break
        }
        
        let targetSize = CGSize(width: 720, height: 1280)
        let scaleX = targetSize.width / transformedImage.extent.width
        let scaleY = targetSize.height / transformedImage.extent.height
        let scale = min(scaleX, scaleY)
        
        let scaledImage = transformedImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
        return UIImage(cgImage: cgImage, scale: 1.0, orientation: .up)
    }
    
    // MARK: - H.264 Encoder Setup
    private func setupH264Encoder() {
        let width = 1280
        let height = 720
        let bitrate = 5_000_000
        
        encoder = H264Encoder()
        encoder?.setupEncoder(width: width, height: height, bitrate: bitrate, fps: Int32(targetFPS))
        encoder?.encodedDataCallback = { [weak self] data, isKeyframe, frameSequence in
            self?.sendH264Data(data, isKeyframe: isKeyframe, frameSequence: frameSequence)
        }
    }
    
    // MARK: - Statistics
    private func updateStats() {
        frameCount += 1
        
        let current = Date()
        if current.timeIntervalSince(lastFrameTime) >= 1.0 {
            let fps = frameCount
            let totalKBps = (bytesSent + lidarBytesSent) / 1024
            let videoKBps = bytesSent / 1024
            let lidarKBps = lidarBytesSent / 1024
            
            fpsCallback?(fps, totalKBps)
            
            print("Stats (\(streamMode)): Video: \(fps) FPS, \(videoKBps) KB/s | LiDAR: \(lidarFrameCount) FPS, \(lidarKBps) KB/s | Total: \(totalKBps) KB/s")
            
            frameCount = 0
            lidarFrameCount = 0
            bytesSent = 0
            lidarBytesSent = 0
            lastFrameTime = current
        }
    }
    
    private func cleanupOldTimestamps(currentTime: TimeInterval) {
        let threshold: TimeInterval = 2.0
        frameTimestamps = frameTimestamps.filter { currentTime - $0.value < threshold }
    }
    
    // MARK: - Streaming Control
    @MainActor func startStreaming() {
        logToFile("🎬 startStreaming called with streamMode: \(streamMode), useLiDAR: \(useLiDAR)")
        
        lidarManager = LiDARDepthManager()
        logToFile("🎬 LiDARDepthManager created")
        
        // 🔹 ВАЖНО: запускаем сессию ПЕРВОЙ
        lidarManager?.startSession()
        logToFile("🎬 Camera session startSession() called")
        
        // 🔹 ЗАТЕМ устанавливаем делегаты с небольшой задержкой
        // чтобы убедиться что outputs уже созданы
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self else { 
                logToFile("❌ startStreaming: self is nil in asyncAfter")
                return 
            }
            
            logToFile("🎬 Setting delegates after 0.2 sec delay...")
            self.lidarManager?.setVideoDelegate(self, queue: .global(qos: .userInitiated))
            logToFile("✅ Video delegate set in ARStreamer")
            
            if self.useLiDAR {
                self.lidarManager?.setDepthDelegate(self, queue: .global(qos: .userInitiated))
                logToFile("✅ Depth delegate set in ARStreamer")
            }
            
            logToFile("🎬 All delegates set, waiting for frames...")
        }
        
        // 🔹 ДОБАВЛЯЕМ ЛОГИРОВАНИЕ О СОСТОЯНИИ КАМЕРЫ
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self else { return }
            logToFile("🎬 Camera session check after 1.5 seconds:")
            logToFile("   - lidarManager: \(self.lidarManager != nil)")
            logToFile("   - streamMode: \(self.streamMode)")
            logToFile("   - useLiDAR: \(self.useLiDAR)")
            logToFile("   - frameCount: \(self.frameCount)")
            logToFile("   - bytesSent: \(self.bytesSent)")
        }
        
        logToFile("🎬 Streaming initialization started (LiDAR: \(useLiDAR), Mode: \(streamMode))")
    }
    
    func stopStreaming() {
        lidarManager?.stopSession()
        lidarManager = nil
        encoder?.stopEncoding()
        motionManager.stopDeviceMotionUpdates()
    }
    
    func switchDisplayMode(_ mode: DisplayMode) {
        currentDisplayMode = mode
        print("Display mode: \(mode)")
    }
    
    @MainActor private func getServerHost() -> String? {
        if streamMode == "USB" {
            return USBEthernetManager.usbHostIP
        } else {
            let viewModel = NetworkConnectViewModel()
            return viewModel.serverIP
        }
    }
    
    @MainActor func getPortInfo() -> String {
        if streamMode == "USB" {
            return "USB port: \(USBEthernetManager.usbPort)"
        } else {
            return "Network: \(getServerHost() ?? "--"):\(getCurrentPort())"
        }
    }
    
    private func getCurrentPort() -> String {
        return "9000"
    }
    
    func switchToUSBMode(usbManager: USBEthernetManager) {
        self.usbManager = usbManager
        self.streamMode = "USB"
        encoder?.stopEncoding()
        encoder = nil
        print("Switched to USB mode")
    }
    
    func switchToNetworkMode(mode: String, connection: NWConnection) {
        self.connection = connection
        self.streamMode = mode
        self.usbManager = nil
        
        if mode == "TCP_H264" || mode == "UDP_H264" {
            setupH264Encoder()
        }
        print("Switched to network mode: \(mode)")
    }
    
    deinit {
        encoder?.stopEncoding()
    }
}
