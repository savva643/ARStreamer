import SwiftUI
import Network

enum ConnectMode { case wifi, usb }

struct NetworkConnectView: View {
    let mode: ConnectMode
    @StateObject private var vm = NetworkConnectViewModel()
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button("Назад") { vm.disconnect(); dismiss() }
                Spacer()
                Text(mode == .wifi ? "Wi-Fi" : "USB").font(.headline)
                Spacer()
            }.padding()
            
            Text("Локальный IP: \(vm.localIP ?? "—") : 9000")
                .font(.subheadline)
            
            Text("Статус: \(vm.statusText)").foregroundColor(.gray)
            
            HStack {
                Button("Start") { vm.start(mode: mode) }.buttonStyle(.borderedProminent)
                Button("Stop") { vm.disconnect() }.buttonStyle(.bordered)
            }
            .padding()
            
            Spacer()
            
            // Preview from iPhone camera (optional)
            if vm.previewImage != nil {
                Image(uiImage: vm.previewImage!)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 300)
                    .padding()
            }
        }
        .onAppear { vm.fetchLocalIP() }
        .padding()
    }
}
