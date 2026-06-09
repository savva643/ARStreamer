import SwiftUI
import UIKit

// MARK: - AppDelegate для контроля ориентации
class AppDelegate: UIResponder, UIApplicationDelegate {
    static var orientationLock = UIInterfaceOrientationMask.all
    
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return AppDelegate.orientationLock
    }
}

@main
struct ARStreamerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject var orientationManager = OrientationManager.shared
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    // Если уже откалибровано, применяем сохранённую ориентацию
                    if orientationManager.isOrientationLocked {
                        AppDelegate.orientationLock = orientationManager.selectedOrientation.mask
                        let orientation = orientationManager.selectedOrientation.preferredOrientation.rawValue
                        UIDevice.current.setValue(orientation, forKey: "orientation")
                    } else {
                        // Иначе разрешаем все ориентации для выбора
                        AppDelegate.orientationLock = .all
                    }
                }
        }
    }
}
