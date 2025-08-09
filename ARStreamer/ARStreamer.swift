import Foundation
import ARKit
import Network
import SwiftUI

class ARStreamer: NSObject, ObservableObject, ARSessionDelegate {
    @Published var isStreaming = false
    @Published var deviceIP: String?
    let port: UInt16 = 5555
    
    let session = ARSession()
    private var connection: NWConnection?
    
    override init() {
        super.init()
        session.delegate = self
        deviceIP = getWiFiAddress()
    }
    
    func start() {
        guard let host = deviceIP else { return }
        
        // Настройка UDP
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .udp)
        connection?.start(queue: .global())
        
        // Настройка ARKit
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics = .sceneDepth
        config.environmentTexturing = .automatic
        session.run(config)
        
        DispatchQueue.main.async {
            self.isStreaming = true
        }
    }
    
    func stop() {
        session.pause()
        connection?.cancel()
        
        DispatchQueue.main.async {
            self.isStreaming = false
        }
    }
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let pixelBuffer = frame.capturedImage
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        
        if let jpegData = context.jpegRepresentation(of: ciImage, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [:]) {
            connection?.send(content: jpegData, completion: .contentProcessed { _ in })
        }
    }
    
    private func getWiFiAddress() -> String? {
        var address : String?
        var ifaddr : UnsafeMutablePointer<ifaddrs>? = nil
        
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                defer { ptr = ptr?.pointee.ifa_next }
                
                let interface = ptr?.pointee
                let addrFamily = interface?.ifa_addr.pointee.sa_family
                if addrFamily == UInt8(AF_INET) {
                    if let name = String(validatingUTF8: (interface?.ifa_name)!), name == "en0" {
                        var addr = interface?.ifa_addr.pointee
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(&addr!, socklen_t(interface!.ifa_addr.pointee.sa_len),
                                    &hostname, socklen_t(hostname.count),
                                    nil, socklen_t(0), NI_NUMERICHOST)
                        address = String(cString: hostname)
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        return address
    }
}
