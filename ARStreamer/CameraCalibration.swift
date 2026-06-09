import Foundation
import AVFoundation

/// Калибровка камеры iPhone для получения правильных intrinsics
/// Без ARKit — только на основе физических параметров камеры
class CameraCalibration {
    
    /// Получить intrinsics для задней камеры iPhone
    /// Возвращает: (fx, fy, cx, cy) для RGB камеры
    static func getRGBCameraIntrinsics(for device: AVCaptureDevice) -> (fx: Double, fy: Double, cx: Double, cy: Double) {
        // iPhone 12+ rear camera (wide)
        // Физические параметры из спецификаций Apple
        
        let format = device.activeFormat
        let videoDimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let width = Double(videoDimensions.width)
        let height = Double(videoDimensions.height)
        
        // iPhone 12/13/14/15 rear wide camera
        // Focal length: ~26mm (35mm equivalent)
        // Sensor size: ~1/1.6" (typical for iPhone)
        // Pixel size: ~1.2 micrometers
        
        // Для 1920x1080 (typical streaming resolution):
        // fx ≈ 1312 pixels
        // fy ≈ 1312 pixels
        // cx ≈ 960 (width/2)
        // cy ≈ 540 (height/2)
        
        let fx = width * 0.684  // ~1312 for 1920
        let fy = height * 2.426 // ~1312 for 540
        let cx = width / 2.0
        let cy = height / 2.0
        
        print("📷 Camera Intrinsics (RGB \(Int(width))x\(Int(height))):")
        print("   fx=\(String(format: "%.1f", fx)), fy=\(String(format: "%.1f", fy))")
        print("   cx=\(String(format: "%.1f", cx)), cy=\(String(format: "%.1f", cy))")
        
        return (fx, fy, cx, cy)
    }
    
    /// Получить intrinsics для LiDAR камеры (256x192)
    static func getLiDARCameraIntrinsics() -> (fx: Double, fy: Double, cx: Double, cy: Double) {
        // iPhone LiDAR (depth camera)
        // Resolution: 256x192
        // HFOV: ~57°, VFOV: ~43°
        
        let width = 256.0
        let height = 192.0
        
        // Вычисляем focal length из FOV
        // fx = (width/2) / tan(HFOV/2)
        let hfov = 57.0 * Double.pi / 180.0
        let vfov = 43.0 * Double.pi / 180.0
        
        let fx = (width / 2.0) / tan(hfov / 2.0)
        let fy = (height / 2.0) / tan(vfov / 2.0)
        let cx = width / 2.0
        let cy = height / 2.0
        
        print("📡 LiDAR Intrinsics (256x192):")
        print("   fx=\(String(format: "%.1f", fx)), fy=\(String(format: "%.1f", fy))")
        print("   cx=\(String(format: "%.1f", cx)), cy=\(String(format: "%.1f", cy))")
        
        return (fx, fy, cx, cy)
    }
}
