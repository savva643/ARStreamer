import Foundation
import CoreMotion

/// Сырые («грязные») данные IMU без фьюжна Apple:
/// гироскоп и акселерометр по 100 Гц (максимум CoreMotion), магнитометр 50 Гц.
/// Каждый сэмпл уходит со своим аппаратным таймстемпом (те же часы, что у PTS камеры),
/// ни один сэмпл не теряется и не «привязывается» к видеокадру.
final class RawIMUStreamer {
    /// Готовый payload пакета .imu
    var onPacket: ((Data) -> Void)?
    /// Строка для UI (вызывается ~5 раз в секунду, не на main)
    var onDebugText: ((String, String) -> Void)?

    private let motion = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "glaski.imu"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        return q
    }()

    // Доступ только из queue (она последовательная)
    private var pending: [StreamPacketBuilder.IMURecord] = []
    private var lastGyro = SIMD3<Float>(repeating: 0)
    private var lastAccel = SIMD3<Float>(repeating: 0)
    private var gyroCount = 0

    private static let gravity: Double = 9.80665

    func start(rateHz: Double = 100) {
        let interval = 1.0 / rateHz
        pending.reserveCapacity(16)

        if motion.isGyroAvailable {
            motion.gyroUpdateInterval = interval
            motion.startGyroUpdates(to: queue) { [weak self] data, _ in
                guard let self = self, let d = data else { return }
                let r = d.rotationRate
                self.lastGyro = SIMD3(Float(r.x), Float(r.y), Float(r.z))
                self.pending.append(.init(tNs: secondsToNs(d.timestamp), kind: .gyro,
                                          x: Float(r.x), y: Float(r.y), z: Float(r.z)))
                self.gyroCount += 1
                // Гироскоп — опорный поток: отправляем пачку на каждом его сэмпле
                self.flush()
                if self.gyroCount % 20 == 0 { self.publishDebug() }
            }
        } else {
            logToFile("❌ Gyroscope not available")
        }

        if motion.isAccelerometerAvailable {
            motion.accelerometerUpdateInterval = interval
            motion.startAccelerometerUpdates(to: queue) { [weak self] data, _ in
                guard let self = self, let d = data else { return }
                // CoreMotion отдаёт ускорение в g со знаком «минус specific force»
                // (лежит экраном вверх → z = -1). Переводим в стандарт IMU: m/s², в покое z = +9.81.
                let a = d.acceleration
                let ax = Float(-a.x * RawIMUStreamer.gravity)
                let ay = Float(-a.y * RawIMUStreamer.gravity)
                let az = Float(-a.z * RawIMUStreamer.gravity)
                self.lastAccel = SIMD3(ax, ay, az)
                self.pending.append(.init(tNs: secondsToNs(d.timestamp), kind: .accel, x: ax, y: ay, z: az))
                if self.pending.count >= 8 { self.flush() }
            }
        } else {
            logToFile("❌ Accelerometer not available")
        }

        if motion.isMagnetometerAvailable {
            motion.magnetometerUpdateInterval = 1.0 / 50.0
            motion.startMagnetometerUpdates(to: queue) { [weak self] data, _ in
                guard let self = self, let d = data else { return }
                let m = d.magneticField
                self.pending.append(.init(tNs: secondsToNs(d.timestamp), kind: .mag,
                                          x: Float(m.x), y: Float(m.y), z: Float(m.z)))
            }
        }

        logToFile("✅ Raw IMU started: gyro/accel \(Int(rateHz)) Hz, mag 50 Hz")
    }

    func stop() {
        motion.stopGyroUpdates()
        motion.stopAccelerometerUpdates()
        motion.stopMagnetometerUpdates()
        queue.addOperation { [weak self] in self?.pending.removeAll() }
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        let payload = StreamPacketBuilder.imu(pending)
        pending.removeAll(keepingCapacity: true)
        onPacket?(payload)
    }

    private func publishDebug() {
        let g = lastGyro
        let a = lastAccel
        let imu = String(format: "IMU: A(%.2f,%.2f,%.2f) G(%.2f,%.2f,%.2f)", a.x, a.y, a.z, g.x, g.y, g.z)
        let rate = String(format: "Gyro |ω| = %.2f rad/s", sqrt(g.x * g.x + g.y * g.y + g.z * g.z))
        onDebugText?(imu, rate)
    }
}
