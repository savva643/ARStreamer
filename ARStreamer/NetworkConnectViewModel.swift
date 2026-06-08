import Foundation
import Network
import SwiftUI
import Combine

// 🔹 ЛОГИРОВАНИЕ В ФАЙЛ
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

@MainActor
class NetworkConnectViewModel: ObservableObject {
    @Published var localIP: String? = nil
    @Published var statusText: String = "Ожидание"
    @Published var previewImage: UIImage? = nil
    @Published var depthPreviewImage: UIImage? = nil // 🔹 ДОБАВИЛ: изображение глубины
    @Published var fpsText: String = "0"
    @Published var networkSpeedText: String = "0 KB/s"
    @Published var pingText: String = "— ms"
    @Published var localIPText: String = "—"
    @Published var serverIPText: String = "—"
    @Published var frameCount: Int = 0 // 🔹 НОВОЕ: счетчик фреймов для отслеживания
    @Published var imuText: String = "IMU: —" // 🔹 НОВОЕ: отображение IMU данных
    @Published var positionText: String = "Pos: —" // 🔹 НОВОЕ: отображение позиции
    
    // 🔹 ЗАЩИТА ОТ ДУБЛИРОВАНИЯ LiDAR
    private var lastDepthImage: UIImage? = nil

    @AppStorage("serverIP") var serverIP: String = "192.168.1.100"
    @AppStorage("serverPort") private var serverPort: String = "9000"
    @AppStorage("streamMode") private var streamMode: String = "TCP_JPEG"
    @AppStorage("sendDepth") var sendDepth: Bool = false
    @AppStorage("targetFPS") private var targetFPS: String = "60"
    
    private var connection: NWConnection?
    private var arStreamer: ARStreamer?
    private var pingTimer: Timer?
    private var usbManager: USBEthernetManager?
    
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Получение локального IP
    func fetchLocalIP() {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                defer { ptr = ptr?.pointee.ifa_next }
                guard let interface = ptr?.pointee else { continue }
                let name = String(cString: interface.ifa_name)
                let addrFamily = interface.ifa_addr.pointee.sa_family
                if addrFamily == UInt8(AF_INET), name == "en0" {
                    var addr = interface.ifa_addr.pointee
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(&addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count),
                                nil, 0, NI_NUMERICHOST)
                    address = String(cString: hostname)
                }
            }
            freeifaddrs(ifaddr)
        }
        self.localIP = address ?? "0.0.0.0"
        self.localIPText = "📶 Локальный IP: \(self.localIP ?? "—")"
    }

    // MARK: - Подключение
    func start() {
        // 🔹 РАЗДЕЛЕНИЕ USB И СЕТЕВЫХ РЕЖИМОВ
        if streamMode.uppercased() == "USB" {
            startUSBStream()
            return
        }
        
        // 🔹 СЕТЕВЫЕ РЕЖИМЫ (TCP/UDP)
        guard let portInt = UInt16(serverPort) else {
            statusText = "Неверный порт"
            return
        }
        
        let host = NWEndpoint.Host(serverIP)
        let port = NWEndpoint.Port(integerLiteral: portInt)
        
        let params: NWParameters
        switch streamMode.uppercased() {
        case "UDP_H264":
            params = NWParameters.udp
            params.requiredInterfaceType = .wifi
        default:
            params = NWParameters.tcp
        }
        
        params.serviceClass = .interactiveVideo
        if let options = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            options.version = .v4
        }

        let connection = NWConnection(host: host, port: port, using: params)
        self.connection = connection
        statusText = "Подключение…"
        self.serverIPText = "🌐 Сервер: \(serverIP):\(serverPort)"

        connection.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor in
                guard let self = self else { return }
                
                // 🔹 ИСПРАВИЛ: явно используем self.streamMode
                let currentStreamMode = self.streamMode
                
                switch newState {
                case .ready:
                    self.statusText = currentStreamMode.uppercased() == "UDP_H264" ?
                        "✅ Подключено (H.264)" : "✅ Подключено (TCP)"
                    self.fetchLocalIP()
                    self.startStreaming()
                    self.startPingTimer()
                case .failed(let err):
                    self.statusText = "❌ Ошибка: \(err.localizedDescription)"
                    self.stopPingTimer()
                case .waiting(let err):
                    self.statusText = "⏳ Ожидание: \(err.localizedDescription)"
                default: break
                }
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
    }
    
    // 🔹 ОТДЕЛЬНЫЙ МЕТОД ДЛЯ USB
    private func startUSBStream() {
        statusText = "🔌 Подключение через USB Ethernet..."
        self.serverIPText = "🔌 USB: поиск подключения..."
        
        // Создаем USB менеджер
        usbManager = USBEthernetManager()
        
        // 🔹 ПРОСТАЯ ОБРАБОТКА СТАТУСА БЕЗ Combine
        // Запускаем проверку статуса через таймер
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self = self, let usbManager = self.usbManager else {
                    timer.invalidate()
                    return
                }
                
                // Обновляем статус
                self.statusText = usbManager.connectionStatus
                
                // Если подключились, запускаем стриминг
                if usbManager.isConnected && self.arStreamer == nil {
                    self.statusText = "✅ USB подключено - начинаем трансляцию"
                    timer.invalidate()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.startStreaming()
                    }
                }
                
                // Если USB менеджер уничтожен, останавливаем таймер
                if self.usbManager == nil {
                    timer.invalidate()
                }
            }
        }
        
        // 🔹 УСТАНАВЛИВАЕМ CALLBACK ДЛЯ ЗАПУСКА СТРИМИНГА
        usbManager?.onConnectionReady = { [weak self] in
            print("📡 USB connection ready callback triggered")
            DispatchQueue.main.async {
                self?.statusText = "✅ USB подключено - начинаем трансляцию"
                self?.startStreaming()
            }
        }
        
        // 🔹 ЗАПУСКАЕМ ПОИСК ПОДКЛЮЧЕНИЯ
        usbManager?.startUSBConnection()
    }

    // MARK: - Запуск стриминга
    private func startStreaming() {
        logToFile("🎬 startStreaming() called with streamMode=\(streamMode)")
        statusText = "🎬 Инициализация камеры..."
        logToFile("statusText set to: 🎬 Инициализация камеры...")
        
        // 🔹 ИСПРАВЛЕНИЕ: для USB создаем фиктивное соединение
        let effectiveConnection: NWConnection
        
        if streamMode.uppercased() == "USB" {
            logToFile("Creating dummy connection for USB mode")
            // Создаем фиктивное соединение для USB (оно не будет использоваться)
            let host = NWEndpoint.Host("127.0.0.1")
            let port = NWEndpoint.Port(integerLiteral: 1)
            effectiveConnection = NWConnection(host: host, port: port, using: .tcp)
        } else {
            guard let connection = connection else {
                logToFile("❌ No connection for network mode")
                statusText = "❌ Ошибка: нет соединения"
                return
            }
            effectiveConnection = connection
        }
        
        let fps = Int(targetFPS) ?? 60
        
        // 🔹 СИНХРОНИЗИРУЕМ LiDAR С НАСТРОЙКАМИ
        let shouldUseLiDAR = self.sendDepth
        
        logToFile("🎬 Creating ARStreamer: useLiDAR=\(shouldUseLiDAR), fps=\(fps)")
        statusText = "🎬 Создание ARStreamer..."
        logToFile("statusText set to: 🎬 Создание ARStreamer...")
        
        // 🔹 ИСПРАВИЛ: правильный callback с двумя изображениями
        arStreamer = ARStreamer(
            connection: effectiveConnection,
            useLiDAR: shouldUseLiDAR,
            streamMode: streamMode,
            compressionQuality: 0.8,
            targetFPS: fps,
            previewCallback: { [weak self] rgbImage, depthImage in
                let msg = "📸 previewCallback: rgbImage=\(rgbImage.size), depthImage=\(depthImage?.size ?? .zero)"
                logToFile(msg)
                
                // 🔹 ЗАЩИТА ОТ ДУБЛИРОВАНИЯ: если depthImage такой же как предыдущий - игнорируем
                if let depthImg = depthImage, let self = self {
                    if let lastDepth = self.lastDepthImage, lastDepth === depthImg {
                        logToFile("⚠️ DUPLICATE depth image detected - skipping")
                        return
                    }
                    self.lastDepthImage = depthImg
                }
                
                Task { @MainActor in
                    logToFile("📸 Setting previewImage on MainActor: \(rgbImage.size)")
                    self?.previewImage = rgbImage
                    logToFile("✅ previewImage set: \(self?.previewImage?.size ?? .zero)")
                    
                    // 🔹 ВАЖНО: обновляем depthPreviewImage
                    if let depthImg = depthImage {
                        self?.depthPreviewImage = depthImg
                        logToFile("✅ depthPreviewImage set: \(depthImg.size)")
                    } else {
                        logToFile("⚠️ depthPreviewImage is nil")
                    }
                    
                    self?.statusText = "📹 Видео: \(Int(rgbImage.size.width))x\(Int(rgbImage.size.height))"
                    logToFile("✅ statusText updated: \(self?.statusText ?? "nil")")
                    // 🔹 ВАЖНО: увеличиваем счетчик чтобы onChange срабатывал
                    self?.frameCount += 1
                    logToFile("📊 frameCount incremented: \(self?.frameCount ?? 0)")
                }
            },
            fpsCallback: { [weak self] fps, bytes in
                Task { @MainActor in
                    self?.fpsText = "\(fps) FPS"
                    self?.networkSpeedText = "\(bytes / 1024) KB/s"
                }
            },
            usbManager: streamMode.uppercased() == "USB" ? usbManager : nil
        )
        
        // 🔹 ДОБАВИЛ: callback для обновления IMU и позиции
        arStreamer?.imuUpdateCallback = { [weak self] imuStr, posStr in
            Task { @MainActor in
                self?.imuText = imuStr
                self?.positionText = posStr
            }
        }
        
        logToFile("🎬 ARStreamer created, calling startStreaming()")
        statusText = "🎬 Запуск камеры..."
        logToFile("statusText set to: 🎬 Запуск камеры...")
        
        // 🔹 ВАЖНО: для USB сразу запускаем AR сессию
        logToFile("Calling arStreamer?.startStreaming()")
        arStreamer?.startStreaming()
        logToFile("✅ arStreamer?.startStreaming() completed")
        
        logToFile("🎬 startStreaming() completed")
        statusText = "⏳ Ожидание видео от камеры..."
        logToFile("statusText set to: ⏳ Ожидание видео от камеры...")
    }

    func switchDisplayMode(_ mode: ARStreamer.DisplayMode) {
        arStreamer?.switchDisplayMode(mode)
        // 🔹 Сбрасываем lastDepthImage при смене режима чтобы избежать конфликтов
        lastDepthImage = nil
    }
    
    // MARK: - Перезапуск
    func restartSession(useLiDAR: Bool) {
        print("🔄 restartSession called: useLiDAR=\(useLiDAR)")
        logToFile("🔄 restartSession called: useLiDAR=\(useLiDAR)")
        
        // 🔹 ОБНОВЛЯЕМ НАСТРОЙКУ sendDepth при изменении LiDAR
        self.sendDepth = useLiDAR
        
        // 🔹 ВАЖНО: запускаем в фоне чтобы не заморозить UI
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            print("🔄 Stopping old session...")
            self?.arStreamer?.stopStreaming()
            
            guard let connection = self?.connection else {
                print("❌ restartSession: connection is nil")
                return
            }
            
            let fps = Int(self?.targetFPS ?? "60") ?? 60
            
            print("🔄 Creating new ARStreamer with useLiDAR=\(useLiDAR)")
            
            // 🔹 ИСПРАВИЛ: правильный callback с двумя изображениями
            let newStreamer = ARStreamer(
                connection: connection,
                useLiDAR: useLiDAR,
                streamMode: self?.streamMode ?? "TCP_JPEG",
                compressionQuality: 0.8,
                targetFPS: fps,
                previewCallback: { [weak self] rgbImage, depthImage in
                    print("📸 previewCallback (restartSession): rgbImage=\(rgbImage.size), depthImage=\(depthImage?.size ?? .zero)")
                    
                    // 🔹 ЗАЩИТА ОТ ДУБЛИРОВАНИЯ
                    if let depthImg = depthImage, let self = self {
                        if let lastDepth = self.lastDepthImage, lastDepth === depthImg {
                            print("⚠️ DUPLICATE depth image detected in restartSession - skipping")
                            return
                        }
                        self.lastDepthImage = depthImg
                    }
                    
                    Task { @MainActor in
                        self?.previewImage = rgbImage
                        self?.depthPreviewImage = depthImage
                    }
                },
                fpsCallback: { [weak self] fps, bytes in
                    Task { @MainActor in
                        self?.fpsText = "\(fps)"
                        self?.networkSpeedText = "\(bytes / 1024) KB/s"
                    }
                },
                usbManager: (self?.streamMode.uppercased() == "USB") ? self?.usbManager : nil
            )
            
            DispatchQueue.main.async {
                self?.arStreamer = newStreamer
                print("🔄 Starting new session...")
                self?.arStreamer?.startStreaming()
                print("✅ restartSession completed")
                logToFile("✅ restartSession completed")
            }
        }
    }
    
    // MARK: - Отключение
    func disconnect() {
        stopPingTimer()
        arStreamer?.stopStreaming()
        arStreamer = nil
        
        // 🔹 ИСПРАВИЛ: явно используем self.streamMode
        if self.streamMode.uppercased() == "USB" {
            usbManager?.disconnect()
            usbManager = nil
            statusText = "🔴 USB отключено"
        } else {
            connection?.cancel()
            connection = nil
            statusText = "🔴 Отключено"
        }
        
        // 🔹 ОЧИЩАЕМ ИЗОБРАЖЕНИЯ
        previewImage = nil
        depthPreviewImage = nil
        lastDepthImage = nil
    }

    // MARK: - Пинг (только для сетевых режимов)
    private func startPingTimer() {
        // 🔹 ИСПРАВИЛ: явно используем self.streamMode
        guard self.streamMode.uppercased() != "USB" else { return }
        
        stopPingTimer()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                let hostString = self.serverIP
                let portString = self.serverPort
                self.pingServerDetached(host: hostString, portString: portString)
            }
        }
    }

    private func stopPingTimer() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    private func pingServerDetached(host: String, portString: String) {
        guard let portInt = UInt16(portString) else {
            Task { @MainActor in self.pingText = "— ms" }
            return
        }

        Task.detached {
            let startTime = Date()
            let hostEndpoint = NWEndpoint.Host(host)
            let port = NWEndpoint.Port(integerLiteral: portInt)
            let pingConnection = NWConnection(host: hostEndpoint, port: port, using: .tcp)

            pingConnection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let latency = Int(Date().timeIntervalSince(startTime) * 1000)
                    Task { @MainActor in
                        self.pingText = "\(latency) ms"
                    }
                    pingConnection.cancel()
                case .failed(_):
                    Task { @MainActor in
                        self.pingText = "— ms"
                    }
                    pingConnection.cancel()
                default:
                    break
                }
            }
            pingConnection.start(queue: .global())
        }
    }
}

// MARK: — Debug convenience computed properties
extension NetworkConnectViewModel {
    var currentIP: String {
        // 🔹 ИСПРАВИЛ: явно используем self.streamMode
        if self.streamMode.uppercased() == "USB" {
            return USBEthernetManager.usbHostIP
        }
        return localIP ?? "—"
    }

    var currentPort: String {
        // 🔹 ИСПРАВИЛ: явно используем self.streamMode
        if self.streamMode.uppercased() == "USB" {
            return "\(USBEthernetManager.usbPort)"
        }
        return serverPort
    }

    var connectionType: String {
        // 🔹 ИСПРАВИЛ: явно используем self.streamMode
        switch self.streamMode.uppercased() {
        case "TCP_JPEG": return "TCP"
        case "UDP_H264": return "UDP"
        case "USB": return "USB"
        default: return "—"
        }
    }
}
