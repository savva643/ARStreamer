import SwiftUI
import ARKit
import Network
import Combine

struct ContentView: View {
    @StateObject private var streamer = ARStreamer()
    
    var body: some View {
        VStack {
            if !streamer.isStreaming {
                // Экран подключения
                Text("ARStreamer")
                    .font(.largeTitle)
                    .bold()
                    .padding(.bottom, 20)
                
                Button(action: {
                    streamer.start()
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
                
                if let ip = streamer.deviceIP {
                    Text("IP: \(ip)  Порт: \(streamer.port)")
                        .padding(.top, 10)
                }
            } else {
                // Экран стрима камеры
                ARPreviewView(session: streamer.session)
                    .edgesIgnoringSafeArea(.all)
                
                Button(action: {
                    streamer.stop()
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

