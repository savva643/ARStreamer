import SwiftUI

struct SettingsView: View {
    @AppStorage("sendRGB") var sendRGB = true
    @AppStorage("sendDepth") var sendDepth = true
    @AppStorage("previewOnPhone") var previewOnPhone = true
    var body: some View {
        Form {
            Toggle("Отправлять RGB", isOn: $sendRGB)
            Toggle("Отправлять Depth (LiDAR)", isOn: $sendDepth)
            Toggle("Показ превью на iPhone", isOn: $previewOnPhone)
            Section {
                Text("Порт: 9000 (фикс.)")
                Text("Протокол: TCP, простой бинарный framing")
            }
        }
    }
}
