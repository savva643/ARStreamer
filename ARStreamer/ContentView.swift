import SwiftUI
import ARKit

struct ContentView: View {
    @StateObject private var streamer = ARStreamer()
    
    var body: some View {
        VStack {
            if !streamer.isConnected {
                // Экран подключения
                Text("ARStreamer")
                    .font(.largeTitle)
                    .bold()
                    .padding(.bottom, 20)
                
                Button(action: {
                    streamer.startSession()
                    streamer.isConnected = true // отметим, что стрим начался
                }) {
                    Text("Подключить")
                        .font(.title2)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .padding()
                
                if let ip = streamer.deviceIP, let port = streamer.port {
                    Text("IP: \(ip)  Порт: \(port)")
                        .padding(.top, 10)
                }
            } else {
                // Экран стрима камеры
                ARPreviewView(session: streamer.session)
                    .ignoresSafeArea()
                
                Button(action: {
                    streamer.stopSession()
                    streamer.isConnected = false
                }) {
                    Text("Отключиться")
                        .font(.title2)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.red)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .padding()
            }
        }
        .padding()
    }
}

