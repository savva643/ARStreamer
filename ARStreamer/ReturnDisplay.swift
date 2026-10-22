import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import UIKit
import simd

// MARK: - Картинка лаунчера с ПК на экране iPhone
//
// Телефон шлёт DISPLAY (режим, размер экрана, FOV линз), ПК рендерит под него и возвращает кадры H.264
// по тому же TCP. В каждом кадре — поза, под которую он нарисован. Перед показом телефон
// доворачивает кадр своим гироскопом (как ATW в VR-шлемах): поворот головы виден с задержкой
// экрана телефона, а не всей цепочки «камера → ПК → кодер → сеть → декодер».
// Эталон математики — ReturnCompositor в SensorStream/tools/stream_simulator.cpp (проверен против истины).

enum ReturnDisplayMode: UInt8 {
    case off = 0
    case mono = 1          // один вид на весь экран
    case stereo = 2        // два глаза рядом, без линз
    case stereoLens = 3    // два глаза + искажение под линзы VR-очков
}

/// Настройки (UserDefaults, правятся в SettingsView)
struct ReturnDisplaySettings {
    var localCamera = false          // фон — своя камера телефона (быстрее), с ПК только объекты
    var renderScale = 0.5            // доля родного разрешения экрана, которую рендерит ПК
    var bitrateMbps = 15
    var timewarp = true              // доворот по гироскопу
    // Линзы (по умолчанию — Cardboard v2)
    var interLensMm = 63.9
    var screenToLensMm = 39.0
    var lensOffsetYMm = 0.0          // центр линз ниже(+) центра экрана
    var k1 = 0.34
    var k2 = 0.55
    var chroma = 0.012
    var fovDeg = 90.0                // полный угол глаза (обрезка; шире камеры iPhone всё равно чёрное)
    var ppi = 460.0                  // плотность экрана (все iPhone Pro с LiDAR — 458–460)

    static func load() -> ReturnDisplaySettings {
        let d = UserDefaults.standard
        var s = ReturnDisplaySettings()
        func dbl(_ key: String, _ fallback: Double) -> Double {
            d.object(forKey: key) == nil ? fallback : d.double(forKey: key)
        }
        s.localCamera = d.bool(forKey: "returnLocalCamera")
        s.renderScale = dbl("returnRenderScale", s.renderScale)
        s.bitrateMbps = Int(dbl("returnBitrateMbps", Double(s.bitrateMbps)))
        s.timewarp = d.object(forKey: "returnTimewarp") == nil ? true : d.bool(forKey: "returnTimewarp")
        s.interLensMm = dbl("lensInterMm", s.interLensMm)
        s.screenToLensMm = dbl("lensScreenMm", s.screenToLensMm)
        s.lensOffsetYMm = dbl("lensOffsetYMm", s.lensOffsetYMm)
        s.k1 = dbl("lensK1", s.k1)
        s.k2 = dbl("lensK2", s.k2)
        s.chroma = dbl("lensChroma", s.chroma)
        s.fovDeg = dbl("lensFovDeg", s.fovDeg)
        s.ppi = dbl("screenPpi", s.ppi)
        return s
    }
}

/// Линзы VR-очков. Лупа даёт подушку: угол глаза растёт быстрее экранной координаты,
/// t = s (1 + k1 s² + k2 s⁴), s — точка экрана относительно центра линзы в tan (мм / расстояние до линзы).
/// Поэтому кадр на экране рисуется «бочкой», а линза его выпрямляет. Тот же расчёт — в шейдере.
struct LensModel {
    var screenWmm: Double
    var screenHmm: Double
    var interLensMm: Double
    var screenToLensMm: Double
    var offsetYmm: Double
    var k1: Double
    var k2: Double
    var maxTan: Double

    init(settings: ReturnDisplaySettings, screenPixels: CGSize) {
        screenWmm = Double(screenPixels.width) / settings.ppi * 25.4
        screenHmm = Double(screenPixels.height) / settings.ppi * 25.4
        interLensMm = settings.interLensMm
        screenToLensMm = max(10, settings.screenToLensMm)
        offsetYmm = settings.lensOffsetYMm
        k1 = settings.k1
        k2 = settings.k2
        maxTan = tan(min(max(settings.fovDeg, 30), 140) * 0.5 * .pi / 180)
    }

    /// tan угла глаза для точки экрана (мм, x вправо, y вниз)
    func eyeTan(eye: Int, mmX: Double, mmY: Double) -> SIMD2<Double> {
        let cx = screenWmm * 0.5 + (eye == 0 ? -0.5 : 0.5) * interLensMm
        let cy = screenHmm * 0.5 + offsetYmm
        let d = SIMD2((mmX - cx) / screenToLensMm, -(mmY - cy) / screenToLensMm)
        let r2 = simd_length_squared(d)
        return d * (1 + k1 * r2 + k2 * r2 * r2)
    }

    /// Полуугол (tan), который глаз видит через свою половину экрана — столько и просим отрендерить
    func requestTan() -> SIMD2<Double> {
        var t = SIMD2<Double>(0, 0)
        for x in [0.0, screenWmm * 0.5] {
            for y in [0.0, screenHmm * 0.5, screenHmm] {
                let e = eyeTan(eye: 0, mmX: x, mmY: y)
                t = simd_max(t, simd_abs(e))
            }
        }
        return simd_min(t, SIMD2(maxTan, maxTan))
    }
}

// MARK: - История ориентации по гироскопу (для доворота)

/// Интеграл сырого гироскопа: ориентация устройства в произвольном начальном базисе.
/// Нужны только относительные повороты (от момента позы ПК до момента показа), поэтому дрейф не важен.
final class GyroHistory {
    private struct Entry {
        var t: Int64
        var q: simd_quatd
        var w: SIMD3<Double>
    }
    private var entries: [Entry] = []
    private let capacity = 512
    private var head = 0
    private var count = 0
    private var bias = SIMD3<Double>(0, 0, 0)
    private let lock = NSLock()

    init() {
        entries = Array(repeating: Entry(t: 0, q: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1), w: .zero), count: capacity)
    }

    func setBias(_ b: SIMD3<Double>) {
        lock.lock(); bias = b; lock.unlock()
    }

    func add(tNs: Int64, rate: SIMD3<Double>) {
        lock.lock(); defer { lock.unlock() }
        let w = rate - bias
        if count == 0 {
            entries[0] = Entry(t: tNs, q: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1), w: w)
            head = 0
            count = 1
            return
        }
        let last = entries[head]
        guard tNs > last.t else { return }
        let dt = min(Double(tNs - last.t) * 1e-9, 0.05)
        // Трапеция по угловой скорости: поворот в осях тела
        let q = simd_normalize(last.q * GyroHistory.expMap((last.w + w) * 0.5, dt))
        head = (head + 1) % capacity
        entries[head] = Entry(t: tNs, q: q, w: w)
        count = min(count + 1, capacity)
    }

    /// Ориентация на момент t: интерполяция по истории, вперёд — экстраполяция последней скоростью (≤ 60 мс)
    func orientation(at t: Int64) -> simd_quatd? {
        lock.lock(); defer { lock.unlock() }
        guard count > 0 else { return nil }
        let newest = entries[head]
        if t >= newest.t {
            let dt = min(Double(t - newest.t) * 1e-9, 0.06)
            return simd_normalize(newest.q * GyroHistory.expMap(newest.w, dt))
        }
        let oldestIndex = (head - count + 1 + capacity) % capacity
        if t <= entries[oldestIndex].t {
            return Double(entries[oldestIndex].t - t) < 0.3e9 ? entries[oldestIndex].q : nil
        }
        // Бинарный поиск по кольцу
        var lo = 0, hi = count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if entries[(oldestIndex + mid) % capacity].t <= t { lo = mid } else { hi = mid }
        }
        let a = entries[(oldestIndex + lo) % capacity]
        let b = entries[(oldestIndex + hi) % capacity]
        let u = b.t > a.t ? Double(t - a.t) / Double(b.t - a.t) : 0
        return simd_slerp(a.q, b.q, u)
    }

    private static func expMap(_ w: SIMD3<Double>, _ dt: Double) -> simd_quatd {
        let angle = simd_length(w) * dt
        if angle < 1e-12 { return simd_quatd(ix: 0, iy: 0, iz: 0, r: 1) }
        return simd_quatd(angle: angle, axis: simd_normalize(w))
    }
}

// MARK: - Декодер (VideoToolbox, минимальная задержка)

final class ReturnVideoDecoder {
    struct Output {
        let pixelBuffer: CVPixelBuffer
        let header: ReturnFrameHeader
        let receivedNs: Int64
        let decodedNs: Int64
    }

    var onFrame: ((Output) -> Void)?
    /// Нужен keyframe (ошибка декодера или ещё не было параметров)
    var onNeedKeyframe: (() -> Void)?

    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var parameterSets: [Data] = []
    private var codec: UInt8 = 0

    func reset() {
        if let s = session { VTDecompressionSessionInvalidate(s) }
        session = nil
        format = nil
        parameterSets = []
    }

    /// payload — пакет RETURN_VIDEO целиком (заголовок + Annex-B). Вызывать с одной очереди.
    func decode(_ payload: Data, receivedNs: Int64) {
        guard let header = payload.withUnsafeBytes({ ReturnFrameHeader($0) }) else { return }
        let nals = ReturnVideoDecoder.splitAnnexB(payload, from: ReturnFrameHeader.size)
        let hevc = header.codec == 2
        if header.codec != codec {
            reset()
            codec = header.codec
        }

        var params: [Data] = []
        var slices: [Data] = []
        for nal in nals where !nal.isEmpty {
            let type = hevc ? (Int(nal[nal.startIndex]) >> 1) & 0x3F : Int(nal[nal.startIndex]) & 0x1F
            let isParam = hevc ? (type >= 32 && type <= 34) : (type == 7 || type == 8)
            let isAud = hevc ? type == 35 : type == 9
            if isParam { params.append(nal) } else if !isAud { slices.append(nal) }
        }
        if !params.isEmpty && params != parameterSets {
            parameterSets = params
            if !makeSession(hevc: hevc) {
                onNeedKeyframe?()
                return
            }
        }
        guard let session = session, let format = format, !slices.isEmpty else {
            if session == nil { onNeedKeyframe?() }
            return
        }

        // AVCC: длина (4 байта BE) + NAL
        var avcc = Data(capacity: slices.reduce(0) { $0 + $1.count + 4 })
        for nal in slices {
            var len = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &len) { avcc.append(contentsOf: $0) }
            avcc.append(nal)
        }

        var block: CMBlockBuffer?
        let total = avcc.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: total,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: total, flags: 0,
                                                 blockBufferOut: &block) == noErr, let bb = block else { return }
        let copied = avcc.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: bb, offsetIntoDestination: 0, dataLength: total)
        }
        guard copied == noErr else { return }

        var sample: CMSampleBuffer?
        var sizes = [total]
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: bb, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &sizes,
                                        sampleBufferOut: &sample) == noErr, let sb = sample else { return }

        // Синхронно (флаги без асинхронности): кадр готов к возврату из вызова
        var infoOut = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb, flags: [], infoFlagsOut: &infoOut) {
            [weak self] status, _, imageBuffer, _, _ in
            guard let self = self else { return }
            guard status == noErr, let pb = imageBuffer else {
                self.onNeedKeyframe?()
                return
            }
            self.onFrame?(Output(pixelBuffer: pb, header: header, receivedNs: receivedNs, decodedNs: hostTimeNs()))
        }
        if status != noErr {
            logToFile("⚠️ Return decode error \(status)")
            if status == kVTInvalidSessionErr { reset() }
            onNeedKeyframe?()
        }
    }

    private func makeSession(hevc: Bool) -> Bool {
        if let s = session { VTDecompressionSessionInvalidate(s) }
        session = nil
        format = nil

        var desc: CMVideoFormatDescription?
        let status: OSStatus = withPointers(parameterSets) { pointers, sizes in
            if hevc {
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: pointers.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &desc)
            }
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: pointers.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
        }
        guard status == noErr, let fmt = desc else {
            logToFile("❌ Return: bad parameter sets (\(status))")
            return false
        }

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var newSession: VTDecompressionSession?
        let created = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: fmt,
                                                   decoderSpecification: nil,
                                                   imageBufferAttributes: attrs as CFDictionary,
                                                   outputCallback: nil, decompressionSessionOut: &newSession)
        guard created == noErr, let s = newSession else {
            logToFile("❌ Return: VTDecompressionSessionCreate \(created)")
            return false
        }
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = s
        format = fmt
        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        logToFile("📺 Return decoder \(hevc ? "HEVC" : "H.264") \(dims.width)x\(dims.height)")
        return true
    }

    /// Указатели на байты параметров на время вызова body
    private func withPointers<R>(_ sets: [Data], _ body: ([UnsafePointer<UInt8>], [Int]) -> R) -> R {
        var buffers: [UnsafeMutablePointer<UInt8>] = []
        defer { buffers.forEach { $0.deallocate() } }
        for d in sets {
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, d.count))
            d.copyBytes(to: p, count: d.count)
            buffers.append(p)
        }
        return body(buffers.map { UnsafePointer($0) }, sets.map { $0.count })
    }

    /// NAL-юниты из Annex-B (start code 00 00 01 или 00 00 00 01), без start code
    static func splitAnnexB(_ data: Data, from offset: Int) -> [Data] {
        var result: [Data] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let n = raw.count
            var i = offset
            var start = -1
            while i + 2 < n {
                if raw[i] == 0 && raw[i + 1] == 0 && raw[i + 2] == 1 {
                    if start >= 0 {
                        var end = i
                        if end > start && raw[end - 1] == 0 { end -= 1 }   // 4-байтный start code
                        result.append(Data(bytes: raw.baseAddress! + start, count: end - start))
                    }
                    i += 3
                    start = i
                } else {
                    i += 1
                }
            }
            if start >= 0 && start < n {
                result.append(Data(bytes: raw.baseAddress! + start, count: n - start))
            }
        }
        return result
    }
}

// MARK: - Контроллер: приём, декод, кадры для экрана, ACK

final class ReturnDisplay {
    static let shared = ReturnDisplay()

    struct CameraFrame {
        let pixelBuffer: CVPixelBuffer
        let ptsNs: Int64
        let fx: Float, fy: Float, cx: Float, cy: Float
        let fullRange: Bool
        let bt709: Bool
    }

    /// Отправка пакета на ПК (ставит ARStreamer, пока идёт поток)
    var send: ((StreamPacketType, Data) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _send }
        set { lock.lock(); _send = newValue; lock.unlock() }
    }

    let gyro = GyroHistory()

    private let lock = NSLock()
    private var _send: ((StreamPacketType, Data) -> Void)?
    private let queue = DispatchQueue(label: "glaski.return", qos: .userInteractive)
    private let parser = IncomingPacketParser()     // только queue
    private let decoder = ReturnVideoDecoder()      // только queue
    private var latest: ReturnVideoDecoder.Output?
    private var latestCamera: CameraFrame?
    private var mode: ReturnDisplayMode = .off
    private var localCamera = false
    private var lastKeyRequestNs: Int64 = 0

    // Статистика (для оверлея)
    private var framesWindow = 0
    private var windowStart = CACurrentMediaTime()
    private(set) var fps: Double = 0
    private var latencySumMs = 0.0
    private var latencyCount = 0
    private(set) var cameraToPhotonMs: Double = 0
    private(set) var targetToPhotonMs: Double = 0

    private init() {
        decoder.onFrame = { [weak self] out in
            guard let self = self else { return }
            self.gyro.setBias(out.header.gyroBias)
            self.lock.lock()
            self.latest = out
            self.framesWindow += 1
            self.lock.unlock()
        }
        decoder.onNeedKeyframe = { [weak self] in self?.requestKeyframe() }
    }

    var currentMode: ReturnDisplayMode {
        lock.lock(); defer { lock.unlock() }; return mode
    }

    /// Камера телефона нужна экрану (фон — своя камера)
    var wantsCameraFrames: Bool {
        lock.lock(); defer { lock.unlock() }; return mode != .off && localCamera
    }

    // MARK: Сеть

    /// Новое соединение — старый хвост байтов недействителен
    func resetStream() {
        queue.async {
            self.parser.reset()
            self.decoder.reset()
        }
    }

    /// Байты от ПК (любая очередь)
    func feed(_ data: Data) {
        let receivedNs = hostTimeNs()
        queue.async {
            self.parser.feed(data) { type, payload in
                guard type == StreamPacketType.returnVideo.rawValue else { return }
                // Если очередь отстала — декодировать всё равно нужно (P-кадры), но показ берёт только свежий
                self.decoder.decode(payload, receivedNs: receivedNs)
            }
        }
    }

    // MARK: Режим

    /// Попросить ПК показывать картинку на этом экране (или выключить: .off)
    func request(mode newMode: ReturnDisplayMode) {
        let s = ReturnDisplaySettings.load()
        lock.lock()
        mode = newMode
        localCamera = s.localCamera
        if newMode == .off { latest = nil }
        lock.unlock()
        sendRequest(settings: s)
    }

    /// Повторить запрос (после переподключения ПК его не помнит)
    func resendRequest() {
        guard currentMode != .off else { return }
        sendRequest(settings: ReturnDisplaySettings.load())
    }

    private func sendRequest(settings s: ReturnDisplaySettings) {
        let m = currentMode
        let native = ReturnDisplay.landscapeNativeSize()
        let scale = min(max(s.renderScale, 0.25), 1.0)
        let w = (Int(native.width * scale) / 2) * 2
        let h = (Int(native.height * scale) / 2) * 2
        var tan = SIMD2<Double>(0, 0)
        if m == .stereoLens {
            tan = LensModel(settings: s, screenPixels: native).requestTan()
        }
        let refresh = Float(UIScreen.main.maximumFramesPerSecond)
        let payload = StreamPacketBuilder.displayRequest(
            mode: m.rawValue, localCamera: s.localCamera, hevc: false, width: w, height: h,
            fps: min(60, Int(refresh)), bitrateKbps: s.bitrateMbps * 1000,
            tanX: Float(tan.x), tanY: Float(tan.y), ipd: Float(s.interLensMm / 1000), refreshHz: refresh)
        send?(.displayRequest, payload)
        logToFile("📺 Display request \(m) \(w)x\(h) local camera \(s.localCamera)")
    }

    func requestKeyframe() {
        let now = hostTimeNs()
        lock.lock()
        let tooSoon = now - lastKeyRequestNs < 300_000_000
        if !tooSoon { lastKeyRequestNs = now }
        lock.unlock()
        guard !tooSoon else { return }
        send?(.returnAck, StreamPacketBuilder.returnAck(frameId: 0, needKeyframe: true, receivedNs: now, displayNs: 0, decodeUs: 0))
    }

    // MARK: Кадры для экрана

    func latestFrame() -> ReturnVideoDecoder.Output? {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    func setCameraFrame(_ frame: CameraFrame) {
        lock.lock(); latestCamera = frame; lock.unlock()
    }

    func cameraFrame() -> CameraFrame? {
        lock.lock(); defer { lock.unlock() }
        return latestCamera
    }

    /// Кадр впервые показан на экране (presentedTime)
    func framePresented(_ out: ReturnVideoDecoder.Output, displayNs: Int64) {
        let decodeUs = UInt32(clamping: max(0, (out.decodedNs - out.receivedNs) / 1000))
        send?(.returnAck, StreamPacketBuilder.returnAck(frameId: out.header.frameId, needKeyframe: false,
                                                         receivedNs: out.receivedNs, displayNs: displayNs,
                                                         decodeUs: decodeUs))
        lock.lock()
        if out.header.tCameraNs > 0 {
            cameraToPhotonMs += 0.1 * (Double(displayNs - out.header.tCameraNs) * 1e-6 - cameraToPhotonMs)
        }
        targetToPhotonMs += 0.1 * (Double(displayNs - out.header.tTargetNs) * 1e-6 - targetToPhotonMs)
        let now = CACurrentMediaTime()
        if now - windowStart >= 1 {
            fps = Double(framesWindow) / (now - windowStart)
            framesWindow = 0
            windowStart = now
        }
        lock.unlock()
    }

    func statsText() -> String {
        lock.lock(); defer { lock.unlock() }
        var s = String(format: "ПК → экран: %.0f fps", fps)
        if cameraToPhotonMs > 0 && !localCamera { s += String(format: ", камера→экран %.0f мс", cameraToPhotonMs) }
        s += String(format: ", поза→экран %+.0f мс", targetToPhotonMs)
        return s
    }

    /// Родное разрешение экрана в ландшафте (ширина > высоты)
    static func landscapeNativeSize() -> CGSize {
        let b = UIScreen.main.nativeBounds.size
        return CGSize(width: max(b.width, b.height), height: min(b.width, b.height))
    }
}
