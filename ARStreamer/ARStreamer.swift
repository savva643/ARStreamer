import Foundation
import ARKit
import Network
import UIKit
import VideoToolbox
import CoreMedia
import CoreMotion

// 🔹 РАСШИРЕНИЯ (остаются без изменений)
extension CMDeviceMotion {
    var eulerAngles: (pitch: Double, yaw: Double, roll: Double) {
        let attitude = self.attitude
        return (attitude.pitch, attitude.yaw, attitude.roll)
    }
    
    var acceleration: (x: Double, y: Double, z: Double) {
        return (userAcceleration.x, userAcceleration.y, userAcceleration.z)
    }
}

extension Float {
    func fixed(_ digits: Int) -> String {
        return String(format: "%.\(digits)f", self)
    }
}

class ARStreamer: NSObject, ARSessionDelegate {
    private var connection: NWConnection
    private let previewCallback: (UIImage, UIImage?) -> Void
    private let fpsCallback: ((Int, Int) -> Void)?
    private let session = ARSession()
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
    
    // H.264 кодировщик
    private var encoder: H264Encoder?
    
    // USB менеджер
    private var usbManager: USBEthernetManager?
    
    // Счётчики производительности
    private var lastFrameTime = Date()
    private var frameCount = 0
    private var bytesSent = 0
    private var lidarBytesSent = 0
    private var lastSentTime: TimeInterval = 0
    private var targetFPS: Int = 60
    
    // LiDAR данные
    private var lastDepthMap: CVPixelBuffer?
    private var lastConfidenceMap: CVPixelBuffer?
    
    // 🔹 УДАЛИЛ отдельные порты для LiDAR - используем один порт для всех данных
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
    
    // 🔹 СИНХРОНИЗАЦИЯ
    private var frameSequence: UInt64 = 0
    private var lastSentFrameTime: TimeInterval = 0
    private var frameTimestamps: [UInt64: TimeInterval] = [:]
    
    // 🔹 СЕНСОРЫ
    private let motionManager = CMMotionManager()
    private var lastSensorData: (pitch: Float, yaw: Float, roll: Float, accelX: Float, accelY: Float, accelZ: Float)?
    private var sensorSequence: UInt64 = 0
    private var lastSensorSentTime: TimeInterval = 0
    private var sensorInterval: TimeInterval {
        return 1.0 / Double(targetFPS)
    }
    
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
        session.delegate = self
        
        if streamMode == "TCP_H264" || streamMode == "UDP_H264" {
            setupH264Encoder()
        } else {
            print("🎯 Режим потоковой передачи: \(streamMode)")
        }
        
        // 🔹 ЗАПУСКАЕМ СЕНСОРЫ
        setupSensors()
    }
    
    // 🔹 НАСТРОЙКА СЕНСОРОВ
    private func setupSensors() {
        guard motionManager.isDeviceMotionAvailable else {
            print("⚠️ Датчики движения недоступны")
            return
        }
        
        motionManager.deviceMotionUpdateInterval = sensorInterval
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] (motion, error) in
            guard let self = self, let motion = motion else { return }
            
            let euler = motion.eulerAngles
            let acceleration = motion.acceleration
            
            self.lastSensorData = (
                pitch: Float(euler.pitch),
                yaw: Float(euler.yaw),
                roll: Float(euler.roll),
                accelX: Float(acceleration.x),
                accelY: Float(acceleration.y),
                accelZ: Float(acceleration.z)
            )
        }
        
        print("📱 Датчики движения активированы (60 Hz) - только сбор данных")
    }
    
    // 🔹 ОТПРАВКА ДАННЫХ СЕНСОРОВ
    private func sendSensorData(frame: ARFrame, frameSequence: UInt64) {
        let cameraTransform = frame.camera.transform
        let cameraPosition = simd_make_float3(cameraTransform.columns.3)
        
        let cameraQuaternion = extractQuaternion(from: cameraTransform)
        
        // 🔹 СОЗДАЕМ ДАННЫЕ В ФОРМАТЕ 44 БАЙТА:
        var data = Data()
        
        // 🔹 ПОЗИЦИЯ КАМЕРЫ (3 float = 12 байт)
        withUnsafeBytes(of: cameraPosition.x) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: cameraPosition.y) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: cameraPosition.z) { data.append(contentsOf: $0) }
        
        // 🔹 КВАРТЕРНИОН ВРАЩЕНИЯ (4 float = 16 байт)
        withUnsafeBytes(of: cameraQuaternion.vector.x) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: cameraQuaternion.vector.y) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: cameraQuaternion.vector.z) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: cameraQuaternion.vector.w) { data.append(contentsOf: $0) }
        
        // 🔹 ДАННЫЕ АКСЕЛЕРОМЕТРА (3 float = 12 байт)
        if let sensorData = lastSensorData {
            withUnsafeBytes(of: sensorData.accelX) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: sensorData.accelY) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: sensorData.accelZ) { data.append(contentsOf: $0) }
        } else {
            let zero: Float = 0.0
            withUnsafeBytes(of: zero) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: zero) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: zero) { data.append(contentsOf: $0) }
        }
        
        // 🔹 РЕЗЕРВ (1 float = 4 байта)
        let reserved: Float = 0.0
        withUnsafeBytes(of: reserved) { data.append(contentsOf: $0) }
        
        guard data.count == 44 else {
            print("❌ Неверный размер данных сенсоров: \(data.count)")
            return
        }
        
        print("📱 Отправка данных камеры #\(frameSequence): " +
              "pos(\(cameraPosition.x.fixed(3)), \(cameraPosition.y.fixed(3)), \(cameraPosition.z.fixed(3))) " +
              "rot(\(cameraQuaternion.vector.x.fixed(3)), \(cameraQuaternion.vector.y.fixed(3)), \(cameraQuaternion.vector.z.fixed(3)), \(cameraQuaternion.vector.w.fixed(3)))")
        
        // 🔹 ОТПРАВКА В ЗАВИСИМОСТИ ОТ РЕЖИМА
        switch streamMode {
        case "USB":
            sendUSBSensorData(data, frameSequence: frameSequence)
        case "TCP_JPEG", "TCP_H264":
            sendTCPSensorData(data, frameSequence: frameSequence)
        case "UDP_H264":
            sendUDPSensorData(data, frameSequence: frameSequence)
        default:
            sendUDPSensorData(data, frameSequence: frameSequence)
        }
    }

    // 🔹 ФУНКЦИЯ ДЛЯ ИЗВЛЕЧЕНИЯ КВАРТЕРНИОНА
    private func extractQuaternion(from matrix: simd_float4x4) -> simd_quatf {
        return simd_quatf(matrix)
    }
    
    // 🔹 ОТПРАВКА СЕНСОРОВ ПО TCP (ЧЕРЕЗ ОСНОВНОЕ СОЕДИНЕНИЕ)
    private func sendTCPSensorData(_ data: Data, frameSequence: UInt64) {
        // 🔹 ФОРМАТ: [ТИП:1] + [НОМЕР КАДРА:8] + [РАЗМЕР:4] + [ДАННЫЕ]
        var dataType: UInt8 = 0x03 // Сенсорные данные
        var sequenceBigEndian = frameSequence.bigEndian
        var size = UInt32(data.count).bigEndian
        
        let headerData = Data(bytes: &dataType, count: 1) +
                        Data(bytes: &sequenceBigEndian, count: 8) +
                        Data(bytes: &size, count: 4)
        let fullData = headerData + data
        
        // 🔹 ОТПРАВЛЯЕМ ЧЕРЕЗ ОСНОВНОЕ СОЕДИНЕНИЕ
        connection.send(content: fullData, completion: .contentProcessed({ err in
            if let e = err {
                print("❌ TCP сенсоры send error:", e)
            } else if frameSequence % 60 == 0 {
                print("✅ TCP сенсоры #\(frameSequence) отправлены")
            }
        }))
    }
    
    // 🔹 ОТПРАВКА СЕНСОРОВ ПО UDP (ЧЕРЕЗ ОСНОВНОЕ СОЕДИНЕНИЕ)
    private func sendUDPSensorData(_ data: Data, frameSequence: UInt64) {
        // 🔹 ФОРМАТ: [ТИП:1] + [НОМЕР КАДРА:8] + [РАЗМЕР:4] + [ДАННЫЕ]
        var dataType: UInt8 = 0x03 // Сенсорные данные
        var sequenceBigEndian = frameSequence.bigEndian
        var size = UInt32(data.count).bigEndian
        
        let headerData = Data(bytes: &dataType, count: 1) +
                        Data(bytes: &sequenceBigEndian, count: 8) +
                        Data(bytes: &size, count: 4)
        let fullData = headerData + data
        
        // 🔹 ОТПРАВЛЯЕМ ЧЕРЕЗ ОСНОВНОЕ СОЕДИНЕНИЕ
        connection.send(content: fullData, completion: .contentProcessed({ err in
            if let e = err {
                print("❌ UDP сенсоры send error:", e)
            } else if frameSequence % 60 == 0 {
                print("✅ UDP сенсоры #\(frameSequence) отправлены")
            }
        }))
    }
    
    // 🔹 ОТПРАВКА СЕНСОРОВ ПО USB (без изменений)
    private func sendUSBSensorData(_ data: Data, frameSequence: UInt64) {
        guard let usbManager = usbManager, usbManager.isConnected else { return }
        
        var dataType: UInt8 = 0x03 // Сенсорные данные
        var sequenceBigEndian = frameSequence.bigEndian
        var size = UInt32(data.count).bigEndian
        
        let headerData = Data(bytes: &dataType, count: 1) +
                        Data(bytes: &sequenceBigEndian, count: 8) +
                        Data(bytes: &size, count: 4)
        let fullData = headerData + data
        
        usbManager.sendData(fullData)
        
        if frameSequence % 60 == 0 {
            print("✅ USB сенсоры #\(frameSequence) отправлены")
        }
    }
    
    
    // 🔹 Отправка Feature Points (Point Cloud)
    private func sendFeaturePoints(_ points: [simd_float3], frameSequence: UInt64) {
        var data = Data()
        
        for point in points {
            withUnsafeBytes(of: point.x) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: point.y) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: point.z) { data.append(contentsOf: $0) }
        }
        
        sendData(data, frameSequence: frameSequence, dataType: 0x04)
    }

    // 🔹 Отправка Camera Intrinsics
    private func sendCameraIntrinsics(_ intrinsics: simd_float3x3, resolution: CGSize, frameSequence: UInt64) {
        var data = Data()
        
        // Матрица 3x3
        for row in 0..<3 {
            for col in 0..<3 {
                let value = intrinsics[row][col]
                withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
            }
        }
        
        // Разрешение
        var width = Float(resolution.width)
        var height = Float(resolution.height)
        withUnsafeBytes(of: width) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: height) { data.append(contentsOf: $0) }
        
        sendData(data, frameSequence: frameSequence, dataType: 0x05)
    }

    // 🔹 Отправка Light Estimation
    private func sendLightEstimation(_ light: ARLightEstimate, frameSequence: UInt64) {
        var data = Data()
        
        // Основные параметры
        let intensity = Float(light.ambientIntensity)
        let temperature = Float(light.ambientColorTemperature)
        withUnsafeBytes(of: intensity) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: temperature) { data.append(contentsOf: $0) }
        
        sendData(data, frameSequence: frameSequence, dataType: 0x06)
    }

    
    // Универсальная отправка — по принципу сенсорики
    private func sendData(_ data: Data, frameSequence: UInt64, dataType: UInt8) {
        switch streamMode {
        case "USB":
            sendUSBData(data, frameSequence: frameSequence, dataType: dataType)
        case "TCP_JPEG", "TCP_H264":
            sendTCPData(data, frameSequence: frameSequence, dataType: dataType)
        case "UDP_H264":
            sendUDPData(data, frameSequence: frameSequence, dataType: dataType)
        default:
            sendUDPData(data, frameSequence: frameSequence, dataType: dataType)
        }
    }

    // TCP
    private func sendTCPData(_ data: Data, frameSequence: UInt64, dataType: UInt8) {
        var seq = frameSequence.bigEndian
        var size = UInt32(data.count).bigEndian
        
        let header = Data([dataType]) +
                     Data(bytes: &seq, count: 8) +
                     Data(bytes: &size, count: 4)
        let packet = header + data

        connection.send(content: packet, completion: .contentProcessed({ err in
            if let e = err {
                print("❌ TCP send error:", e)
            } else if frameSequence % 60 == 0 {
                print("✅ TCP пакет \(dataType) #\(frameSequence) отправлен")
            }
        }))
    }

    // UDP
    private func sendUDPData(_ data: Data, frameSequence: UInt64, dataType: UInt8) {
        var seq = frameSequence.bigEndian
        var size = UInt32(data.count).bigEndian
        
        let header = Data([dataType]) +
                     Data(bytes: &seq, count: 8) +
                     Data(bytes: &size, count: 4)
        let packet = header + data

        connection.send(content: packet, completion: .contentProcessed({ err in
            if let e = err {
                print("❌ UDP send error:", e)
            } else if frameSequence % 60 == 0 {
                print("✅ UDP пакет \(dataType) #\(frameSequence) отправлен")
            }
        }))
    }

    // USB
    private func sendUSBData(_ data: Data, frameSequence: UInt64, dataType: UInt8) {
        guard let usbManager = usbManager, usbManager.isConnected else { return }

        var seq = frameSequence.bigEndian
        var size = UInt32(data.count).bigEndian
        
        let header = Data([dataType]) +
                     Data(bytes: &seq, count: 8) +
                     Data(bytes: &size, count: 4)
        let packet = header + data

        usbManager.sendData(packet)

        if frameSequence % 60 == 0 {
            print("✅ USB пакет \(dataType) #\(frameSequence) отправлен")
        }
    }

    
    

    // 🔹 НОВОЕ: Получение хоста сервера
    @MainActor private func getServerHost() -> String? {
        if streamMode == "USB" {
            return USBEthernetManager.usbHostIP
        } else {
            let viewModel = NetworkConnectViewModel()
            return viewModel.serverIP
        }
    }
    
    @MainActor func startStreaming() {
        let config = ARWorldTrackingConfiguration()
        if useLiDAR && ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
            print("🔦 LiDAR активирован")
        }
        
        DispatchQueue.main.async {
            self.session.run(config)
        }
    }
    
    func stopStreaming() {
        DispatchQueue.main.async {
            self.session.pause()
        }
        encoder?.stopEncoding()
        motionManager.stopDeviceMotionUpdates()
    }
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let now = Date().timeIntervalSince1970
        guard now - lastSentTime >= frameInterval else { return }
        lastSentTime = now
        
        let buffer = frame.capturedImage
        guard let uiImage = imageFromPixelBuffer(buffer) else { return }
        
        // 🔹 УВЕЛИЧИВАЕМ СЧЕТЧИК КАДРОВ
        frameSequence += 1
        frameTimestamps[frameSequence] = now
        
        // 🔹 ОТПРАВЛЯЕМ СЕНСОРЫ С ТЕМ ЖЕ НОМЕРОМ КАДРА (СИНХРОННО)
        sendSensorData(frame: frame, frameSequence: frameSequence)
        if let featurePoints = frame.rawFeaturePoints?.points {
            sendFeaturePoints(featurePoints, frameSequence: frameSequence)
        }

        sendCameraIntrinsics(frame.camera.intrinsics, resolution: frame.camera.imageResolution, frameSequence: frameSequence)

        if let light = frame.lightEstimate {
            sendLightEstimation(light, frameSequence: frameSequence)
        }


        // 🔹 Обработка данных LiDAR
        var depthImage: UIImage? = nil
        if useLiDAR, let sceneDepth = frame.sceneDepth {
            depthImage = processDepthData(sceneDepth)
            lastDepthMap = sceneDepth.depthMap
            lastConfidenceMap = sceneDepth.confidenceMap
            
            // 🔹 ОТПРАВЛЯЕМ LiDAR С ТЕМ ЖЕ НОМЕРОМ КАДРА
            if now - lastLidarSentTime >= lidarFrameInterval {
                lastLidarSentTime = now
                sendLiDARData(sceneDepth, frameSequence: frameSequence)
            }
        }
        
        DispatchQueue.main.async { [weak self] in
            switch self?.currentDisplayMode {
            case .rgbOnly:
                self?.previewCallback(uiImage, nil)
            case .depthOnly:
                self?.previewCallback(depthImage ?? uiImage, nil)
            case .both:
                self?.previewCallback(uiImage, depthImage)
            case .none:
                self?.previewCallback(uiImage, nil)
            }
        }
        
        // 🔹 ОТПРАВЛЯЕМ RGB С НОМЕРОМ КАДРА
        processFrame(buffer, uiImage: uiImage, depthImage: depthImage, frameSequence: frameSequence)
        updateStats()
        
        // 🔹 ОЧИСТКА СТАРЫХ МЕТОК
        cleanupOldTimestamps(currentTime: now)
    }
    
    // 🔹 ОБНОВЛЕННАЯ ОТПРАВКА LiDAR ДАННЫХ ДЛЯ TCP/UDP
    private func sendLiDARData(_ depthData: ARDepthData, frameSequence: UInt64) {
        let depthMap = depthData.depthMap
        
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return }
        let height = CVPixelBufferGetHeight(depthMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        
        let dataSize = height * bytesPerRow
        let rawData = Data(bytes: baseAddress, count: dataSize)
        
        print("🔦 Отправка LiDAR кадра #\(frameSequence): \(rawData.count) байт")
        
        // 🔹 ОТПРАВКА В ЗАВИСИМОСТИ ОТ РЕЖИМА
        sendData(rawData, frameSequence: frameSequence, dataType: 0x02)
    }

    // 🔹 ОТПРАВКА LiDAR ПО TCP (ЧЕРЕЗ ОСНОВНОЕ СОЕДИНЕНИЕ)
    private func sendTCPLiDARData(_ data: Data, frameSequence: UInt64) {
        // 🔹 ФОРМАТ: [ТИП:1] + [НОМЕР КАДРА:8] + [РАЗМЕР:4] + [ДАННЫЕ]
        var dataType: UInt8 = 0x02 // LiDAR данные
        var sequenceBigEndian = frameSequence.bigEndian
        var size = UInt32(data.count).bigEndian
        
        let headerData = Data(bytes: &dataType, count: 1) +
                        Data(bytes: &sequenceBigEndian, count: 8) +
                        Data(bytes: &size, count: 4)
        let fullData = headerData + data
        
        // 🔹 ОТПРАВЛЯЕМ ЧЕРЕЗ ОСНОВНОЕ СОЕДИНЕНИЕ
        connection.send(content: fullData, completion: .contentProcessed({ err in
            if let e = err {
                print("❌ TCP LiDAR send error:", e)
            } else {
                print("✅ TCP LiDAR кадр #\(frameSequence) отправлен")
            }
        }))
    }

    // 🔹 ОТПРАВКА LiDAR ПО UDP (ЧЕРЕЗ ОСНОВНОЕ СОЕДИНЕНИЕ)
    private func sendUDPLiDARData(_ data: Data, frameSequence: UInt64) {
        // 🔹 ФОРМАТ: [ТИП:1] + [НОМЕР КАДРА:8] + [РАЗМЕР:4] + [ДАННЫЕ]
        var dataType: UInt8 = 0x02 // LiDAR данные
        var sequenceBigEndian = frameSequence.bigEndian
        var size = UInt32(data.count).bigEndian
        
        let headerData = Data(bytes: &dataType, count: 1) +
                        Data(bytes: &sequenceBigEndian, count: 8) +
                        Data(bytes: &size, count: 4)
        let fullData = headerData + data
        
        // 🔹 ОТПРАВЛЯЕМ ЧЕРЕЗ ОСНОВНОЕ СОЕДИНЕНИЕ
        connection.send(content: fullData, completion: .contentProcessed({ err in
            if let e = err {
                print("❌ UDP LiDAR send error:", e)
            } else {
                print("✅ UDP LiDAR кадр #\(frameSequence) отправлен")
            }
        }))
    }

    // 🔹 ОТПРАВКА LiDAR ПО USB (без изменений)
    private func sendUSBLiDARData(_ data: Data, frameSequence: UInt64) {
        guard let usbManager = usbManager, usbManager.isConnected else { return }
        
        var dataType: UInt8 = 0x02 // LiDAR данные
        var sequenceBigEndian = frameSequence.bigEndian
        var size = UInt32(data.count).bigEndian
        
        let headerData = Data(bytes: &dataType, count: 1) +
                        Data(bytes: &sequenceBigEndian, count: 8) +
                        Data(bytes: &size, count: 4)
        let fullData = headerData + data
        
        usbManager.sendData(fullData)
    }
    
    // 🔹 СТАТИСТИКА
    private func updateStats() {
        frameCount += 1
        
        let current = Date()
        if current.timeIntervalSince(lastFrameTime) >= 1.0 {
            let fps = frameCount
            let totalKBps = (bytesSent + lidarBytesSent) / 1024
            let videoKBps = bytesSent / 1024
            let lidarKBps = lidarBytesSent / 1024
            
            fpsCallback?(fps, totalKBps)
            
            print("""
            📊 Статистика (\(streamMode)):
            🎥 Видео: \(fps) FPS, \(videoKBps) KB/s
            🔦 LiDAR: \(lidarFrameCount) FPS, \(lidarKBps) KB/s
            📡 Всего: \(totalKBps) KB/s
            """)
            
            frameCount = 0
            lidarFrameCount = 0
            bytesSent = 0
            lidarBytesSent = 0
            lastFrameTime = current
        }
    }
    
    // 🔹 НОВОЕ: Получение информации о портах
    @MainActor func getPortInfo() -> String {
        if streamMode == "USB" {
            return "🔌 USB порт: \(USBEthernetManager.usbPort)"
        } else {
            return "🌐 Сетевой порт: \(getServerHost() ?? "—"):\(getCurrentPort())"
        }
    }
    
    private func getCurrentPort() -> String {
        // 🔹 ДОБАВЬТЕ ЛОГИКУ ДЛЯ ПОЛУЧЕНИЯ ПОРТА ИЗ NetworkConnectViewModel
        return "9000" // Заглушка
    }
    
    // 🔹 МЕТОД ДЛЯ СМЕНЫ РЕЖИМА ОТОБРАЖЕНИЯ
    func switchDisplayMode(_ mode: DisplayMode) {
        currentDisplayMode = mode
        print("🎛️ Режим отображения изменен: \(mode)")
    }
    
    // 🔹 ОСТАЛЬНЫЕ МЕТОДЫ БЕЗ ИЗМЕНЕНИЙ
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
    
    private func cleanupOldTimestamps(currentTime: TimeInterval) {
        let threshold: TimeInterval = 2.0
        frameTimestamps = frameTimestamps.filter {
            currentTime - $0.value < threshold
        }
    }
    
    // 🔹 ОБРАБОТКА RGB КАДРОВ
    private func processFrame(_ pixelBuffer: CVPixelBuffer, uiImage: UIImage, depthImage: UIImage?, frameSequence: UInt64) {
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
    
    // 🔹 H.264 КОДИРОВАНИЕ
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
                if let e = err {
                    print("❌ UDP H.264 send error:", e)
                } else {
                    print("✅ H.264 кадр #\(frameSequence) отправлен")
                }
            }))
        } else {
            var size = UInt32(fullData.count).bigEndian
            let sizeData = Data(bytes: &size, count: 4)
            let finalData = sizeData + fullData
            
            connection.send(content: finalData, completion: .contentProcessed({ err in
                if let e = err {
                    print("❌ TCP H.264 send error:", e)
                } else {
                    print("✅ H.264 кадр #\(frameSequence) отправлен")
                }
            }))
        }
    }
    
    // 🔹 ОТПРАВКА JPEG
    private func sendTCPJPEG(_ image: UIImage, frameSequence: UInt64) {
        guard let jpegData = image.jpegData(compressionQuality: compressionQuality) else { return }
        
        // 🔹 ФОРМАТ: [ТИП:1] + [НОМЕР КАДРА:8] + [РАЗМЕР:4] + [JPEG]
        var dataType: UInt8 = 0x01 // RGB данные
        var sequenceBigEndian = frameSequence.bigEndian
        var size = UInt32(jpegData.count).bigEndian
        
        let headerData = Data(bytes: &dataType, count: 1) +
                        Data(bytes: &sequenceBigEndian, count: 8) +
                        Data(bytes: &size, count: 4)
        let fullData = headerData + jpegData
        
        bytesSent += fullData.count
        
        connection.send(content: fullData, completion: .contentProcessed({ err in
            if let e = err {
                print("TCP send error:", e)
            } else {
                print("✅ RGB кадр #\(frameSequence) отправлен")
            }
        }))
    }
    
    // 🔹 ОТПРАВКА USB (без изменений)
    private func sendUSBFrame(_ image: UIImage, frameSequence: UInt64) {
        guard let usbManager = usbManager, usbManager.isConnected else { return }
        
        guard let jpegData = image.jpegData(compressionQuality: usbCompressionQuality) else { return }
        
        var dataType: UInt8 = 0x01 // RGB данные
        var sequenceBigEndian = frameSequence.bigEndian
        var frameSize = UInt32(jpegData.count).bigEndian
        
        let headerData = Data(bytes: &dataType, count: 1) +
                        Data(bytes: &sequenceBigEndian, count: 8) +
                        Data(bytes: &frameSize, count: 4)
        let packetData = headerData + jpegData
        
        usbManager.sendData(packetData)
    }
    
    
    private func processDepthData(_ depthData: ARDepthData) -> UIImage? {
        let depthMap = depthData.depthMap
        
        // Конвертируем CVPixelBuffer в CIImage
        let ciImage = CIImage(cvPixelBuffer: depthMap)
        
        // 🔹 ДОБАВИЛ: Применяем те же преобразования, что и для RGB
        let deviceOrientation = UIDevice.current.orientation
        let imageOrientation = uiImageOrientation(for: deviceOrientation)
        
        // Создаем трансформации для правильной ориентации
        var transformedImage = ciImage
        
        // Применяем трансформации в зависимости от ориентации
        switch imageOrientation {
        case .right:
            // Портретная ориентация
            transformedImage = ciImage.transformed(by: CGAffineTransform(rotationAngle: -.pi/2))
        case .left:
            // Портретная перевернутая
            transformedImage = ciImage.transformed(by: CGAffineTransform(rotationAngle: .pi/2))
        case .down:
            // Ландшафт лево
            transformedImage = ciImage.transformed(by: CGAffineTransform(rotationAngle: .pi))
        default:
            // Ландшафт право или другие
            break
        }
        
        // 🔹 ДОБАВИЛ: Масштабирование до нужного размера
        let targetSize = CGSize(width: 720, height: 1280)
        let scaleX = targetSize.width / transformedImage.extent.width
        let scaleY = targetSize.height / transformedImage.extent.height
        let scale = min(scaleX, scaleY)
        
        let scaledImage = transformedImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        
        // Конвертируем в CGImage
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
        
        // Создаем UIImage с правильной ориентацией
        return UIImage(cgImage: cgImage, scale: 1.0, orientation: .up)
    }

    // 🔹 ИСПРАВИЛ: Метод для создания изображения из pixel buffer
    private func imageFromPixelBuffer(_ buffer: CVPixelBuffer) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        
        // 🔹 УЛУЧШИЛ: Применяем правильные трансформации
        let deviceOrientation = UIDevice.current.orientation
        let imageOrientation = uiImageOrientation(for: deviceOrientation)
        
        var transformedImage = ciImage
        
        // Применяем трансформации для правильной ориентации
        switch imageOrientation {
        case .right:
            transformedImage = ciImage.transformed(by: CGAffineTransform(rotationAngle: -.pi/2))
        case .left:
            transformedImage = ciImage.transformed(by: CGAffineTransform(rotationAngle: .pi/2))
        case .down:
            transformedImage = ciImage.transformed(by: CGAffineTransform(rotationAngle: .pi))
        default:
            break
        }
        
        // 🔹 ДОБАВИЛ: Масштабирование для консистентности с LiDAR
        let targetSize = CGSize(width: 720, height: 1280)
        let scaleX = targetSize.width / transformedImage.extent.width
        let scaleY = targetSize.height / transformedImage.extent.height
        let scale = min(scaleX, scaleY)
        
        let scaledImage = transformedImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
        
        return UIImage(cgImage: cgImage, scale: 1.0, orientation: .up)
    }
    
    private func uiImageOrientation(for deviceOrientation: UIDeviceOrientation) -> UIImage.Orientation {
        switch deviceOrientation {
        case .portrait: return .right
        case .portraitUpsideDown: return .left
        case .landscapeLeft: return .up
        case .landscapeRight: return .down
        default: return .right
        }
    }
    
    // 🔹 МЕТОД ДЛЯ СМЕНЫ РЕЖИМА НА ЛЕТУ
    func switchToUSBMode(usbManager: USBEthernetManager) {
        self.usbManager = usbManager
        self.streamMode = "USB"
        encoder?.stopEncoding()
        encoder = nil
        print("🎯 Переключено в USB режим")
    }
    
    func switchToNetworkMode(mode: String, connection: NWConnection) {
        self.connection = connection
        self.streamMode = mode
        self.usbManager = nil
        
        if mode == "TCP_H264" || mode == "UDP_H264" {
            setupH264Encoder()
        }
        print("🎯 Переключено в сетевой режим: \(mode)")
    }
    
    deinit {
        encoder?.stopEncoding()
    }
}
