import SwiftUI
import UIKit

/// Менеджер ориентации приложения
class OrientationManager: NSObject, ObservableObject {
    @Published var selectedOrientation: AppOrientation = .landscape
    @Published var isCalibrated = false
    @Published var isOrientationLocked = false
    
    static let shared = OrientationManager()
    
    enum AppOrientation: String, CaseIterable {
        case landscape = "Landscape (Горизонтально)"
        case portrait = "Portrait (Вертикально)"
        
        var mask: UIInterfaceOrientationMask {
            switch self {
            case .landscape:
                return .landscape
            case .portrait:
                return .portrait
            }
        }
        
        var preferredOrientation: UIInterfaceOrientation {
            switch self {
            case .landscape:
                return .landscapeRight
            case .portrait:
                return .portraitUp
            }
        }
    }
    
    override init() {
        super.init()
        loadSettings()
    }
    
    func setOrientation(_ orientation: AppOrientation) {
        selectedOrientation = orientation
        AppDelegate.orientationLock = orientation.mask
        
        // Принудительно установить ориентацию
        let orientation = orientation.preferredOrientation.rawValue
        UIDevice.current.setValue(orientation, forKey: "orientation")
        
        // Уведомить систему
        AppDelegate.orientationLock = orientation.mask
        UIViewController.attemptRotationToDeviceOrientation()
        
        saveSettings()
    }
    
    func lockOrientation() {
        isOrientationLocked = true
        AppDelegate.orientationLock = selectedOrientation.mask
        saveSettings()
        print("🔒 Ориентация заблокирована: \(selectedOrientation.rawValue)")
    }
    
    func unlockOrientation() {
        isOrientationLocked = false
        saveSettings()
        print("🔓 Ориентация разблокирована")
    }
    
    func markCalibrated() {
        isCalibrated = true
        saveSettings()
        print("✅ Калибровка завершена для: \(selectedOrientation.rawValue)")
    }
    
    func resetCalibration() {
        isCalibrated = false
        isOrientationLocked = false
        AppDelegate.orientationLock = .all
        saveSettings()
        print("🔄 Калибровка сброшена. Нужно выбрать ориентацию заново.")
    }
    
    private func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(selectedOrientation.rawValue, forKey: "selectedOrientation")
        defaults.set(isCalibrated, forKey: "isCalibrated")
        defaults.set(isOrientationLocked, forKey: "isOrientationLocked")
    }
    
    private func loadSettings() {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "selectedOrientation"),
           let orientation = AppOrientation(rawValue: saved) {
            selectedOrientation = orientation
        }
        isCalibrated = defaults.bool(forKey: "isCalibrated")
        isOrientationLocked = defaults.bool(forKey: "isOrientationLocked")
        
        if isOrientationLocked {
            AppDelegate.orientationLock = selectedOrientation.mask
        }
    }
}
