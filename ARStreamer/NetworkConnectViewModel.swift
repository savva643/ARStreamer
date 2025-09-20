import Foundation
import Network
import SwiftUI

@MainActor
class NetworkConnectViewModel: ObservableObject {
    @Published var localIP: String? = nil
    @Published var statusText: String = "Ожидание"
    @Published var previewImage: UIImage? = nil
    
    var connection: NWConnection?
    var arStreamer: ARStreamer?
    
    func fetchLocalIP() {
        // Простая попытка взять Wi-Fi IP (en0)
        var address : String?
        var ifaddr : UnsafeMutablePointer<ifaddrs>? = nil
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                defer { ptr = ptr?.pointee.ifa_next }
                guard let interface = ptr?.pointee else { continue }
                let name = String(cString: interface.ifa_name)
                let addrFamily = interface.ifa_addr.pointee.sa_family
                if addrFamily == UInt8(AF_INET) && name == "en0" {
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
    }
    
    func start(mode: ConnectMode) {
        // Пример подключения к серверу
        let host = NWEndpoint.Host("192.168.1.100") // <- IP ПК
        let port = NWEndpoint.Port(integerLiteral: 9000)
        let params = NWParameters.tcp
        connection = NWConnection(host: host, port: port, using: params)
        statusText = "Connecting..."
        
        connection?.stateUpdateHandler = { [weak self] newState in
            DispatchQueue.main.async {
                switch newState {
                    case .ready:
                        self?.statusText = "Connected"
                        self?.startStreaming()
                    case .failed(let err):
                        // NWError не optional, можно напрямую
                        self?.statusText = "Failed: \(err.localizedDescription)"
                    case .waiting(let err):
                        self?.statusText = "Waiting: \(err.localizedDescription)"
                    default:
                        break
                }
            }
        }
        connection?.start(queue: .global())
    }
    
    func startStreaming() {
        // Запускаем ARStreamer — он будет отправлять кадры через connection
        guard let conn = connection else { return }
        arStreamer = ARStreamer(connection: conn, previewCallback: { [weak self] img in
            DispatchQueue.main.async { self?.previewImage = img }
        })
        arStreamer?.startSession()
    }
    
    func disconnect() {
        arStreamer?.stopSession()
        arStreamer = nil
        connection?.cancel()
        connection = nil
        statusText = "Disconnected"
    }
}
