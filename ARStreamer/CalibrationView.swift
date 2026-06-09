import SwiftUI
import AVFoundation

struct CalibrationView: View {
    @ObservedObject var orientationManager = OrientationManager.shared
    @State private var calibrationStep = 0
    @State private var isCalibrationComplete = false
    @State private var cameraPreview: UIImage?
    @State private var statusMessage = "Инициализация калибровки..."
    
    var steps: [String] {
        let baseSteps = [
            "📐 Шаг 1: Исходное положение",
            "📐 Шаг 2: Поворот на 90°",
            "📐 Шаг 3: Поворот на 180°",
            "📐 Шаг 4: Поворот на 270°",
            "✅ Калибровка завершена!"
        ]
        return baseSteps
    }
    
    var instructions: [String] {
        let isLandscape = orientationManager.selectedOrientation == .landscape
        let baseInstructions = isLandscape ? [
            "Держи iPhone горизонтально (landscape).\nКамера должна смотреть прямо перед тобой.\nНажми 'Далее' когда готов.",
            "Поверни iPhone на 90° по часовой стрелке.\nУбедись, что положение стабильно.\nНажми 'Далее'.",
            "Поверни iPhone на 180° (вверх ногами).\nКамера должна смотреть в противоположную сторону.\nНажми 'Далее'.",
            "Поверни iPhone на 270° (или -90°).\nПроверь стабильность положения.\nНажми 'Завершить'.",
            "Калибровка успешно завершена!\nТвои intrinsics сохранены.\nПриложение готово к работе."
        ] : [
            "Держи iPhone вертикально (portrait).\nКамера должна смотреть прямо перед тобой.\nНажми 'Далее' когда готов.",
            "Поверни iPhone на 90° по часовой стрелке.\nУбедись, что положение стабильно.\nНажми 'Далее'.",
            "Поверни iPhone на 180° (вверх ногами).\nКамера должна смотреть в противоположную сторону.\nНажми 'Далее'.",
            "Поверни iPhone на 270° (или -90°).\nПроверь стабильность положения.\nНажми 'Завершить'.",
            "Калибровка успешно завершена!\nТвои intrinsics сохранены.\nПриложение готово к работе."
        ]
        return baseInstructions
    }
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            GeometryReader { geometry in
                let isLandscape = geometry.size.width > geometry.size.height
                
                if isLandscape {
                    // ГОРИЗОНТАЛЬНЫЙ МАКЕТ
                    horizontalLayout
                } else {
                    // ВЕРТИКАЛЬНЫЙ МАКЕТ
                    verticalLayout
                }
            }
        }
    }
    
    // ВЕРТИКАЛЬНЫЙ МАКЕТ
    private var verticalLayout: some View {
        VStack(spacing: 20) {
            // Заголовок с ориентацией
            VStack(spacing: 5) {
                Text("Калибровка камеры")
                    .font(.title)
                    .foregroundColor(.white)
                
                HStack {
                    Image(systemName: orientationManager.selectedOrientation == .landscape ? "iphone.landscape" : "iphone")
                        .foregroundColor(.cyan)
                    Text(orientationManager.selectedOrientation.rawValue)
                        .foregroundColor(.cyan)
                        .font(.caption)
                }
            }
            .padding()
            
            // Прогресс
            ProgressView(value: Double(calibrationStep), total: 5.0)
                .tint(.blue)
                .padding()
            
            // Текущий шаг
            Text(steps[calibrationStep])
                .font(.headline)
                .foregroundColor(.cyan)
                .padding()
            
            // Инструкции
            VStack(alignment: .leading, spacing: 10) {
                Text("📋 Инструкции:")
                    .font(.subheadline)
                    .foregroundColor(.gray)
                
                Text(instructions[calibrationStep])
                    .font(.body)
                    .foregroundColor(.white)
                    .lineLimit(nil)
            }
            .padding()
            .background(Color.gray.opacity(0.2))
            .cornerRadius(10)
            
            // Статус
            Text(statusMessage)
                .font(.caption)
                .foregroundColor(.yellow)
                .padding()
            
            // Диаграмма ориентации
            OrientationDiagramView(step: calibrationStep)
                .frame(height: 150)
                .padding()
            
            Spacer()
            
            // Кнопки
            HStack(spacing: 15) {
                if calibrationStep > 0 {
                    Button(action: { calibrationStep -= 1 }) {
                        Text("← Назад")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.gray)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                }
                
                Button(action: nextStep) {
                    Text(calibrationStep < 4 ? "Далее →" : "Завершить ✓")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
            }
            .padding()
        }
        .padding()
    }
    
    // ГОРИЗОНТАЛЬНЫЙ МАКЕТ
    private var horizontalLayout: some View {
        HStack(spacing: 20) {
            // Левая часть: Инструкции
            VStack(spacing: 15) {
                VStack(spacing: 5) {
                    Text("Калибровка")
                        .font(.title2)
                        .bold()
                        .foregroundColor(.white)
                    
                    HStack {
                        Image(systemName: orientationManager.selectedOrientation == .landscape ? "iphone.landscape" : "iphone")
                            .foregroundColor(.cyan)
                            .font(.system(size: 14))
                        Text(orientationManager.selectedOrientation.rawValue)
                            .foregroundColor(.cyan)
                            .font(.caption2)
                    }
                }
                
                VStack(spacing: 5) {
                    Text("Шаг \(calibrationStep + 1) из 5")
                        .font(.caption)
                        .foregroundColor(.gray)
                    ProgressView(value: Double(calibrationStep), total: 5.0)
                        .tint(.blue)
                }
                
                Text(steps[calibrationStep])
                    .font(.headline)
                    .foregroundColor(.cyan)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("📋 Инструкции:")
                        .font(.caption)
                        .foregroundColor(.gray)
                    
                    Text(instructions[calibrationStep])
                        .font(.caption)
                        .foregroundColor(.white)
                        .lineLimit(4)
                }
                .padding()
                .background(Color.gray.opacity(0.2))
                .cornerRadius(8)
                
                Text(statusMessage)
                    .font(.caption2)
                    .foregroundColor(.yellow)
                
                Spacer()
                
                VStack(spacing: 10) {
                    if calibrationStep > 0 {
                        Button(action: { calibrationStep -= 1 }) {
                            Text("← Назад")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(Color.gray)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                                .font(.caption)
                        }
                    }
                    
                    Button(action: nextStep) {
                        Text(calibrationStep < 4 ? "Далее →" : "Завершить ✓")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                            .font(.caption)
                    }
                }
            }
            .frame(maxWidth: 280)
            .padding()
            
            // Правая часть: Диаграмма
            VStack(spacing: 10) {
                Text("Положение iPhone")
                    .font(.caption)
                    .foregroundColor(.gray)
                
                OrientationDiagramView(step: calibrationStep)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                Text("Поворачивай на \(calibrationStep * 90)°")
                    .font(.caption2)
                    .foregroundColor(.cyan)
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(10)
        }
        .padding()
    }
    
    private func nextStep() {
        if calibrationStep < 4 {
            statusMessage = "Записываю данные для шага \(calibrationStep + 1)..."
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                calibrationStep += 1
                statusMessage = "Готово! Переходим к следующему шагу."
            }
        } else {
            // Завершаем калибровку и блокируем ориентацию
            orientationManager.markCalibrated()
            orientationManager.lockOrientation()
            isCalibrationComplete = true
            statusMessage = "✅ Калибровка завершена! Ориентация заблокирована."
        }
    }
}

struct OrientationDiagramView: View {
    let step: Int
    
    var body: some View {
        ZStack {
            // Фон
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.gray.opacity(0.3))
            
            // Диаграмма
            VStack {
                Text("Текущая ориентация:")
                    .font(.caption)
                    .foregroundColor(.gray)
                
                ZStack {
                    // Рамка устройства
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white, lineWidth: 2)
                        .frame(width: 120, height: 70)
                    
                    // Камера (точка)
                    Circle()
                        .fill(Color.red)
                        .frame(width: 12, height: 12)
                        .offset(x: -50, y: 0)
                    
                    // Стрелка направления
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.cyan)
                        .rotationEffect(.degrees(Double(step) * 90))
                    
                    // Текст ориентации
                    Text(getOrientationText(step))
                        .font(.caption2)
                        .foregroundColor(.yellow)
                        .offset(y: 40)
                }
            }
        }
    }
    
    private func getOrientationText(_ step: Int) -> String {
        switch step {
        case 0: return "0° (Landscape Right)"
        case 1: return "90° (Portrait Up)"
        case 2: return "180° (Landscape Left)"
        case 3: return "270° (Portrait Down)"
        default: return "✓ Готово"
        }
    }
}

#Preview {
    CalibrationView()
}
