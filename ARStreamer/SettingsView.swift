import SwiftUI

struct SettingsView: View {
    @AppStorage("serverIP") private var serverIP: String = "192.168.1.100"
    @AppStorage("serverPort") private var serverPort: String = "9000"
    @AppStorage("sendRGB") private var sendRGB: Bool = true
    @AppStorage("sendDepth") private var sendDepth: Bool = false
    @AppStorage("streamMode") private var streamMode: String = "TCP_JPEG"
    @AppStorage("targetFPS") private var targetFPS: String = "60"

    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            Form {
                // MARK: - Сервер (скрываем для USB)
                if streamMode != "USB" {
                    Section(header: Text("Сервер")) {
                        TextField("IP адрес", text: $serverIP)
                            .keyboardType(.numbersAndPunctuation)
                        TextField("Порт", text: $serverPort)
                            .keyboardType(.numberPad)
                    }
                }

                // MARK: - Передача данных
                Section(header: Text("Передача данных")) {
                    Toggle("Отправлять RGB-видео", isOn: $sendRGB)
                    
                    Toggle("Отправлять глубину (LiDAR)", isOn: $sendDepth)
                    
                    if sendDepth {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("📡 **LiDAR данные** — передает карту глубины сенсора LiDAR")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            // 🔹 НОВОЕ: Информация о портах LiDAR
                            if streamMode == "USB" {
                                Text("🔦 LiDAR порт: 9004 (отдельный для USB)")
                                    .font(.caption)
                                    .foregroundColor(.blue)
                            } else {
                                Text("🔦 LiDAR порт: 9002 (отдельный для Wi-Fi)")
                                    .font(.caption)
                                    .foregroundColor(.blue)
                            }
                            
                            Text("Требуется устройство с LiDAR (iPhone 12 Pro и новее)")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                        .padding(.vertical, 4)
                    }
                }

                // MARK: - Настройки производительности
                Section(header: Text("Производительность")) {
                    HStack {
                        Text("Целевой FPS")
                        Spacer()
                        TextField("60", text: $targetFPS)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                        Text("кадров/сек")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("🎯 **Рекомендации:**")
                            .font(.caption)
                            .bold()
                        Text("• USB: 60 FPS (максимум)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("• UDP: 30-60 FPS")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("• TCP: 15-30 FPS")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                // MARK: - Режим потока
                Section(header: Text("Режим потока")) {
                    Picker("Тип передачи", selection: $streamMode) {
                        Text("TCP (JPEG)").tag("TCP_JPEG")
                        Text("UDP (H.264)").tag("UDP_H264")
                        Text("USB (через кабель)").tag("USB")
                    }
                    .pickerStyle(.segmented)

                    VStack(alignment: .leading, spacing: 6) {
                        switch streamMode {
                        case "TCP_JPEG":
                            Text("🖼 **TCP (JPEG)** — простой и надёжный, хорошее качество, но ограничен ~30 FPS. Лучше для стабильного Wi-Fi.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        case "UDP_H264":
                            Text("🎥 **UDP (H.264)** — высокая скорость и плавность (до 60 FPS), низкая задержка, но может быть артефакты при плохом соединении.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        case "USB":
                            VStack(alignment: .leading, spacing: 4) {
                                Text("🔌 **USB** — идеальное качество и минимальная задержка. Требует подключения по кабелю.")
                                Text("IP: \(USBEthernetManager.usbHostIP), Port: \(USBEthernetManager.usbPort)")
                                    .font(.caption)
                                    .foregroundColor(.blue)
                            }
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        default:
                            EmptyView()
                        }
                    }
                    .padding(.vertical, 4)
                }

                // MARK: - Логи
                Section(header: Text("📋 Логи")) {
                    NavigationLink(destination: LogsView()) {
                        HStack {
                            Image(systemName: "doc.text")
                                .foregroundColor(.blue)
                            Text("Просмотреть логи")
                        }
                    }
                }
                
                // MARK: - Инструкция для USB
                if streamMode == "USB" {
                    Section(header: Text("📋 Инструкция для USB-подключения")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("1. **Подключите iPhone к ПК через USB-кабель**")
                                .font(.caption)
                                .foregroundColor(.primary)
                            Text("2. **На iPhone включите режим модема по USB**")
                                .font(.caption)
                                .foregroundColor(.primary)
                            Text("   • На Windows: установите iTunes для драйверов")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("3. **На ПК запустите программу-ресивер**")
                                .font(.caption)
                                .foregroundColor(.primary)
                            Text("4. **В этом приложении нажмите 'Подключиться'**")
                                .font(.caption)
                                .foregroundColor(.primary)
                            
                            Divider()
                            
                            Text("**Порты для приема данных:**")
                                .font(.caption)
                                .bold()
                                .foregroundColor(.primary)
                            Text("🎥 Видео порт: \(USBEthernetManager.usbPort)")
                                .font(.caption2)
                                .foregroundColor(.blue)
                            if sendDepth {
                                Text("🔦 LiDAR порт: 9004")
                                    .font(.caption2)
                                    .foregroundColor(.blue)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
