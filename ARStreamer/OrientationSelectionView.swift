import SwiftUI

struct OrientationSelectionView: View {
    @ObservedObject var orientationManager = OrientationManager.shared
    @State private var showWarning = false
    
    var body: some View {
        ZStack {
            // Фон
            LinearGradient(
                gradient: Gradient(colors: [Color.black, Color.blue.opacity(0.3)]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            VStack(spacing: 30) {
                // Заголовок
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
                
                // Варианты ориентации
                VStack(spacing: 20) {
                    ForEach(OrientationManager.AppOrientation.allCases, id: \.self) { orientation in
                        Button(action: {
                            orientationManager.setOrientation(orientation)
                        }) {
                            HStack(spacing: 20) {
                                // Иконка
                                Image(systemName: orientation == .landscape ? "iphone.landscape" : "iphone")
                                    .font(.system(size: 40))
                                    .foregroundColor(.white)
                                
                                // Текст
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
                                
                                // Галочка если выбрана
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
                
                // Кнопка подтверждения
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
        .alert("⚠️ Подтверждение", isPresented: $showWarning) {
            Button("Отмена", role: .cancel) { }
            Button("Заблокировать", role: .destructive) {
                orientationManager.lockOrientation()
            }
        } message: {
            Text("Ориентация будет заблокирована на \(orientationManager.selectedOrientation.rawValue).\n\nНЕ МЕНЯЙ ориентацию устройства во время использования приложения!")
        }
    }
}

#Preview {
    OrientationSelectionView()
}
