import SwiftUI

struct SettingsView: View {
    @AppStorage("serverIP") private var serverIP: String = "192.168.1.100"
    @AppStorage("serverPort") private var serverPort: String = "9000"
    @AppStorage("sendDepth") private var sendDepth: Bool = false
    @AppStorage("sendMicrophone") private var sendMicrophone: Bool = false
    @AppStorage("streamMode") private var streamMode: String = "USB"
    @AppStorage("targetFPS") private var targetFPS: String = "60"
    @AppStorage("videoCodec") private var videoCodec: String = "H264"
    @AppStorage("videoResolution") private var videoResolution: String = "1440p"
    @AppStorage("bitrateMbps") private var bitrateMbps: String = "30"
    // Картинка лаунчера с ПК на экране телефона (ReturnDisplay)
    @AppStorage("returnLocalCamera") private var returnLocalCamera: Bool = false
    @AppStorage("returnTimewarp") private var returnTimewarp: Bool = true
    @AppStorage("returnRenderScale") private var returnRenderScale: Double = 0.5
    @AppStorage("returnBitrateMbps") private var returnBitrateMbps: Double = 15
    @AppStorage("lensInterMm") private var lensInterMm: Double = 63.9
    @AppStorage("lensScreenMm") private var lensScreenMm: Double = 39.0
    @AppStorage("lensOffsetYMm") private var lensOffsetYMm: Double = 0
    @AppStorage("lensK1") private var lensK1: Double = 0.34
    @AppStorage("lensK2") private var lensK2: Double = 0.55
    @AppStorage("lensChroma") private var lensChroma: Double = 0.012
    @AppStorage("lensFovDeg") private var lensFovDeg: Double = 90

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

                // MARK: - Микрофон
                Section(header: Text("Звук")) {
                    Toggle("Микрофон → ПК", isOn: $sendMicrophone)
                    if sendMicrophone {
                        Text("16 кГц моно, пачки по 20 мс, тем же соединением. На ПК: уровень в панели, F6 — запись в WAV, F7 — слушать в наушниках.")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }

                // MARK: - Экран телефона: картинка с ПК
                Section(header: Text("Экран iPhone: лаунчер с ПК")) {
                    Text("Кнопка режимов в трансляции: RGB → LiDAR → оба → ПК: один глаз → ПК: два глаза → ПК: VR-очки.")
                        .font(.caption2).foregroundColor(.secondary)
                    Toggle("Фон — камера iPhone (меньше задержка)", isOn: $returnLocalCamera)
                    Text(returnLocalCamera
                         ? "ПК рисует только объекты с прозрачностью, фон — живая камера телефона: задержка фона ~30–40 мс вместо ~80–120."
                         : "Весь кадр рендерит ПК (видео + объекты).")
                        .font(.caption2).foregroundColor(.secondary)
                    Toggle("Доворот по гироскопу", isOn: $returnTimewarp)
                    Picker("Разрешение рендера", selection: $returnRenderScale) {
                        Text("50%").tag(0.5)
                        Text("75%").tag(0.75)
                        Text("100%").tag(1.0)
                    }
                    .pickerStyle(.segmented)
                    Stepper("Битрейт с ПК: \(Int(returnBitrateMbps)) Мбит/с", value: $returnBitrateMbps, in: 4...60, step: 2)
                }

                Section(header: Text("VR-очки (линзы)")) {
                    sliderRow("Между линзами", value: $lensInterMm, range: 50...75, format: "%.1f мм")
                    sliderRow("Экран → линза", value: $lensScreenMm, range: 25...60, format: "%.1f мм")
                    sliderRow("Центр линз по высоте", value: $lensOffsetYMm, range: -15...15, format: "%+.1f мм")
                    sliderRow("Искажение k1", value: $lensK1, range: 0...1, format: "%.2f")
                    sliderRow("Искажение k2", value: $lensK2, range: 0...1, format: "%.2f")
                    sliderRow("Хроматизм", value: $lensChroma, range: 0...0.04, format: "%.3f")
                    sliderRow("Поле зрения", value: $lensFovDeg, range: 60...120, format: "%.0f°")
                    Button("Сбросить (Cardboard v2)") {
                        lensInterMm = 63.9; lensScreenMm = 39.0; lensOffsetYMm = 0
                        lensK1 = 0.34; lensK2 = 0.55; lensChroma = 0.012; lensFovDeg = 90
                    }
                    Text("Параметры как у профиля Google Cardboard: их печатают на коробке или в QR-коде очков. Шире камеры iPhone (~70°) по краям будет темно — так и должно быть при реальном масштабе.")
                        .font(.caption2).foregroundColor(.secondary)
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

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value.wrappedValue)).foregroundColor(.secondary).monospacedDigit()
            }
            Slider(value: value, in: range)
        }
    }
}
