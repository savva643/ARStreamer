import Foundation
import CoreMedia

// MARK: - GlaskiOS sensor stream protocol v2
//
// Каждый пакет (TCP, USB и Wi-Fi одинаково):
//   [type u8][sequence u64 BE][payloadSize u32 BE][payload]
// Все поля внутри payload — little-endian.
// Все таймстемпы — наносекунды аппаратных часов iPhone (host clock / mach_absolute_time),
// это общие часы для камеры (PTS кадра), CoreMotion и LiDAR.
// Полное описание: ARLauncherProject/docs/PROTOCOL_V2.md
enum StreamPacketType: UInt8 {
    case hello = 0x20
    case video = 0x21
    case imu = 0x22
    case depth = 0x23
    case audio = 0x24               // микрофон: PCM16
    case deviceOrientation = 0x0A   // legacy: Double градусы
}

enum StreamVideoCodec: UInt8 {
    case h264 = 1
    case hevc = 2
    case jpeg = 3
}

enum IMUSampleKind: UInt8 {
    case gyro = 0    // rad/s, сырой гироскоп (с bias), оси устройства
    case accel = 1   // m/s², specific force (в покое экраном вверх: z = +9.81), сырой акселерометр
    case mag = 2     // µT, сырой магнитометр
}

/// Host clock в наносекундах (те же часы, что у PTS камеры и CMLogItem.timestamp)
@inline(__always)
func hostTimeNs() -> Int64 {
    return Int64(CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) * 1_000_000_000.0)
}

@inline(__always)
func secondsToNs(_ seconds: Double) -> Int64 {
    return Int64(seconds * 1_000_000_000.0)
}

/// Быстрая сборка little-endian payload без промежуточных массивов
struct PacketWriter {
    private(set) var data: Data

    init(capacity: Int) {
        data = Data()
        data.reserveCapacity(capacity)
    }

    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
    mutating func i64(_ v: Int64) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func bytes(_ d: Data) { data.append(d) }
    mutating func bytes(_ p: UnsafeRawBufferPointer) { data.append(contentsOf: p) }
}

/// Метаданные кадра, которые идут вместе с видео (48 байт заголовка пакета video)
struct VideoFrameMeta {
    var ptsNs: Int64
    var width: Int
    var height: Int
    var fx: Float
    var fy: Float
    var cx: Float
    var cy: Float
    var exposureUs: UInt32
    /// Цвет исходного буфера камеры: 420f = full range; матрица из вложения kCVImageBufferYCbCrMatrixKey
    var fullRange: Bool = true
    var bt709: Bool = true
}

enum StreamPacketBuilder {
    static let videoHeaderSize = 48
    static let imuHeaderSize = 16
    static let imuRecordSize = 24
    static let depthHeaderSize = 32

    static func video(codec: StreamVideoCodec, keyframe: Bool, meta: VideoFrameMeta, bitstream: Data) -> Data {
        var w = PacketWriter(capacity: videoHeaderSize + bitstream.count)
        w.u8(codec.rawValue)
        // бит 0 keyframe, бит 1 «цвет указан», бит 2 full range, бит 3 BT.709
        var flags: UInt8 = keyframe ? 1 : 0
        flags |= 1 << 1
        if meta.fullRange { flags |= 1 << 2 }
        if meta.bt709 { flags |= 1 << 3 }
        w.u8(flags)
        w.u16(0)
        w.u16(UInt16(clamping: meta.width))
        w.u16(UInt16(clamping: meta.height))
        w.i64(meta.ptsNs)
        w.f32(meta.fx)
        w.f32(meta.fy)
        w.f32(meta.cx)
        w.f32(meta.cy)
        w.u32(meta.exposureUs)
        w.u32(0)
        w.i64(hostTimeNs())
        w.bytes(bitstream)
        return w.data
    }

    struct IMURecord {
        var tNs: Int64
        var kind: IMUSampleKind
        var x: Float
        var y: Float
        var z: Float
    }

    static func imu(_ records: [IMURecord]) -> Data {
        var w = PacketWriter(capacity: imuHeaderSize + records.count * imuRecordSize)
        w.u16(UInt16(clamping: records.count))
        w.u16(0)
        w.u32(0)
        w.i64(hostTimeNs())
        for r in records {
            w.i64(r.tNs)
            w.u8(r.kind.rawValue)
            w.u8(0); w.u8(0); w.u8(0)
            w.f32(r.x)
            w.f32(r.y)
            w.f32(r.z)
        }
        return w.data
    }

    /// depth: Float16 метры, плотно упакованы (width*height*2 байт)
    static func depth(tNs: Int64, width: Int, height: Int,
                      fx: Float, fy: Float, cx: Float, cy: Float,
                      float16Depth: Data) -> Data {
        var w = PacketWriter(capacity: depthHeaderSize + float16Depth.count)
        w.i64(tNs)
        w.u16(UInt16(clamping: width))
        w.u16(UInt16(clamping: height))
        w.u8(0)     // format: 0 = float16 meters
        w.u8(0)     // confidence: 0 = нет
        w.u16(0)
        w.f32(fx)
        w.f32(fy)
        w.f32(cx)
        w.f32(cy)
        w.bytes(float16Depth)
        return w.data
    }

    /// audio: [tNs i64 первого сэмпла][sampleRate u32][channels u8][format u8 = 1 PCM16][reserved u16] + сэмплы
    static func audio(tNs: Int64, sampleRate: Int, samples: UnsafeBufferPointer<Int16>) -> Data {
        var w = PacketWriter(capacity: 16 + samples.count * 2)
        w.i64(tNs)
        w.u32(UInt32(sampleRate))
        w.u8(1)     // каналов
        w.u8(1)     // PCM16 little-endian
        w.u16(0)
        w.bytes(UnsafeRawBufferPointer(samples))
        return w.data
    }

    static func hello() -> Data {
        var w = PacketWriter(capacity: 16)
        w.bytes(Data("GLSK".utf8))
        w.u16(2)    // protocol version
        w.u16(0)
        w.i64(hostTimeNs())
        return w.data
    }
}

/// Отправка пакетов поверх любого транспорта (NWConnection / USB) с учётом байтов «в полёте».
/// Если сеть не успевает, видео-кадры пропускаются ДО кодирования (IMU не теряется никогда),
/// поэтому задержка не накапливается.
final class PacketSender {
    typealias RawSend = (_ packet: Data, _ completion: @escaping (Error?) -> Void) -> Void

    private let rawSend: RawSend
    private let lock = NSLock()
    private var sequence: UInt64 = 0
    private var inFlight = 0
    private var sentBytesWindow = 0

    init(rawSend: @escaping RawSend) {
        self.rawSend = rawSend
    }

    var bytesInFlight: Int {
        lock.lock(); defer { lock.unlock() }
        return inFlight
    }

    /// Возвращает и обнуляет счётчик отправленных байт (для статистики)
    func takeSentBytes() -> Int {
        lock.lock(); defer { lock.unlock() }
        let v = sentBytesWindow
        sentBytesWindow = 0
        return v
    }

    func send(_ type: StreamPacketType, payload: Data) {
        lock.lock()
        sequence &+= 1
        let seq = sequence
        let total = 13 + payload.count
        inFlight += total
        sentBytesWindow += total
        lock.unlock()

        var packet = Data(capacity: total)
        packet.append(type.rawValue)
        var seqBE = seq.bigEndian
        withUnsafeBytes(of: &seqBE) { packet.append(contentsOf: $0) }
        var sizeBE = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &sizeBE) { packet.append(contentsOf: $0) }
        packet.append(payload)

        rawSend(packet) { [weak self] _ in
            guard let self = self else { return }
            self.lock.lock()
            self.inFlight -= total
            self.lock.unlock()
        }
    }
}
