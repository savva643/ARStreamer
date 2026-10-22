import SwiftUI

struct SettingsView: View {
    @AppStorage("serverIP") private var serverIP: String = "192.168.1.100"
    @AppStorage("serverPort") private var serverPort: String = "9000"
    @AppStorage("sendDepth") private var sendDepth: Bool = false
    @AppStorage("streamMode") private var streamMode: String = "USB"
    @AppStorage("targetFPS") private var targetFPS: String = "60"
    @AppStorage("videoCodec") private var videoCodec: String = "H264"
    @AppStorage("videoResolution") private var videoResolution: String = "1440p"
    @AppStorage("bitrateMbps") private var bitrateMbps: String = "30"

    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            Form {
                // MARK: - Транспорт
                Section(header: Text("Подключение")) {
                    Picker("Транспорт", selection: $streamMode) {
                        Text("USB").tag("USB")
                        Text("Wi-Fi").tag("TCP_H264")
                        Text("JPEG (отладка)").tag("TCP_JPEG")
                    }
                    .pickerStyle(.segmented)

                    if streamMode != "USB" {
                        TextField("IP адрес ПК", text: $serverIP)
                            .keyboardType(.numbersAndPunctuation)
                        TextField("Порт", text: $serverPort)
                            .keyboardType(.numberPad)
                    }

                    switch streamMode {
                    case "USB":
                        Text("🔌 Лучший вариант: минимальная задержка и высокий битрейт. Включите «Режим модема» по USB, ПК слушает порт \(USBEthernetManager.usbPort).")
                            .font(.footnote).foregroundColor(.secondary)
                    case "TCP_JPEG":
                        Text("🖼 Только для отладки: тяжёлый для сети и телефона, задержка выше.")
                            .font(.footnote).foregroundColor(.orange)
                    default:
                        Text("📶 Wi-Fi 5/6 на 5 ГГц. Рекомендуемый битрейт 15–25 Мбит/с.")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                }

                // MARK: - Видео
                if streamMode != "TCP_JPEG" {
                    Section(header: Text("Видео")) {
                        Picker("Кодек", selection: $videoCodec) {
                            Text("H.264").tag("H264")
                            Text("HEVC").tag("HEVC")
                        }
                        .pickerStyle(.segmented)

                        Picker("Разрешение", selection: $videoResolution) {
                            Text("720p").tag("720p")
                            Text("1080p").tag("1080p")
                            Text("1440p 4:3").tag("1440p")
                            Text("4K").tag("4K")
                        }

                        HStack {
                            Text("Битрейт")
                            Spacer()
                            TextField("30", text: $bitrateMbps)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 60)
                            Text("Мбит/с").foregroundColor(.secondary).font(.caption)
                        }

                        Text("H.264 — минимальная задержка (low-latency режим энкодера). HEVC — лучше качество на том же битрейте. 1440p 4:3 — полный кадр сенсора, лучший угол обзора для трекинга.")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }

                // MARK: - Производительность
                Section(header: Text("Частота кадров камеры")) {
                    Picker("FPS", selection: $targetFPS) {
                        Text("30").tag("30")
                        Text("60").tag("60")
                        Text("120").tag("120")
                    }
                    .pickerStyle(.segmented)
                    Text("Плавность на ПК обеспечивает репроекция по IMU, а не FPS камеры. 60 — оптимально; 120 доступно не на всех форматах (обычно ≤1080p). С LiDAR камера часто ограничена 30 FPS.")
                        .font(.caption2).foregroundColor(.secondary)
                }

                // MARK: - LiDAR
                Section(header: Text("Глубина")) {
                    Toggle("Отправлять LiDAR (глубина)", isOn: $sendDepth)
                    if sendDepth {
                        Text("Сырая карта глубины Float16 с таймстемпом и интринсиками, тем же соединением. Требуется iPhone Pro с LiDAR.")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }

                // MARK: - Логи
                Section(header: Text("📋 Логи")) {
                    NavigationLink(destination: LogsView()) {
                        HStack {
                            Image(systemName: "doc.text").foregroundColor(.blue)
                            Text("Просмотреть логи")
                        }
                    }
                }

                if streamMode == "USB" {
                    Section(header: Text("📋 USB-подключение")) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("1. Подключите iPhone к ПК кабелем").font(.caption)
                            Text("2. На iPhone включите «Режим модема» (доступ по USB)").font(.caption)
                            Text("3. На ПК запустите ARLauncher").font(.caption)
                            Text("4. Нажмите «Подключиться»").font(.caption)
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
