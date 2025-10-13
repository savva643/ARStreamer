import Foundation
import Network

class USBEthernetManager: ObservableObject {
    private var connection: NWConnection?
    private var currentHostIndex = 0
    private var connectionTimer: Timer?
    private var connectionTimeoutTimer: Timer?
    private var scannedIPs: [String] = []
    
    @Published var connectionStatus: String = "Не подключено"
    @Published var isConnected: Bool = false
    
    // 🔹 ТЕПЕРЬ ИСПОЛЬЗУЕМ ТОЛЬКО ОДИН ПОРТ ДЛЯ ВСЕХ ДАННЫХ
    static let usbPort: UInt16 = 9001
    
    // 🔹 ОСНОВНОЙ IP ДЛЯ ОТОБРАЖЕНИЯ
    static var usbHostIP: String = "172.20.10.3"
    
    // 🔹 ДИНАМИЧЕСКИЙ СПИСОК IP ДЛЯ ПОДКЛЮЧЕНИЯ
    var possibleHostIPs: [String] {
        if scannedIPs.isEmpty {
            return [
                "172.20.10.3",      // 🔹 IP вашего ПК
                "172.20.10.1",      // iPhone как шлюз
                "169.254.2.1",      // Link-Local
                "192.168.0.100",    // Домашняя сеть
                "192.168.1.100",    // Другая домашняя сеть
                "10.0.0.100"        // Корпоративная сеть
            ]
        } else {
            return scannedIPs
        }
    }
    
    // 🔹 АВТОМАТИЧЕСКОЕ СКАНИРОВАНИЕ СЕТИ (без изменений)
    func scanNetworkForHosts() -> [String] {
        var foundIPs: [String] = []
        
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return foundIPs }
        defer { freeifaddrs(ifaddr) }
        
        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            guard let interface = ptr?.pointee else { continue }
            
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                
                if (name.hasPrefix("en") || name.hasPrefix("utun") || name.hasPrefix("eth")) && name != "en0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                              &hostname, socklen_t(hostname.count),
                              nil, 0, NI_NUMERICHOST)
                    let localIP = String(cString: hostname)
                    
                    print("🔍 Найден сетевой интерфейс \(name) с IP: \(localIP)")
                    
                    let networkIPs = generatePossibleIPs(for: localIP)
                    foundIPs.append(contentsOf: networkIPs)
                }
            }
        }
        
        foundIPs = Array(Set(foundIPs)).sorted { ip1, ip2 in
            if ip1.hasSuffix(".1") || ip1.hasSuffix(".2") || ip1.hasSuffix(".3") {
                return true
            }
            if ip2.hasSuffix(".1") || ip2.hasSuffix(".2") || ip2.hasSuffix(".3") {
                return false
            }
            return ip1 < ip2
        }
        
        print("🎯 Найдены IP для сканирования: \(foundIPs)")
        return foundIPs
    }
    
    private func generatePossibleIPs(for localIP: String) -> [String] {
        var possibleIPs: [String] = []
        
        let components = localIP.split(separator: ".")
        guard components.count == 4 else { return possibleIPs }
        
        let networkPrefix = components[0...2].joined(separator: ".")
        
        for i in 1...10 {
            let ip = "\(networkPrefix).\(i)"
            possibleIPs.append(ip)
        }
        
        if localIP.hasPrefix("172.20.10") {
            possibleIPs.append(contentsOf: ["172.20.10.1", "172.20.10.2", "172.20.10.3", "172.20.10.4"])
        } else if localIP.hasPrefix("169.254") {
            possibleIPs.append(contentsOf: ["169.254.1.1", "169.254.2.1", "169.254.0.1"])
        } else if localIP.hasPrefix("192.168") {
            let thirdOctet = components[2]
            possibleIPs.append(contentsOf: ["192.168.\(thirdOctet).1", "192.168.\(thirdOctet).100", "192.168.\(thirdOctet).254"])
        }
        
        return possibleIPs
    }
    
    // 🔹 ОБНОВЛЕННЫЙ МЕТОД START USB CONNECTION
    func startUSBConnection() {
        disconnect()
        
        connectionStatus = "🔍 Сканирование сети..."
        isConnected = false
        
        scannedIPs = scanNetworkForHosts()
        
        if scannedIPs.isEmpty {
            connectionStatus = "⚠️ Сеть не найдена, использую статический список"
        } else {
            connectionStatus = "🎯 Найдено \(scannedIPs.count) IP для проверки"
        }
        
        currentHostIndex = 0
        attemptNextConnection()
        
        connectionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if !self.isConnected {
                self.attemptNextConnection()
            } else {
                self.connectionTimer?.invalidate()
                self.connectionTimer = nil
            }
        }
    }
    
    private func attemptNextConnection() {
        let ips = possibleHostIPs
        
        guard currentHostIndex < ips.count else {
            currentHostIndex = 0
            connectionStatus = "🔄 Перебор IP адресов (\(ips.count))..."
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                guard let self = self, !self.isConnected else { return }
                self.connectionStatus = "🔄 Пересканирование сети..."
                self.startUSBConnection()
            }
            return
        }
        
        let hostIP = ips[currentHostIndex]
        currentHostIndex += 1
        
        USBEthernetManager.usbHostIP = hostIP
        
        connectionStatus = "🔌 Подключение к \(hostIP)..."
        print("USB: Попытка \(currentHostIndex)/\(ips.count) к \(hostIP)")
        
        attemptConnection(to: hostIP)
    }
    
    private func attemptConnection(to hostIP: String) {
        let host = NWEndpoint.Host(hostIP)
        let port = NWEndpoint.Port(integerLiteral: USBEthernetManager.usbPort)
        
        let params = NWParameters.tcp
        params.serviceClass = .interactiveVideo
        
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        params.defaultProtocolStack.transportProtocol = tcpOptions
        
        connection = NWConnection(host: host, port: port, using: params)
        
        startConnectionTimeoutTimer()
        
        connection?.stateUpdateHandler = { [weak self] newState in
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                self.connectionTimeoutTimer?.invalidate()
                self.connectionTimeoutTimer = nil
                
                switch newState {
                case .ready:
                    self.connectionTimer?.invalidate()
                    self.connectionTimer = nil
                    self.connectionStatus = "✅ Подключено к \(hostIP)"
                    self.isConnected = true
                    print("🎉 USB Ethernet: успешное подключение к \(hostIP)")
                    
                    USBEthernetManager.usbHostIP = hostIP
                    self.startReceiving()
                    
                case .failed(let error):
                    print("❌ Подключение к \(hostIP) не удалось: \(error.localizedDescription)")
                    
                    if !self.isConnected {
                        self.connectionStatus = "❌ \(hostIP) недоступен"
                    }
                    
                case .waiting(let error):
                    print("⏳ Ожидание подключения к \(hostIP): \(error.localizedDescription)")
                    self.connectionStatus = "⏳ Ожидание \(hostIP)..."
                    self.startConnectionTimeoutTimer()
                    
                case .cancelled:
                    if !self.isConnected {
                        self.connectionStatus = "🔴 Подключение отменено"
                    }
                    
                case .preparing:
                    self.connectionStatus = "⚙️ Подготовка \(hostIP)..."
                    
                default:
                    break
                }
            }
        }
        
        connection?.start(queue: .global(qos: .userInitiated))
    }
    
    private func startConnectionTimeoutTimer() {
        connectionTimeoutTimer?.invalidate()
        connectionTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            
            if !self.isConnected {
                print("⏰ Таймаут подключения к \(USBEthernetManager.usbHostIP)")
                self.connection?.cancel()
                self.connectionStatus = "⏰ Таймаут подключения"
            }
        }
    }
    
    func connectToSpecificIP(_ hostIP: String) {
        disconnect()
        connectionStatus = "🔌 Ручное подключение к \(hostIP)..."
        
        if !scannedIPs.contains(hostIP) {
            scannedIPs.insert(hostIP, at: 0)
        }
        
        USBEthernetManager.usbHostIP = hostIP
        attemptConnection(to: hostIP)
    }
    
    func refreshNetworkScan() {
        connectionStatus = "🔍 Обновление списка IP..."
        scannedIPs = scanNetworkForHosts()
        connectionStatus = "🎯 Обновлено: \(scannedIPs.count) IP"
    }
    
    private func startReceiving() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, context, isComplete, error in
            guard let self = self else { return }
            
            if let data = data, !data.isEmpty {
                print("📥 USB получены данные: \(data.count) байт")
                // Обработка полученных данных
            }
            
            if let error = error {
                print("❌ USB ошибка получения: \(error)")
                if self.isConnected {
                    DispatchQueue.main.async {
                        self.connectionStatus = "❌ Ошибка связи"
                        self.isConnected = false
                        self.startUSBConnection()
                    }
                }
                return
            }
            
            if self.isConnected {
                self.startReceiving()
            }
        }
    }
    
    // 🔹 УПРОЩЕННЫЙ МЕТОД ОТПРАВКИ ДАННЫХ
    func sendData(_ data: Data) {
        guard isConnected, let connection = connection else {
            print("⚠️ USB: соединение не готово для отправки")
            return
        }
        
        connection.send(content: data, completion: .contentProcessed({ error in
            if let error = error {
                print("❌ USB ошибка отправки: \(error)")
                DispatchQueue.main.async {
                    if self.isConnected {
                        self.connectionStatus = "❌ Ошибка отправки"
                        self.isConnected = false
                        self.startUSBConnection()
                    }
                }
            } else {
                // 🔹 ЛОГИРОВАНИЕ ПО ТИПУ ДАННЫХ
                if data.count >= 1 {
                    let dataType = data[0]
                    switch dataType {
                    case 0x01:
                        print("📤 USB RGB отправлен | размер: \(data.count) байт")
                    case 0x02:
                        print("📤 USB LiDAR отправлен | размер: \(data.count) байт")
                    case 0x03:
                        print("📤 USB сенсоры отправлены | размер: \(data.count) байт")
                    default:
                        print("📤 USB данные отправлены | размер: \(data.count) байт")
                    }
                }
            }
        }))
    }
    
    func disconnect() {
        connectionTimer?.invalidate()
        connectionTimer = nil
        connectionTimeoutTimer?.invalidate()
        connectionTimeoutTimer = nil
        
        connection?.cancel()
        connection = nil
        
        isConnected = false
        connectionStatus = "🔴 USB отключено"
        print("🔴 USB соединение закрыто")
    }
    
    deinit {
        disconnect()
    }
}
