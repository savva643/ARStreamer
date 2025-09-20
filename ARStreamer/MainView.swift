import SwiftUI

struct MainView: View {
    @State private var showWiFi = false
    @State private var showUSB = false
    @State private var showSettings = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 18) {
                Text("ARStreamer").font(.largeTitle).bold()
                Button("📡 Подключение по Wi-Fi") {
                    showWiFi = true
                }
                .buttonStyle(.borderedProminent)
                
                Button("🔌 Подключение по USB (dev mode)") {
                    showUSB = true
                }
                .buttonStyle(.borderedProminent)
                
                Button("⚙️ Настройки / Отладка") {
                    showSettings = true
                }
                .buttonStyle(.bordered)
                
                Spacer()
            }
            .padding()
            .sheet(isPresented: $showWiFi) { NetworkConnectView(mode: .wifi) }
            .sheet(isPresented: $showUSB) { NetworkConnectView(mode: .usb) }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }
}
