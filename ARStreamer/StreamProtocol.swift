import Foundation
import CoreMedia
import simd

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
    case displayRequest = 0x26      // «верни картинку лаунчера»: режим, размер экрана, FOV
    case returnAck = 0x27           // кадр с ПК показан (время показа, запрос keyframe)
    case returnVideo = 0x30         // ПК -> телефон: готовый кадр лаунчера + поза для доворота
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

    /// DISPLAY (40 байт): что показывать на экране телефона. tan = 0 — FOV решает ПК (как у камеры)
    static func displayRequest(mode: UInt8, localCamera: Bool, hevc: Bool, width: Int, height: Int, fps: Int,
                               bitrateKbps: Int, tanX: Float, tanY: Float, ipd: Float, refreshHz: Float) -> Data {
        var w = PacketWriter(capacity: 40)
        w.u8(mode)
        var flags: UInt8 = 0
        if localCamera { flags |= 1 }
        if hevc { flags |= 2 }
        w.u8(flags)
        w.u16(UInt16(clamping: width))
        w.u16(UInt16(clamping: height))
        w.u16(UInt16(clamping: fps))
        w.u32(UInt32(clamping: bitrateKbps))
        w.f32(tanX)
        w.f32(tanY)
        w.f32(ipd)
        w.f32(refreshHz)
        w.u32(0)
        w.i64(hostTimeNs())
        return w.data
    }

    /// ACK (32 байта): кадр frameId показан в displayNs (часы телефона); frameId 0 + needKeyframe — просьба о keyframe
    static func returnAck(frameId: UInt32, needKeyframe: Bool, receivedNs: Int64, displayNs: Int64, decodeUs: UInt32) -> Data {
        var w = PacketWriter(capacity: 32)
        w.u32(frameId)
        w.u8(needKeyframe ? 1 : 0)
        w.u8(0); w.u8(0); w.u8(0)
        w.i64(receivedNs)
        w.i64(displayNs)
        w.u32(decodeUs)
        w.u32(0)
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

// MARK: - Обратный поток (ПК -> телефон)

/// Заголовок RETURN_VIDEO (128 байт), см. docs/PROTOCOL_V2.md «Возврат картинки»
struct ReturnFrameHeader {
    static let size = 128

    var codec: UInt8 = 1             // 1 H.264, 2 HEVC
    var keyframe = false
    var alpha = false                // кадр вдвое выше: снизу альфа (фон — своя камера)
    var fullRange = true
    var bt709 = true
    var layout: UInt8 = 1            // 1 моно, 2 SBS
    var mode: UInt8 = 1
    var width = 0
    var height = 0
    var frameId: UInt32 = 0
    var tRefNs: Int64 = 0
    var tTargetNs: Int64 = 0
    var tCameraNs: Int64 = 0
    var tSendNs: Int64 = 0
    var predFromRef = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    var eyeFromDevice = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    var cameraFromDevice = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    var gyroBias = SIMD3<Double>(0, 0, 0)
    var overscan: Float = 1
    var tanX: Float = 1
    var tanY: Float = 1
    var ipd: Float = 0.063

    init?(_ p: UnsafeRawBufferPointer) {
        guard p.count >= ReturnFrameHeader.size else { return nil }
        func u16(_ o: Int) -> Int { Int(p[o]) | (Int(p[o + 1]) << 8) }
        func u32(_ o: Int) -> UInt32 {
            UInt32(p[o]) | (UInt32(p[o + 1]) << 8) | (UInt32(p[o + 2]) << 16) | (UInt32(p[o + 3]) << 24)
        }
        func i64(_ o: Int) -> Int64 {
            var v: UInt64 = 0
            for i in (0..<8).reversed() { v = (v << 8) | UInt64(p[o + i]) }
            return Int64(bitPattern: v)
        }
        func f32(_ o: Int) -> Float { Float(bitPattern: u32(o)) }
        func quat(_ o: Int) -> simd_quatd {
            let q = simd_quatd(ix: Double(f32(o)), iy: Double(f32(o + 4)), iz: Double(f32(o + 8)), r: Double(f32(o + 12)))
            let n = simd_length(q.vector)
            return n > 1e-6 ? simd_quatd(vector: q.vector / n) : simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        }
        codec = p[0]
        let flags = p[1]
        keyframe = flags & 1 != 0
        alpha = flags & 2 != 0
        fullRange = flags & 4 != 0
        bt709 = flags & 8 != 0
        layout = p[2]
        mode = p[3]
        width = u16(4)
        height = u16(6)
        frameId = u32(8)
        tRefNs = i64(16)
        tTargetNs = i64(24)
        tCameraNs = i64(32)
        tSendNs = i64(40)
        predFromRef = quat(48)
        eyeFromDevice = quat(64)
        cameraFromDevice = quat(80)
        gyroBias = SIMD3(Double(f32(96)), Double(f32(100)), Double(f32(104)))
        overscan = max(1, f32(108))
        tanX = max(0.05, f32(112))
        tanY = max(0.05, f32(116))
        ipd = f32(120)
    }
}

/// Разбор входящих пакетов того же формата [type u8][seq u64 BE][size u32 BE][payload] (ПК -> телефон)
final class IncomingPacketParser {
    private var buffer = Data()
    private var readPos = 0

    func reset() {
        buffer.removeAll(keepingCapacity: true)
        readPos = 0
    }

    /// Добавить байты и вызвать onPacket для каждого целого пакета
    func feed(_ data: Data, onPacket: (UInt8, Data) -> Void) {
        buffer.append(data)
        while buffer.count - readPos >= 13 {
            let base = buffer.startIndex + readPos
            let type = buffer[base]
            var size = 0
            for i in 0..<4 { size = (size << 8) | Int(buffer[base + 9 + i]) }
            if size > 64 * 1024 * 1024 {
                // Поток испорчен — начинаем заново (ПК пришлёт keyframe по запросу)
                reset()
                return
            }
            guard buffer.count - readPos >= 13 + size else { break }
            let payload = buffer.subdata(in: (base + 13)..<(base + 13 + size))
            readPos += 13 + size
            onPacket(type, payload)
        }
        if readPos > 0 && (readPos == buffer.count || readPos > 1 << 20) {
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + readPos))
            readPos = 0
        }
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
