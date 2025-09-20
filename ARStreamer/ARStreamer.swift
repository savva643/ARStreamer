import SwiftUI
import ARKit
import Network
import UIKit
import Accelerate
import Combine

class ARStreamer: NSObject {
    var connection: NWConnection?
    var previewCallback: ((UIImage) -> Void)?
    var session: ARSession

    // Основной инициализатор
    init(connection: NWConnection?, previewCallback: ((UIImage) -> Void)?) {
        self.connection = connection
        self.previewCallback = previewCallback
        self.session = ARSession()
        super.init()
    }

    // Удобный конструктор без параметров
    override convenience init() {
        self.init(connection: nil, previewCallback: nil)
    }
    
    func startSession() {
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        session.run(config)
    }
    
    func stopSession() {
        session.pause()
    }
    
    func sendPacket(type: UInt8, data: Data) {
        var packet = Data()
        packet.append(contentsOf: [0x41,0x52,0x53,0x54]) // 'ARST'
        packet.append(type)
        var len = UInt32(data.count).bigEndian
        packet.append(Data(bytes: &len, count: 4))
        packet.append(data)
        connection.send(content: packet, completion: .contentProcessed({ err in
            if let e = err { print("send err:", e) }
        }))
    }
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        if sendRGB {
            let ciImage = CIImage(cvPixelBuffer: frame.capturedImage)
            let context = CIContext()
            if let cg = context.createCGImage(ciImage, from: ciImage.extent) {
                let ui = UIImage(cgImage: cg, scale: 1.0, orientation: .right)
                if let jpeg = ui.jpegData(compressionQuality: 0.6) {
                    sendPacket(type: 0x01, data: jpeg)
                    previewCallback?(ui)
                }
            }
        }
        
        if sendDepth, let sd = frame.sceneDepth {
            let depthBuffer = sd.depthMap
            if let depthPNG = depthBufferToPNG(depthBuffer) {
                sendPacket(type: 0x02, data: depthPNG)
            }
        }
    }
    
    func depthBufferToPNG(_ buffer: CVPixelBuffer) -> Data? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let count = width*height
        let floatPtr = base.assumingMemoryBound(to: Float32.self)
        var maxVal: Float32 = 0
        for i in 0..<count { maxVal = max(maxVal, floatPtr[i]) }
        let scale: Float32 = maxVal > 0 ? (Float32(UInt16.max) / maxVal) : 1.0
        let uint16Ptr = UnsafeMutablePointer<UInt16>.allocate(capacity: count)
        for i in 0..<count {
            let v = floatPtr[i]*scale
            let vv = UInt16(min(max(v, 0), Float32(UInt16.max)))
            uint16Ptr[i] = vv.bigEndian
        }
        let provider = CGDataProvider(dataInfo: nil, data: uint16Ptr, size: count*MemoryLayout<UInt16>.size) { _, data, _ in
            data.deallocate()
        }
        let cg = CGImage(width: width,
                         height: height,
                         bitsPerComponent: 16,
                         bitsPerPixel: 16,
                         bytesPerRow: width*2,
                         space: CGColorSpaceCreateDeviceGray(),
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                         provider: provider!,
                         decode: nil,
                         shouldInterpolate: false,
                         intent: .defaultIntent)
        if let cg = cg {
            let ui = UIImage(cgImage: cg)
            return ui.pngData()
        }
        return nil
    }
}
