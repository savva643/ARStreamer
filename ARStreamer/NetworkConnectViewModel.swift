import Foundation
import Network
import SwiftUI
import Combine

// 🔹 ЛОГИРОВАНИЕ В ФАЙЛ
// Асинхронно на отдельной очереди, файл открыт один раз: логирование больше не тормозит
// видео/IMU потоки (раньше каждый вызов создавал DateFormatter и открывал файл).
private final class FileLogger {
    static let shared = FileLogger()

    private let queue = DispatchQueue(label: "glaski.log", qos: .utility)
    private var handle: FileHandle?
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init() {
        queue.async {
            guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            let url = dir.appendingPathComponent("ARStreamer.log")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            self.handle = try? FileHandle(forWritingTo: url)
            self.handle?.seekToEndOfFile()
        }
    }

    func write(_ message: String) {
        let now = Date()
        queue.async {
            let line = "[\(self.formatter.string(from: now))] \(message)\n"
            if let data = line.data(using: .utf8) {
                self.handle?.write(data)
            }
        }
    }
}

func logToFile(_ message: String) {
    FileLogger.shared.write(message)
    #if DEBUG
    print(message)
    #endif
}

/// Приём от ПК по Wi-Fi (картинка лаунчера для экрана телефона). Вне MainActor: колбэки NWConnection — на её очереди.
private func receiveFromPC(_ connection: NWConnection) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
        if let data = data, !data.isEmpty {
            ReturnDisplay.shared.feed(data)
        }
        if error == nil && !isComplete {
            receiveFromPC(connection)
        }
    }
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
    @AppStorage("streamMode") private var streamModeRaw: String = "USB"
    @AppStorage("sendDepth") var sendDepth: Bool = false
    @AppStorage("sendMicrophone") var sendMicrophone: Bool = false
    @AppStorage("targetFPS") private var targetFPS: String = "60"
    @AppStorage("videoCodec") private var videoCodec: String = "H264"
    @AppStorage("videoResolution") private var videoResolution: String = "1440p"
    @AppStorage("bitrateMbps") private var bitrateMbps: String = "30"

    /// UDP_H264 из старых версий больше не поддерживается (кадры > 64 KB не влезают в датаграмму) → Wi-Fi TCP
    private var streamMode: String {
        let m = streamModeRaw.uppercased()
        return m == "UDP_H264" ? "TCP_H264" : m
    }

    private func makeSettings(useLiDAR: Bool) -> StreamSettings {
        var s = StreamSettings()
        s.streamMode = streamMode
        s.codec = videoCodec
        s.resolution = videoResolution
        s.targetFPS = Int(targetFPS) ?? 60
        s.bitrateMbps = Int(bitrateMbps) ?? 30
        s.useLiDAR = useLiDAR
        s.sendMicrophone = sendMicrophone
        return s
    }
    
    private var connection: NWConnection?
    private var arStreamer: ARStreamer?
    // Состояние превью переживает перезапуск стримера (переключение LiDAR)
    private var displayMode: ARStreamer.DisplayMode = .rgbOnly
    private var previewInterface: UIInterfaceOrientation = .landscapeRight
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
        
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        
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
                    ReturnDisplay.shared.resetStream()
                    receiveFromPC(connection)
                    self.statusText = currentStreamMode == "TCP_JPEG" ?
                        "✅ Подключено (JPEG)" : "✅ Подключено (\(self.videoCodec))"
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
    private func makeStreamer(connection: NWConnection, useLiDAR: Bool) -> ARStreamer {
        let settings = makeSettings(useLiDAR: useLiDAR)
        let streamer = ARStreamer(
            connection: connection,
            settings: settings,
            previewCallback: { [weak self] rgbImage, depthImage in
                Task { @MainActor in
                    guard let self = self else { return }
                    if let depthImg = depthImage {
                        // защита от повторной отправки того же depth-кадра
                        if let last = self.lastDepthImage, last === depthImg { return }
                        self.lastDepthImage = depthImg
                        self.depthPreviewImage = depthImg
                    }
                    if rgbImage.size != .zero {
                        self.previewImage = rgbImage
                        self.statusText = "📹 Трансляция \(settings.resolution) @\(settings.targetFPS)"
                    }
                    // счётчик для перехода в экран трансляции (onChange в ContentView)
                    self.frameCount += 1
                }
            },
            fpsCallback: { [weak self] fps, bytesPerSecond in
                Task { @MainActor in
                    self?.fpsText = "\(fps) FPS"
                    self?.networkSpeedText = "\(bytesPerSecond / 1024) KB/s"
                }
            },
            usbManager: streamMode == "USB" ? usbManager : nil
        )
        streamer.switchDisplayMode(displayMode)
        streamer.setPreviewOrientation(previewInterface)
        streamer.imuUpdateCallback = { [weak self] imuStr, posStr in
            Task { @MainActor in
                self?.imuText = imuStr
                self?.positionText = posStr
            }
        }
        return streamer
    }

    private func startStreaming() {
        logToFile("🎬 startStreaming() streamMode=\(streamMode)")

        let effectiveConnection: NWConnection
        if streamMode == "USB" {
            // Для USB данные идут через USBEthernetManager, NWConnection не используется
            effectiveConnection = NWConnection(host: "127.0.0.1", port: 1, using: .tcp)
        } else {
            guard let connection = connection else {
                logToFile("❌ No connection for network mode")
                statusText = "❌ Ошибка: нет соединения"
                return
            }
            effectiveConnection = connection
        }

        arStreamer?.stopStreaming()
        arStreamer = makeStreamer(connection: effectiveConnection, useLiDAR: sendDepth)
        statusText = "🎬 Запуск камеры..."
        arStreamer?.startStreaming()
        statusText = "⏳ Ожидание видео от камеры..."
    }

    func switchDisplayMode(_ mode: ARStreamer.DisplayMode) {
        displayMode = mode
        arStreamer?.switchDisplayMode(mode)
        lastDepthImage = nil
        // Режимы «ПК → экран»: просим лаунчер рендерить под этот экран (или перестать)
        if mode.returnMode != ReturnDisplay.shared.currentMode {
            ReturnDisplay.shared.request(mode: mode.returnMode)
        }
    }

    /// Поворот превью под ориентацию интерфейса (поток на ПК не поворачивается)
    func setPreviewOrientation(_ orientation: UIInterfaceOrientation) {
        guard orientation != .unknown else { return }
        previewInterface = orientation
        arStreamer?.setPreviewOrientation(orientation)
    }
    
    // MARK: - Перезапуск
    func restartSession(useLiDAR: Bool) {
        logToFile("🔄 restartSession useLiDAR=\(useLiDAR)")
        self.sendDepth = useLiDAR
        if !useLiDAR && (displayMode == .depthOnly || displayMode == .both) {
            displayMode = .rgbOnly
            depthPreviewImage = nil
            lastDepthImage = nil
        }

        arStreamer?.stopStreaming()
        arStreamer = nil

        let connection: NWConnection
        if streamMode == "USB" {
            connection = NWConnection(host: "127.0.0.1", port: 1, using: .tcp)
        } else {
            guard let c = self.connection else {
                logToFile("❌ restartSession: connection is nil")
                return
            }
            connection = c
        }

        // Камере нужно время, чтобы освободиться после stopRunning
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            self.arStreamer = self.makeStreamer(connection: connection, useLiDAR: useLiDAR)
            self.arStreamer?.startStreaming()
        }
    }
    
    // MARK: - Отключение
    func disconnect() {
        stopPingTimer()
        ReturnDisplay.shared.request(mode: .off)
        displayMode = .rgbOnly
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
        case "TCP_JPEG": return "WI-FI JPEG"
        case "TCP_H264": return "WI-FI \(videoCodec)"
        case "USB": return "USB \(videoCodec)"
        default: return "—"
        }
    }

    func sendOrientation(degrees: Double) {
        arStreamer?.sendOrientation(degrees: degrees)
    }
}
