import Foundation
import AVFoundation
import Network
import UIKit
import VideoToolbox
import CoreMedia
import CoreMotion
import CoreVideo

// 🔹 logToFile функция определена в NetworkConnectViewModel.swift

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
    private var lastRGBImage: UIImage?  // 🔹 Сохраняем последний RGB frame для синхронизации
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
    
    // 🔹 НОВОЕ: callback для обновления IMU и позиции
    var imuUpdateCallback: ((String, String) -> Void)?
    
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
            
            // 🔹 ОБНОВЛЯЕМ IMU И ПОЗИЦИЮ В UI (каждый 10-й кадр)
            if self.frameSequence % 10 == 0 {
                let imuStr = String(format: "IMU: A(%.1f,%.1f,%.1f) G(%.1f,%.1f,%.1f)", 
                    accel.x, accel.y, accel.z, gyro.x, gyro.y, gyro.z)
                let posStr = String(format: "Rot: P%.0f° Y%.0f° R%.0f°", 
                    euler.pitch * 180 / .pi, euler.yaw * 180 / .pi, euler.roll * 180 / .pi)
                self.imuUpdateCallback?(imuStr, posStr)
            }
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
        let timestamp = UInt64(now * 1000)
        var timestampVar = timestamp
        withUnsafeBytes(of: &timestampVar) { data.append(contentsOf: $0) }
        
        // 2-5. IMU Data (12 x Double = 96 bytes) - accel, gyro, gravity, mag
        if let sensor = lastSensorData {
            let values: [Double] = [
                Double(sensor.accelX), Double(sensor.accelY), Double(sensor.accelZ),
                Double(sensor.gyroX), Double(sensor.gyroY), Double(sensor.gyroZ),
                Double(sensor.gravityX), Double(sensor.gravityY), Double(sensor.gravityZ),
                Double(sensor.magX), Double(sensor.magY), Double(sensor.magZ)
            ]
            for value in values {
                withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
            }
            
            // 🔹 ЛОГИРОВАНИЕ IMU ДАННЫХ
            if frameSequence <= 5 || frameSequence % 60 == 0 {
                print("📊 IMU #\(frameSequence): Accel=(\(String(format: "%.2f", sensor.accelX)), \(String(format: "%.2f", sensor.accelY)), \(String(format: "%.2f", sensor.accelZ))) Gyro=(\(String(format: "%.2f", sensor.gyroX)), \(String(format: "%.2f", sensor.gyroY)), \(String(format: "%.2f", sensor.gyroZ)))")
                logToFile("📊 IMU #\(frameSequence): Accel=(\(sensor.accelX), \(sensor.accelY), \(sensor.accelZ)) Gyro=(\(sensor.gyroX), \(sensor.gyroY), \(sensor.gyroZ))")
            }
        } else {
            let zero: Double = 0.0
            for _ in 0..<12 {
                withUnsafeBytes(of: zero) { data.append(contentsOf: $0) }
            }
            
            // 🔹 ЛОГИРОВАНИЕ ОТСУТСТВИЯ IMU ДАННЫХ
            if frameSequence <= 5 || frameSequence % 60 == 0 {
                print("⚠️ IMU #\(frameSequence): NO SENSOR DATA - sending zeros")
                logToFile("⚠️ IMU #\(frameSequence): NO SENSOR DATA - sending zeros")
            }
        }
        
        guard data.count == 104 else {
            print("Sensor data size error: \(data.count)")
            logToFile("❌ Sensor data size error: \(data.count)")
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
        withUnsafeBytes(of: &w) { pointCloudData.append(contentsOf: $0) }
        withUnsafeBytes(of: &h) { pointCloudData.append(contentsOf: $0) }
        
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
        withUnsafeBytes(of: &w) { confidenceData.append(contentsOf: $0) }
        withUnsafeBytes(of: &h) { confidenceData.append(contentsOf: $0) }
        
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
        
        // 🔹 СОХРАНЯЕМ RGB FRAME для синхронизации с depth в depthDataOutput
        self.lastRGBImage = uiImage
        
        // 🔹 ОТПРАВЛЯЕМ PREVIEW: если LiDAR выключен или режим rgbOnly - отправляем сразу
        // если LiDAR включен - отправка будет из depthDataOutput
        if !self.useLiDAR || self.currentDisplayMode == .rgbOnly {
            DispatchQueue.main.async { [weak self] in
                self?.previewCallback(uiImage, nil)
            }
        }
        
        cleanupOldTimestamps(currentTime: now)
    }
    
    // MARK: - Depth Data Processing
    func depthDataOutput(_ output: AVCaptureDepthDataOutput, didOutput depthData: AVDepthData, timestamp: CMTime, connection: AVCaptureConnection) {
        let now = Date().timeIntervalSince1970
        guard useLiDAR, now - lastLidarSentTime >= lidarFrameInterval else { return }
        lastLidarSentTime = now
        
        let depthMap = depthData.depthDataMap
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        
        // 🔹 ЛОГИРОВАНИЕ DEPTH ДАННЫХ
        if frameSequence <= 5 || frameSequence % 60 == 0 {
            print("🎯 [LIDAR] depthDataOutput: width=\(width), height=\(height), frameSequence=\(frameSequence)")
            logToFile("🎯 [LIDAR] depthDataOutput: width=\(width), height=\(height), frameSequence=\(frameSequence)")
        }
        
        // 🔹 СОЗДАЕМ DEPTH IMAGE ДЛЯ PREVIEW
        if let depthImage = createDepthImage(from: depthData) {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                // 🔹 ОТПРАВЛЯЕМ ТОЛЬКО НУЖНЫЕ ИЗОБРАЖЕНИЯ В ЗАВИСИМОСТИ ОТ РЕЖИМА
                switch self.currentDisplayMode {
                case .rgbOnly:
                    // В режиме RGB только - не отправляем depth
                    return
                case .depthOnly:
                    // В режиме LiDAR только - отправляем только depth
                    self.previewCallback(UIImage(), depthImage)
                case .both:
                    // В режиме "оба" - отправляем оба изображения
                    let rgbImage = self.lastRGBImage ?? UIImage()
                    self.previewCallback(rgbImage, depthImage)
                }
                
                if self.frameSequence <= 5 || self.frameSequence % 60 == 0 {
                    print("✅ Depth image created and sent to preview: \(depthImage.size), mode=\(self.currentDisplayMode)")
                    logToFile("✅ Depth image created and sent to preview: \(depthImage.size), mode=\(self.currentDisplayMode)")
                }
            }
        } else {
            logToFile("❌ Failed to create depth image from depthData")
        }
        
        sendLiDARData(depthData, frameSequence: frameSequence)
        sendPointCloudData(depthData, frameSequence: frameSequence)
        sendConfidenceMapData(depthData, frameSequence: frameSequence)
        lidarFrameCount += 1
        
        // Count all LiDAR data sizes
        let depthSize = CVPixelBufferGetDataSize(depthData.depthDataMap)
        let confidenceSize = 8 + (width * height) // header + confidence bytes
        let pointCloudSize = 8 + depthSize // header + depth data
        lidarBytesSent += depthSize + pointCloudSize + confidenceSize
    }
    
    // 🔹 НОВЫЙ МЕТОД: создание UIImage из depth данных с поддержкой Float16 и Float32
    private func createDepthImage(from depthData: AVDepthData) -> UIImage? {
        let depthMap = depthData.depthDataMap
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let pixelFormat = CVPixelBufferGetPixelFormatType(depthMap)
        
        print("📐 Depth map: \(width)x\(height), format: \(pixelFormat)")
        logToFile("📐 Depth map: \(width)x\(height), format: \(pixelFormat)")
        
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        
        // Проверка формата – поддерживаем только Float32 и Float16
        let isFloat16 = (pixelFormat == kCVPixelFormatType_DepthFloat16 ||
                         pixelFormat == kCVPixelFormatType_DisparityFloat16)
        let isFloat32 = (pixelFormat == kCVPixelFormatType_DepthFloat32 ||
                         pixelFormat == kCVPixelFormatType_DisparityFloat32)
        
        guard isFloat16 || isFloat32 else {
            print("❌ Unsupported depth format: \(pixelFormat)")
            return nil
        }
        
        // Вспомогательная функция конвертации Float16 -> Float32
        func float16to32(_ f16: UInt16) -> Float {
            let sign = (f16 >> 15) & 0x1
            let exponent = (f16 >> 10) & 0x1F
            let mantissa = f16 & 0x3FF
            if exponent == 0 {
                if mantissa == 0 { return 0.0 }
                let value = Float(mantissa) / 1024.0 * powf(2, -14)
                return sign == 0 ? value : -value
            } else if exponent == 31 {
                return mantissa == 0 ? (sign == 0 ? Float.infinity : -Float.infinity) : Float.nan
            } else {
                let value = powf(2, Float(exponent) - 15) * (1.0 + Float(mantissa) / 1024.0)
                return sign == 0 ? value : -value
            }
        }
        
        // Вычисляем минимум и максимум глубины для нормализации
        var minDepth: Float = Float.infinity
        var maxDepth: Float = -Float.infinity
        var validCount = 0
        
        if isFloat32 {
            let depthPtr = baseAddress.assumingMemoryBound(to: Float32.self)
            for y in 0..<height {
                for x in 0..<width {
                    let depth = depthPtr[y * (bytesPerRow / 4) + x]
                    if depth > 0 && depth.isFinite {
                        minDepth = min(minDepth, depth)
                        maxDepth = max(maxDepth, depth)
                        validCount += 1
                    }
                }
            }
        } else if isFloat16 {
            let depthPtr = baseAddress.assumingMemoryBound(to: UInt16.self)
            for y in 0..<height {
                for x in 0..<width {
                    let f16 = depthPtr[y * (bytesPerRow / 2) + x]
                    let f32 = float16to32(f16)
                    if f32 > 0 && f32.isFinite {
                        minDepth = min(minDepth, f32)
                        maxDepth = max(maxDepth, f32)
                        validCount += 1
                    }
                }
            }
        }
        
        if validCount == 0 {
            minDepth = 0.1
            maxDepth = 5.0
        }
        let range = maxDepth - minDepth
        if range <= 0 { return nil }
        
        // Создаём RGB-изображение
        var rgbData = [UInt8](repeating: 0, count: width * height * 3)
        
        if isFloat32 {
            let depthPtr = baseAddress.assumingMemoryBound(to: Float32.self)
            for y in 0..<height {
                for x in 0..<width {
                    let depth = depthPtr[y * (bytesPerRow / 4) + x]
                    let idx = (y * width + x) * 3
                    if depth <= 0 || !depth.isFinite {
                        rgbData[idx] = 0; rgbData[idx+1] = 0; rgbData[idx+2] = 0
                    } else {
                        let norm = (depth - minDepth) / range
                        // Цветовая карта: синий->зелёный->красный
                        if norm < 0.5 {
                            let t = norm * 2
                            rgbData[idx] = 0
                            rgbData[idx+1] = UInt8(t * 255)
                            rgbData[idx+2] = UInt8((1 - t) * 255)
                        } else {
                            let t = (norm - 0.5) * 2
                            rgbData[idx] = UInt8(t * 255)
                            rgbData[idx+1] = UInt8((1 - t) * 255)
                            rgbData[idx+2] = 0
                        }
                    }
                }
            }
        } else if isFloat16 {
            let depthPtr = baseAddress.assumingMemoryBound(to: UInt16.self)
            for y in 0..<height {
                for x in 0..<width {
                    let f16 = depthPtr[y * (bytesPerRow / 2) + x]
                    let f32 = float16to32(f16)
                    let idx = (y * width + x) * 3
                    if f32 <= 0 || !f32.isFinite {
                        rgbData[idx] = 0; rgbData[idx+1] = 0; rgbData[idx+2] = 0
                    } else {
                        let norm = (f32 - minDepth) / range
                        if norm < 0.5 {
                            let t = norm * 2
                            rgbData[idx] = 0
                            rgbData[idx+1] = UInt8(t * 255)
                            rgbData[idx+2] = UInt8((1 - t) * 255)
                        } else {
                            let t = (norm - 0.5) * 2
                            rgbData[idx] = UInt8(t * 255)
                            rgbData[idx+1] = UInt8((1 - t) * 255)
                            rgbData[idx+2] = 0
                        }
                    }
                }
            }
        }
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        guard let provider = CGDataProvider(data: Data(rgbData) as CFData) else { return nil }
        guard let cgImage = CGImage(width: width, height: height,
                                    bitsPerComponent: 8, bitsPerPixel: 24,
                                    bytesPerRow: width * 3,
                                    space: colorSpace, bitmapInfo: bitmapInfo,
                                    provider: provider, decode: nil, shouldInterpolate: false,
                                    intent: .defaultIntent) else { return nil }
        
        let result = UIImage(cgImage: cgImage)
        print("✅ Depth image created: \(result.size)")
        return result
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
        print("🔄 Display mode switched: \(mode)")
        logToFile("🔄 Display mode switched: \(mode)")
        
        switch mode {
        case .rgbOnly:
            print("📸 Showing RGB only")
            logToFile("📸 Showing RGB only")
        case .depthOnly:
            print("🎯 Showing LiDAR/Depth only")
            logToFile("🎯 Showing LiDAR/Depth only")
        case .both:
            print("📊 Showing both RGB and LiDAR")
            logToFile("📊 Showing both RGB and LiDAR")
        }
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
