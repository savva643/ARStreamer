import SwiftUI

struct ARContentView: View {
    @StateObject private var viewModel = NetworkConnectViewModel()
    @State private var showDebug = false
    @State private var showInfo = false
    @State private var useLiDAR = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // AR камера
            if let previewImage = viewModel.previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFill()
                    .edgesIgnoringSafeArea(.all)
                    .rotationEffect(.degrees(180)) // если перевёрнуто, подкорректировать
                    .scaleEffect(x: -1, y: 1, anchor: .center) // зеркальное отображение при необходимости
            } else {
                Text("Ожидание подключения...")
                    .foregroundColor(.white)
                    .font(.title)
            }

            // Верхний ряд кнопок управления
            VStack {
                HStack {
                    Button(action: { viewModel.disconnect() }) {
                        Text("Отключить")
                            .padding(8)
                            .background(Color.red.opacity(0.8))
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }

                    Button(action: { showDebug.toggle() }) {
                        Text("Debug")
                            .padding(8)
                            .background(Color.blue.opacity(0.8))
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }

                    Button(action: { useLiDAR.toggle(); viewModel.restartSession(useLiDAR: useLiDAR) }) {
                        Text(useLiDAR ? "LiDAR ON" : "LiDAR OFF")
                            .padding(8)
                            .background(useLiDAR ? Color.green.opacity(0.8) : Color.gray.opacity(0.8))
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }

                    Button(action: { showInfo.toggle() }) {
                        Image(systemName: "info.circle")
                            .padding(8)
                            .background(Color.black.opacity(0.5))
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                }
                .padding()
                Spacer()
            }

            // Debug overlay
            if showDebug {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Статус: \(viewModel.statusText)")
                    Text("IP ПК: \(UserDefaults.standard.string(forKey: "serverIP") ?? "—")")
                    Text("Порт: \(UserDefaults.standard.string(forKey: "serverPort") ?? "—")")
                    Text("Скорость: \(viewModel.networkSpeedText)")
                }
                .padding()
                .background(Color.black.opacity(0.6))
                .foregroundColor(.white)
                .cornerRadius(12)
                .padding()
                .transition(.move(edge: .top))
            }

            // Info окно
            if showInfo {
                VStack {
                    Text("Инструкции")
                        .font(.title)
                        .bold()
                        .padding()
                    Text("""
                    • Кнопка Отключить — завершает трансляцию
                    • Кнопка Debug — показывает пинг и скорость
                    • Кнопка LiDAR — включает/выключает LiDAR
                    • Здесь отображается превью камеры AR
                    """)
                        .padding()
                    Button("Закрыть") { showInfo = false }
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .frame(maxWidth: 300)
                .background(Color.black.opacity(0.8))
                .foregroundColor(.white)
                .cornerRadius(12)
                .shadow(radius: 10)
                .transition(.scale)
            }
        }
        .onAppear { viewModel.start() }
    }
}
