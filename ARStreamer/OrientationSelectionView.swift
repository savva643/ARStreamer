import SwiftUI

struct OrientationSelectionView: View {
    @ObservedObject var orientationManager = OrientationManager.shared
    @State private var showWarning = false
    
    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [Color.black, Color.blue.opacity(0.3)]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            GeometryReader { geometry in
                let isLandscape = geometry.size.width > geometry.size.height
                
                if isLandscape {
                    horizontalOrientationLayout
                } else {
                    verticalOrientationLayout
                }
            }
        }
        .alert("⚠️ Подтверждение", isPresented: $showWarning) {
            Button("Отмена", role: .cancel) { }
            Button("Заблокировать", role: .destructive) {
                orientationManager.lockOrientation()
            }
        } message: {
            Text("Ориентация будет заблокирована на \(orientationManager.selectedOrientation.rawValue).\n\nНЕ МЕНЯЙ ориентацию устройства во время использования приложения!")
        }
    }
    
    // ВЕРТИКАЛЬНЫЙ МАКЕТ
    private var verticalOrientationLayout: some View {
        VStack(spacing: 30) {
            VStack(spacing: 10) {
                Image(systemName: "iphone.landscape")
                    .font(.system(size: 50))
                    .foregroundColor(.cyan)
                
                Text("Выбери ориентацию")
                    .font(.title)
                    .foregroundColor(.white)
                
                Text("Эта ориентация будет заблокирована на всё время использования приложения")
                    .font(.caption)
                    .foregroundColor(.yellow)
                    .multilineTextAlignment(.center)
                    .padding()
            }
            
            Spacer()
            
            VStack(spacing: 20) {
                ForEach(OrientationManager.AppOrientation.allCases, id: \.self) { orientation in
                    Button(action: {
                        orientationManager.setOrientation(orientation)
                    }) {
                        HStack(spacing: 20) {
                            Image(systemName: orientation == .landscape ? "iphone.landscape" : "iphone")
                                .font(.system(size: 40))
                                .foregroundColor(.white)
                            
                            VStack(alignment: .leading, spacing: 5) {
                                Text(orientation.rawValue)
                                    .font(.headline)
                                    .foregroundColor(.white)
                                
                                Text(orientation == .landscape ?
                                     "Рекомендуется для AR" :
                                     "Альтернативный режим")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            
                            Spacer()
                            
                            if orientationManager.selectedOrientation == orientation {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 30))
                                    .foregroundColor(.green)
                            }
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(orientationManager.selectedOrientation == orientation ?
                                      Color.blue.opacity(0.3) :
                                      Color.gray.opacity(0.2))
                        )
                    }
                }
            }
            .padding()
            
            Spacer()
            
            Button(action: {
                showWarning = true
            }) {
                HStack {
                    Image(systemName: "lock.fill")
                    Text("Заблокировать и продолжить")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(12)
                .font(.headline)
            }
            .padding()
        }
        .padding()
    }
    
    // ГОРИЗОНТАЛЬНЫЙ МАКЕТ
    private var horizontalOrientationLayout: some View {
        HStack(spacing: 30) {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "iphone.landscape")
                    .font(.system(size: 60))
                    .foregroundColor(.cyan)
                
                Text("Выбери ориентацию")
                    .font(.title2)
                    .bold()
                    .foregroundColor(.white)
                
                Text("Эта ориентация будет заблокирована на всё время использования приложения")
                    .font(.caption)
                    .foregroundColor(.yellow)
                    .lineLimit(4)
                
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            
            VStack(spacing: 15) {
                ForEach(OrientationManager.AppOrientation.allCases, id: \.self) { orientation in
                    Button(action: {
                        orientationManager.setOrientation(orientation)
                    }) {
                        HStack(spacing: 15) {
                            Image(systemName: orientation == .landscape ? "iphone.landscape" : "iphone")
                                .font(.system(size: 30))
                                .foregroundColor(.white)
                                .frame(width: 40)
                            
                            VStack(alignment: .leading, spacing: 3) {
                                Text(orientation.rawValue)
                                    .font(.headline)
                                    .foregroundColor(.white)
                                
                                Text(orientation == .landscape ?
                                     "Рекомендуется" :
                                     "Альтернативный")
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                            }
                            
                            Spacer()
                            
                            if orientationManager.selectedOrientation == orientation {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 24))
                                    .foregroundColor(.green)
                            }
                        }
                        .padding(.horizontal, 15)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(orientationManager.selectedOrientation == orientation ?
                                      Color.blue.opacity(0.4) :
                                      Color.gray.opacity(0.2))
                        )
                    }
                }
                
                Spacer()
                
                Button(action: {
                    showWarning = true
                }) {
                    HStack {
                        Image(systemName: "lock.fill")
                        Text("Заблокировать")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                    .font(.headline)
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
        .padding()
    }
}

#Preview {
    OrientationSelectionView()
}
