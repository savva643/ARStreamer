import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = NetworkConnectViewModel()
    @ObservedObject var orientationManager = OrientationManager.shared
    @State private var showDebug = false
    @State private var showInfoModal = false
    @State private var showSettings = false
    @State private var showAboutModal = false // 🔹 Новое: модальное окно "О приложении"
    @State private var useLiDAR = false
    @State private var deviceOrientation = UIDevice.current.orientation
    @State private var isConnected = false
    @State private var mirrorPreview = false
    @State private var isConnecting = false
    @State private var lastPreviewImageSize: CGSize = .zero
    @State private var cameraRotation: Double = 0 // 🔹 НОВОЕ: точная ориентация камеры (для UI preview)
    @State private var deviceOrientationAngle: Double = 0 // 🔹 НОВОЕ: угол ориентации для ARLauncher
    @State private var showOrientationSelection = false
    @State private var showCalibration = false

    // 🔹 НОВОЕ: Режимы отображения и временный текст
        @State private var displayMode: ARStreamer.DisplayMode = .rgbOnly
        @State private var showModeText = false
        @State private var modeText = ""
    
    var body: some View {
        NavigationView {
            ZStack {
                // Проверяем, нужна ли калибровка
                if !orientationManager.isCalibrated {
                    if showOrientationSelection {
                        OrientationSelectionView(showOrientationSelection: $showOrientationSelection)
                            .transition(.opacity)
                    } else {
                        CalibrationView()
                            .transition(.opacity)
                    }
                } else if isConnected {
                    streamingView
                } else if isConnecting {
                    connectingView
                } else {
                    mainMenuView
                }
            }
            .onChange(of: viewModel.frameCount) { frameCount in
                // 🔹 КЛЮЧЕВОЕ: onChange на ZStack уровне срабатывает всегда
                print("📊 ZStack onChange frameCount triggered: frameCount = \(frameCount), isConnecting = \(isConnecting)")
                if frameCount > 0 && isConnecting {
                    print("✅ Transitioning to streaming view! (frameCount=\(frameCount))")
                    isConnected = true
                    isConnecting = false
                }
            }
            .onAppear {
                viewModel.fetchLocalIP()
                updateOrientation()
                useLiDAR = viewModel.sendDepth
                
                // Если не откалибровано, показываем выбор ориентации
                if !orientationManager.isCalibrated {
                    showOrientationSelection = true
                }
            }
            .sheet(isPresented: $showInfoModal) {
                InfoView()
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showAboutModal) {
                AboutView() // 🔹 Новое: модальное окно "О приложении"
            }
        }
    }

    // 🔹 ЭКРАН ПОДКЛЮЧЕНИЯ
    private var connectingView: some View {
        VStack(spacing: 30) {
            Spacer()
            
            ProgressView()
                .scaleEffect(2.0)
                .padding()
            
            Text("Подключение...")
                .font(.title2)
                .foregroundColor(.primary)
            
            Text(viewModel.statusText)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Button("Отменить") {
                viewModel.disconnect()
                isConnecting = false
                isConnected = false
            }
            .buttonStyle(.bordered)
            .foregroundColor(.red)
            
            Spacer()
        }
        .padding()
    }

    // 🔹 ГЛАВНОЕ МЕНЮ
    private var mainMenuView: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            
            if isLandscape {
                menuHorizontalLayout
            } else {
                menuVerticalLayout
            }
        }
    }
    
    // ВЕРТИКАЛЬНЫЙ МАКЕТ МЕНЮ
    private var menuVerticalLayout: some View {
        VStack(spacing: 0) {
            // Верхние кнопки
            HStack {
                Button(action: { showInfoModal = true }) {
                    Image(systemName: "info.circle")
                        .font(.title2)
                        .foregroundColor(.blue)
                }
                
                Spacer()
                
                Button(action: { showSettings = true }) {
                    Image(systemName: "gear")
                        .font(.title2)
                        .foregroundColor(.blue)
                }
            }
            .padding(.horizontal)
            .padding(.top, 10)
            .padding(.bottom, 10)

            // ScrollView для основного контента
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 24) {
                    VStack(spacing: 8) {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 60))
                            .foregroundColor(.blue)
                        
                        Text("ARStreamer")
                            .font(.largeTitle)
                            .bold()
                        
                        Text("Трансляция AR в реальном времени")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 20)

                    VStack(spacing: 12) {
                        HStack {
                            Image(systemName: "wifi")
                            Text("Локальный IP: \(viewModel.localIP ?? "—")")
                            Spacer()
                        }
                        .foregroundColor(.secondary)
                        
                        HStack {
                            Image(systemName: "info.circle")
                            Text(viewModel.statusText)
                            Spacer()
                        }
                        .foregroundColor(.gray)
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(12)

                    VStack(spacing: 12) {
                        Button(action: {
                            isConnecting = true
                            viewModel.start()
                        }) {
                            HStack {
                                Image(systemName: "play.circle.fill")
                                Text("Начать трансляцию")
                                    .font(.headline)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }

                        Button(action: {
                            orientationManager.resetCalibration()
                            withAnimation {
                                showOrientationSelection = true
                            }
                        }) {
                            HStack {
                                Image(systemName: "iphone.landscape")
                                Text("Сменить ориентацию")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(Color.orange)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }

                        Button(action: { showAboutModal = true }) {
                            HStack {
                                Image(systemName: "app.badge")
                                Text("О приложении")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                    }
                    .padding(.horizontal)
                }
                .padding()
            }
        }
    }
    
    // ГОРИЗОНТАЛЬНЫЙ МАКЕТ МЕНЮ
    private var menuHorizontalLayout: some View {
        HStack(spacing: 30) {
            // Левая часть со ScrollView
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Button(action: { showInfoModal = true }) {
                            Image(systemName: "info.circle")
                                .font(.title3)
                                .foregroundColor(.blue)
                        }
                        
                        Spacer()
                        
                        Button(action: { showSettings = true }) {
                            Image(systemName: "gear")
                                .font(.title3)
                                .foregroundColor(.blue)
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 50))
                            .foregroundColor(.blue)
                        
                        Text("ARStreamer")
                            .font(.title2)
                            .bold()
                        
                        Text("AR трансляция")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "wifi")
                                .font(.caption)
                            Text("IP: \(viewModel.localIP ?? "—")")
                                .font(.caption)
                        }
                        .foregroundColor(.secondary)
                        
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle")
                                .font(.caption)
                            Text(viewModel.statusText)
                                .font(.caption)
                        }
                        .foregroundColor(.gray)
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(10)
                }
                .padding()
            }
            .frame(maxWidth: 280, alignment: .leading)
            
            // Правая часть со ScrollView для кнопок
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 12) {
                    Button(action: {
                        isConnecting = true
                        viewModel.start()
                    }) {
                        VStack(spacing: 8) {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 28))
                            Text("Начать")
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }

                    Button(action: {
                        orientationManager.resetCalibration()
                        withAnimation {
                            showOrientationSelection = true
                        }
                    }) {
                        VStack(spacing: 8) {
                            Image(systemName: "iphone.landscape")
                                .font(.system(size: 28))
                            Text("Ориентация")
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }

                    Button(action: { showAboutModal = true }) {
                        VStack(spacing: 8) {
                            Image(systemName: "app.badge")
                                .font(.system(size: 28))
                            Text("О приложении")
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                }
                .padding()
            }
            .frame(maxWidth: 150)
        }
        .padding()
    }

    // 🔹 РЕЖИМ СТРИМИНГА
    // 🔹 РЕЖИМ СТРИМИНГА С ДОПОЛНЕНИЯМИ
    private var streamingView: some View {
        ZStack {
            // 🔹 ИСПРАВИЛ: Отделяем проверки RGB и LiDAR
            if displayMode == .depthOnly, let depthPreview = viewModel.depthPreviewImage {
                // Только LiDAR
                Image(uiImage: depthPreview)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .onAppear {
                        print("📊 Showing depthOnly mode")
                        logToFile("📊 Showing depthOnly mode")
                    }
            } else if displayMode == .both, let preview = viewModel.previewImage, let depthPreview = viewModel.depthPreviewImage {
                // Режим "оба сразу" - разделенный экран
                GeometryReader { proxy in
                    if deviceOrientation.isLandscape {
                        // 🔹 Горизонтальное разделение
                        HStack(spacing: 0) {
                            Image(uiImage: mirrorPreview ? preview.mirroredHorizontally() : preview)
                                .resizable()
                                .scaledToFill()
                                .frame(width: proxy.size.width / 2, height: proxy.size.height)
                                .rotationEffect(.degrees(cameraRotation))
                                .clipped()

                            Image(uiImage: depthPreview)
                                .resizable()
                                .scaledToFill()
                                .frame(width: proxy.size.width / 2, height: proxy.size.height)
                                .rotationEffect(.degrees(cameraRotation))
                                .clipped()
                        }
                        .frame(width: proxy.size.width, height: proxy.size.height)
                    } else {
                        // 🔹 Вертикальное разделение
                        VStack(spacing: 0) {
                            Image(uiImage: mirrorPreview ? preview.mirroredHorizontally() : preview)
                                .resizable()
                                .scaledToFill()
                                .frame(width: proxy.size.width, height: proxy.size.height / 2)
                                .clipped()

                            Image(uiImage: depthPreview)
                                .resizable()
                                .scaledToFill()
                                .frame(width: proxy.size.width, height: proxy.size.height / 2)
                                .clipped()
                        }
                        .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                }
                .ignoresSafeArea()
                .onAppear {
                    print("📊 Showing both mode")
                    logToFile("📊 Showing both mode")
                }
            } else if let preview = viewModel.previewImage {
                // Только RGB изображение доступно
                Image(uiImage: mirrorPreview ? preview.mirroredHorizontally() : preview)
                    .resizable()
                    .scaledToFill()
                    .rotationEffect(.degrees(cameraRotation))
                    .ignoresSafeArea()
            } else {
                // 🔹 ОТЛАДКА: показываем статус если нет изображения
                ZStack {
                    Color.black.ignoresSafeArea()
                    
                    VStack(spacing: 20) {
                        Text("Ожидание видео...")
                            .font(.title2)
                            .foregroundColor(.white)
                        
                        ProgressView()
                            .tint(.white)
                        
                        Text("Статус: \(viewModel.statusText)")
                            .font(.caption)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding()
                        
                        Text("FPS: \(viewModel.fpsText)")
                            .font(.caption)
                            .foregroundColor(.gray)
                        
                        Text("Скорость: \(viewModel.networkSpeedText)")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .padding()
                }
            }

            // 🔹 Временный текст режима (по центру сверху с учетом безопасных областей)
            if showModeText {
                VStack {
                    Text(modeText)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(10)
                        .transition(.opacity)
                    Spacer()
                }
                .padding(.top,displayMode == .both ? 60 :  120) // Учитываем safe area сверху
                .frame(maxWidth: .infinity)
                .animation(.easeInOut(duration: 0.3), value: showModeText)
            }
            

            // 🔹 ОБЩИЙ GeometryReader ДЛЯ ВСЕХ ЭЛЕМЕНТОВ УПРАВЛЕНИЯ
            GeometryReader { geo in
                if deviceOrientation.isLandscape {
                    // АЛЬБОМНАЯ ОРИЕНТАЦИЯ
                    HStack {
                        if displayMode == .both {
                            // 🔹 РЕЖИМ "ОБА" - кнопки по центру слева
                            VStack(spacing: 20) {
                                Spacer()
                                controlButtonsLandscape
                                Spacer()
                            }
                            .padding(.leading, 20)
                        } else {
                            // 🔹 РЕЖИМЫ RGB/LiDAR - кнопки ближе к краю
                            VStack(spacing: 20) {
                                Spacer()
                                controlButtonsLandscape
                                Spacer()
                            }
                            .padding(.leading, 15) // Меньший отступ для одного изображения
                        }
                        
                        Spacer()
                        
                      

                        if showDebug {
                            ScrollView {
                                debugPanel
                            }
                            .frame(width: 280, height: 400)
                            .padding(.trailing, 20)
                        }
                    }
                    
                } else {
                    // ПОРТРЕТНАЯ ОРИЕНТАЦИЯ
                    VStack {
                    

                        if showDebug {
                            ScrollView {
                                debugPanel
                            }
                            .frame(maxWidth: 320, maxHeight: 300)
                            .padding(.top, 10)
                        }

                        Spacer()
                        
                        // 🔹 КНОПКИ УПРАВЛЕНИЯ - по центру снизу с учетом safe area
                        HStack(spacing: 20) {
                            Spacer()
                            controlButtonsPortrait
                            Spacer()
                        }
                        .padding(.bottom, geo.safeAreaInsets.bottom + 30) // Учитываем safe area снизу
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            updateOrientation()
        }
    }

    // 🔹 ВЫНЕС КНОПКИ В ОТДЕЛЬНЫЕ КОМПОНЕНТЫ ДЛЯ ПОВТОРНОГО ИСПОЛЬЗОВАНИЯ

    // Кнопки для альбомной ориентации
    // Кнопки для альбомной ориентации
    private var controlButtonsLandscape: some View {
        Group {
            Button(action: {
                useLiDAR.toggle()
                viewModel.restartSession(useLiDAR: useLiDAR)
                showTemporaryText(useLiDAR ? "LiDAR ВКЛ" : "LiDAR ВЫКЛ")
            }) {
                Image(systemName: "scope")
                    .font(.title2)
                    .foregroundColor(.white)
                    .padding(12)
                    .background(useLiDAR ? Color.green.opacity(0.8) : Color.gray.opacity(0.6))
                    .clipShape(Circle())
            }

            Button(action: {
                switch displayMode {
                case .rgbOnly:
                    displayMode = useLiDAR ? .depthOnly : .both
                    showTemporaryText("РЕЖИМ: LiDAR")
                case .depthOnly:
                    displayMode = .both
                    showTemporaryText("РЕЖИМ: ОБА")
                case .both:
                    displayMode = .rgbOnly
                    showTemporaryText("РЕЖИМ: RGB")
                }
                viewModel.switchDisplayMode(displayMode)
            }) {
                Image(systemName: displayModeIcon)
                    .font(.title2)
                    .foregroundColor(.white)
                    .padding(12)
                    .background(displayModeColor.opacity(0.8))
                    .clipShape(Circle())
            }

            Button(action: {
                viewModel.disconnect()
                isConnected = false
                isConnecting = false
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.white)
                    .padding(12)
                    .background(Color.red.opacity(0.8))
                    .clipShape(Circle())
            }

            Button(action: { showDebug.toggle() }) {
                Image(systemName: "gauge")
                    .font(.title2)
                    .foregroundColor(.white)
                    .padding(12)
                    .background(Color.orange.opacity(0.8))
                    .clipShape(Circle())
            }

            Button(action: { showInfoModal = true }) {
                Image(systemName: "info.circle")
                    .font(.title2)
                    .foregroundColor(.white)
                    .padding(12)
                    .background(Color.purple.opacity(0.8))
                    .clipShape(Circle())
            }
        }
    }

    // Кнопки для портретной ориентации
    private var controlButtonsPortrait: some View {
        Group {
            Button(action: {
                useLiDAR.toggle()
                viewModel.restartSession(useLiDAR: useLiDAR)
                showTemporaryText(useLiDAR ? "LiDAR ВКЛ" : "LiDAR ВЫКЛ")
            }) {
                Image(systemName: "scope")
                    .font(.title2)
                    .foregroundColor(.white)
                    .padding(12)
                    .background(useLiDAR ? Color.green.opacity(0.8) : Color.gray.opacity(0.6))
                    .clipShape(Circle())
            }

            Button(action: {
                switch displayMode {
                case .rgbOnly:
                    displayMode = useLiDAR ? .depthOnly : .both
                    showTemporaryText("РЕЖИМ: LiDAR")
                case .depthOnly:
                    displayMode = .both
                    showTemporaryText("РЕЖИМ: ОБА")
                case .both:
                    displayMode = .rgbOnly
                    showTemporaryText("РЕЖИМ: RGB")
                }
                viewModel.switchDisplayMode(displayMode)
            }) {
                Image(systemName: displayModeIcon)
                    .font(.title2)
                    .foregroundColor(.white)
                    .padding(12)
                    .background(displayModeColor.opacity(0.8))
                    .clipShape(Circle())
            }

            Button(action: {
                viewModel.disconnect()
                isConnected = false
                isConnecting = false
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.white)
                    .padding(12)
                    .background(Color.red.opacity(0.8))
                    .clipShape(Circle())
            }

            Button(action: { showDebug.toggle() }) {
                Image(systemName: "gauge")
                    .font(.title2)
                    .foregroundColor(.white)
                    .padding(12)
                    .background(Color.orange.opacity(0.8))
                    .clipShape(Circle())
            }

            Button(action: { showInfoModal = true }) {
                Image(systemName: "info.circle")
                    .font(.title2)
                    .foregroundColor(.white)
                    .padding(12)
                    .background(Color.purple.opacity(0.8))
                    .clipShape(Circle())
            }
        }
    }


    // 🔹 ИСПРАВИЛ: Функция для показа временного текста
    private func showTemporaryText(_ text: String) {
        modeText = text
        // Сбрасываем анимацию перед показом нового текста
        withAnimation(.easeInOut(duration: 0.1)) {
            showModeText = false
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.easeInOut(duration: 0.3)) {
                showModeText = true
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    showModeText = false
                }
            }
        }
    }

        // 🔹 ВСПОМОГАТЕЛЬНЫЕ СВОЙСТВА ДЛЯ РЕЖИМОВ
        private var displayModeIcon: String {
            switch displayMode {
            case .rgbOnly:
                return "camera"
            case .depthOnly:
                return "waveform.path.ecg"
            case .both:
                return "square.split.2x1"
            }
        }
        
        private var displayModeColor: Color {
            switch displayMode {
            case .rgbOnly:
                return .blue
            case .depthOnly:
                return .green
            case .both:
                return .purple
            }
        }
        
       

    // 🔹 DEBUG ПАНЕЛЬ
    private var debugPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("📊 Debug информация")
                .font(.headline)
                .padding(.bottom, 4)

            Group {
                DebugRow(icon: "waveform.path.ecg", title: "Статус", value: viewModel.statusText)
                DebugRow(icon: "speedometer", title: "FPS", value: viewModel.fpsText)
                DebugRow(icon: "network", title: "Скорость", value: viewModel.networkSpeedText)
                DebugRow(icon: "chart.line.uptrend.xyaxis", title: "Пинг", value: viewModel.pingText)
            }

            Divider()
                .background(Color.white.opacity(0.3))

            Group {
                DebugRow(icon: "globe", title: "IP адрес", value: viewModel.currentIP)
                DebugRow(icon: "number", title: "Порт", value: viewModel.currentPort)
                DebugRow(icon: "point.3.connected.trianglepath.dotted", title: "Тип подключения", value: viewModel.connectionType.uppercased())
                DebugRow(icon: "scope", title: "LiDAR", value: useLiDAR ? "ВКЛ" : "ВЫКЛ")
                DebugRow(icon: "camera", title: "Зеркало", value: mirrorPreview ? "ВКЛ" : "ВЫКЛ")
            }
            
            Divider()
                .background(Color.white.opacity(0.3))
            
            // 🔹 IMU И ПОЗИЦИЯ
            Group {
                DebugRow(icon: "gyroscope", title: "IMU", value: viewModel.imuText)
                DebugRow(icon: "location.circle", title: "Позиция", value: viewModel.positionText)
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.8))
        .foregroundColor(.white)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
    }

    private func updateOrientation() {
        let o = UIDevice.current.orientation
        if o.isValidInterfaceOrientation {
            deviceOrientation = o

            // 🔹 Вычисляем правильный угол поворота камеры в зависимости от ориентации
            switch o {
            case .portrait:
                cameraRotation = 0
                deviceOrientationAngle = 0
                print("📱 Portrait: preview 180°, device 0°")
            case .portraitUpsideDown:
                cameraRotation = 0
                deviceOrientationAngle = 180
                print("📱 Portrait Upside Down: preview 0°, device 180°")
            case .landscapeLeft:
                // Провод слева
                cameraRotation = 180
                deviceOrientationAngle = 270
                print("📱 Landscape Left (провод слева): preview 90°, device 270°")
            case .landscapeRight:
                // Провод справа
                cameraRotation = 180
                deviceOrientationAngle = 90
                print("📱 Landscape Right (провод справа): preview 270°, device 90°")
            default:
                cameraRotation = 180
                deviceOrientationAngle = 0
            }
            viewModel.sendOrientation(degrees: deviceOrientationAngle)
        }
    }
}

// 🔹 КОМПОНЕНТ ДЛЯ DEBUG СТРОК
struct DebugRow: View {
    let icon: String
    let title: String
    let value: String
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 20)
            Text(title)
                .font(.subheadline)
            Spacer()
            Text(value.isEmpty ? "—" : value)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.semibold)
        }
    }
}

// MARK: — UIImage mirror helper
extension UIImage {
    func mirroredHorizontally() -> UIImage {
        guard let cg = self.cgImage else { return self }
        return UIImage(cgImage: cg, scale: self.scale, orientation: .upMirrored)
    }
}

// MARK: — InfoView (исправленная версия)
struct InfoView: View {
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("📱 ARStreamer - Инструкция")
                        .font(.title2)
                        .bold()
                    
                    InfoSection(title: "🎯 Назначение", content: "Приложение для трансляции AR-контента с устройства iOS на ПК в реальном времени с минимальной задержкой.")
                    
                    InfoSection(title: "🔧 Режимы передачи", content: """
                    • TCP (JPEG) - Надежный, хорошее качество
                    • UDP (H.264) - Высокая скорость, до 60 FPS  
                    • USB - Максимальное качество, минимальная задержка
                    """)
                    
                    InfoSection(title: "📡 LiDAR данные", content: "Передача карты глубины сенсора LiDAR для AR-приложений. Доступно на iPhone 12 Pro и новее.")
                    
                    InfoSection(title: "⚡ Управление в режиме трансляции", content: """
                    Портретная ориентация:
                    • ❌ - Остановить трансляцию (вернуться в меню)
                    • 🎯 - Вкл/Выкл LiDAR
                    • 🔁 - Зеркалить изображение
                    • 📊 - Показать/скрыть метрики
                    • 💡 - Эта инструкция

                    Альбомная ориентация:
                    • Все кнопки слева, метрики справа
                    • Такие же функции как в портретной
                    """)
                    
                    InfoSection(title: "🔙 Возврат в меню", content: "Нажмите кнопку ❌ в режиме трансляции чтобы вернуться в главное меню и остановить передачу данных.")
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}

struct InfoSection: View {
    let title: String
    let content: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundColor(.primary)
            
            Text(content)
                .font(.body)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// 🔹 НОВОЕ: Модальное окно "О приложении"
struct AboutView: View {
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Заголовок
                    VStack(spacing: 10) {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 50))
                            .foregroundColor(.blue)
                        
                        Text("ARStreamer")
                            .font(.title)
                            .bold()
                        
                        Text("Версия 1.0")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 10)

                    // Основное назначение
                    VStack(alignment: .leading, spacing: 12) {
                        Text("🎯 Основное назначение")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        Text("ARStreamer - это специализированное приложение для трансляции видео с камеры ARKit на ПК в реальном времени. Основное применение:")
                            .font(.body)
                            .foregroundColor(.secondary)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            FeatureRow(icon: "arkit", title: "AR проекты", description: "Идеально для разработки AR-приложений и компьютерного зрения")
                            FeatureRow(icon: "glasses", title: "AR очки", description: "Трансляция для AR-очков и шлемов виртуальной реальности")
                            FeatureRow(icon: "cube.transparent", title: "3D интерфейсы", description: "Создание интерактивных 3D интерфейсов и приложений")
                        }
                    }

                    // Важность LiDAR
                    VStack(alignment: .leading, spacing: 12) {
                        Text("📡 Критическая важность LiDAR")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        Text("LiDAR сенсор является ключевым компонентом для полноценной работы AR-функционала:")
                            .font(.body)
                            .foregroundColor(.secondary)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            LiDARFeatureRow(
                                title: "Без LiDAR",
                                description: "Ограниченный 2D интерфейс, отсутствие точного позиционирования в пространстве",
                                color: .red
                            )
                            
                            LiDARFeatureRow(
                                title: "С LiDAR",
                                description: "Полноценный 3D интерфейс, точное позиционирование объектов, карта глубины окружения",
                                color: .green
                            )
                        }
                    }

                    // Технические возможности
                    VStack(alignment: .leading, spacing: 12) {
                        Text("⚙️ Технические возможности")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            TechFeature(icon: "camera.fill", title: "60 FPS", color: .blue)
                            TechFeature(icon: "network", title: "3 режима", color: .green)
                            TechFeature(icon: "speedometer", title: "Низкая задержка", color: .orange)
                            TechFeature(icon: "move.3d", title: "3D позиционирование", color: .purple)
                        }
                    }

                    // Системные требования
                    VStack(alignment: .leading, spacing: 12) {
                        Text("📱 Системные требования")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        VStack(alignment: .leading, spacing: 6) {
                            RequirementRow(icon: "iphone", text: "iPhone с LiDAR (12 Pro/13 Pro/14 Pro/15 Pro)")
                            RequirementRow(icon: "desktopcomputer", text: "ПК с принимающим приложением")
                            RequirementRow(icon: "wifi", text: "WiFi сеть или USB подключение")
                        }
                    }
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}

// 🔹 КОМПОНЕНТЫ ДЛЯ ABOUT VIEW
struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.blue)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)
                Text(description)
                    .font(.body)
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct LiDARFeatureRow: View {
    let title: String
    let description: String
    let color: Color
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(color)
                Text(description)
                    .font(.body)
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct TechFeature: View {
    let icon: String
    let title: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
            
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.primary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(10)
    }
}

struct RequirementRow: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.blue)
                .frame(width: 20)
            
            Text(text)
                .font(.body)
                .foregroundColor(.secondary)
            
            Spacer()
        }
    }
}
