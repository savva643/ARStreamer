import SwiftUI

struct LogsView: View {
    @State private var logContent: String = "Загрузка логов..."
    @State private var autoRefresh = true
    @State private var refreshTimer: Timer?
    
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // Заголовок с кнопками
            HStack {
                Button(action: clearLogs) {
                    HStack {
                        Image(systemName: "trash")
                        Text("Очистить")
                    }
                    .font(.caption)
                    .foregroundColor(.red)
                }
                
                Spacer()
                
                Toggle("Авто-обновление", isOn: $autoRefresh)
                    .font(.caption)
                
                Button(action: refreshLogs) {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(.blue)
                }
            }
            .padding()
            .background(Color(.systemGray6))
            
            // Логи
            ScrollViewReader { proxy in
                ScrollView {
                    SelectionView {
                        Text(logContent)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .textSelection(.enabled)
                            .id("logsEnd")
                    }
                }
                .onAppear {
                    refreshLogs()
                    proxy.scrollTo("logsEnd", anchor: .bottom)
                }
                .onChange(of: logContent) { _ in
                    proxy.scrollTo("logsEnd", anchor: .bottom)
                }
            }
        }
        .navigationTitle("Логи ARStreamer")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            startAutoRefresh()
        }
        .onDisappear {
            stopAutoRefresh()
        }
    }
    
    private func refreshLogs() {
        if let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let logFilePath = documentsPath.appendingPathComponent("ARStreamer.log")
            
            if FileManager.default.fileExists(atPath: logFilePath.path) {
                if let content = try? String(contentsOfFile: logFilePath.path, encoding: .utf8) {
                    logContent = content.isEmpty ? "Логи пусты" : content
                } else {
                    logContent = "Ошибка при чтении логов"
                }
            } else {
                logContent = "Файл логов еще не создан"
            }
        }
    }
    
    private func clearLogs() {
        if let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let logFilePath = documentsPath.appendingPathComponent("ARStreamer.log")
            try? FileManager.default.removeItem(at: logFilePath)
            logContent = "Логи очищены"
        }
    }
    
    private func startAutoRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            if autoRefresh {
                refreshLogs()
            }
        }
    }
    
    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}

#Preview {
    LogsView()
}
