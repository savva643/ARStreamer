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
            
            HStack(spacing: 30) {
                // Левая часть: Заголовок и описание
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
                
                // Правая часть: Варианты ориентации
                VStack(spacing: 15) {
                    ForEach(OrientationManager.AppOrientation.allCases, id: \.self) { orientation in
                        Button(action: {
                            orientationManager.setOrientation(orientation)
                        }) {
                            HStack(spacing: 15) {
                                // Иконка
                                Image(systemName: orientation == .landscape ? "iphone.landscape" : "iphone")
                                    .font(.system(size: 30))
                                    .foregroundColor(.white)
                                    .frame(width: 40)
                                
                                // Текст
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
                                
                                // Галочка если выбрана
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
                    
                    // Кнопка подтверждения
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
