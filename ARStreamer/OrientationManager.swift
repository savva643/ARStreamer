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
                return .portrait
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
        let orientationValue = orientation.preferredOrientation.rawValue
        UIDevice.current.setValue(orientationValue, forKey: "orientation")
        
        // Уведомить систему
        AppDelegate.orientationLock = orientation.mask
        if #available(iOS 16.0, *) {
            let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene
            windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: orientation.mask))
        } else {
            UIViewController.attemptRotationToDeviceOrientation()
        }
        
        saveSettings()
    }
    
    func lockOrientation() {
        isOrientationLocked = true
        // Устанавливаем маску ориентации
        AppDelegate.orientationLock = selectedOrientation.mask
        
        // Принудительно устанавливаем текущую ориентацию
        let orientationValue = selectedOrientation.preferredOrientation.rawValue
        UIDevice.current.setValue(orientationValue, forKey: "orientation")
        
        // Запрашиваем обновление геометрии для iOS 16+
        if #available(iOS 16.0, *) {
            let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene
            windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: selectedOrientation.mask))
        } else {
            UIViewController.attemptRotationToDeviceOrientation()
        }
        
        saveSettings()
        print("🔒 Ориентация полностью заблокирована: \(selectedOrientation.rawValue)")
    }
    
    func unlockOrientation() {
        isOrientationLocked = false
        saveSettings()
        print("🔓 Ориентация разблокирована")
    }
    
    // MARK: - Подключено к ПК: экран не вертится

    private var maskBeforeStreaming: UIInterfaceOrientationMask?

    /// Телефон в шлеме: интерфейс замирает ровно в текущей ориентации (одна ориентация, не «любой ландшафт»),
    /// иначе при наклоне головы iOS переворачивает экран на 180°. Поток для ПК от этого не зависит —
    /// он всегда в ориентации сенсора.
    func lockForStreaming() {
        guard maskBeforeStreaming == nil else { return }
        maskBeforeStreaming = AppDelegate.orientationLock
        let scene = activeScene()
        let mask: UIInterfaceOrientationMask
        switch scene?.interfaceOrientation ?? .landscapeRight {
        case .landscapeLeft: mask = .landscapeLeft
        case .portrait: mask = .portrait
        case .portraitUpsideDown: mask = .portraitUpsideDown
        default: mask = .landscapeRight
        }
        apply(mask, scene: scene)
        print("🔒 Подключено: экран зафиксирован (\(mask.rawValue))")
    }

    /// Отключились — возвращаем прежние правила поворота
    func unlockAfterStreaming() {
        guard let mask = maskBeforeStreaming else { return }
        maskBeforeStreaming = nil
        apply(mask, scene: activeScene())
        print("🔓 Отключено: поворот экрана как раньше")
    }

    private func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    private func apply(_ mask: UIInterfaceOrientationMask, scene: UIWindowScene?) {
        AppDelegate.orientationLock = mask
        if #available(iOS 16.0, *) {
            scene?.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            scene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        } else {
            UIViewController.attemptRotationToDeviceOrientation()
        }
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
