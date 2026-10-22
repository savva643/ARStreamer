import SwiftUI
import MetalKit
import CoreVideo
import simd

/// Экран «картинка лаунчера с ПК» (моно / стерео / стерео + линзы). Metal, частота экрана (ProMotion — 120 Гц).
struct ReturnDisplayView: UIViewRepresentable {
    final class Coordinator {
        var renderer: ReturnRenderer?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = UIScreen.main.maximumFramesPerSecond
        view.contentScaleFactor = UIScreen.main.nativeScale
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.backgroundColor = .black
        // Меньше кадров в очереди — меньше задержка (работа GPU тут — один проход)
        (view.layer as? CAMetalLayer)?.maximumDrawableCount = 2
        if let renderer = ReturnRenderer(view: view) {
            view.delegate = renderer
            context.coordinator.renderer = renderer
        } else {
            logToFile("❌ Metal недоступен — экран ПК не работает")
        }
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        uiView.isPaused = true
        uiView.delegate = nil
        coordinator.renderer = nil
    }
}

/// Должна совпадать с ReturnUniforms в ReturnDisplay.metal
struct ReturnUniforms {
    var toRendered = matrix_identity_float4x4
    var toCamera = matrix_identity_float4x4
    var rendered = SIMD4<Float>(1, 1, 1, 0)
    var display = SIMD4<Float>(1, 1, 1, 0)
    var camK = SIMD4<Float>(0, 0, 0, 0)
    var lens = SIMD4<Float>(0, 0, 0, 1)
    var lensGeom = SIMD4<Float>(1, 1, 1, 1)
    var viewport = SIMD4<Float>(0, 1, 1, 1)
    var color = SIMD4<Float>(1, 1, 1, 1)
}

final class ReturnRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var cache: CVMetalTextureCache?
    private let dummyY: MTLTexture
    private let dummyUV: MTLTexture

    private var settings = ReturnDisplaySettings.load()
    private var settingsLoadedAt = CACurrentMediaTime()

    // Время от начала отрисовки до фотонов (по presentedTime), для доворота «на момент показа»
    private let timingLock = NSLock()
    private var presentLatencyNs: Double = 12_000_000
    private var lastAckedFrame: UInt32 = 0

    init?(view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vfn = library.makeFunction(name: "returnVertex"),
              let ffn = library.makeFunction(name: "returnFragment") else { return nil }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        var textureCache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        self.cache = textureCache

        func dummy(_ format: MTLPixelFormat, _ bytes: [UInt8]) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: 1, height: 1, mipmapped: false)
            d.usage = .shaderRead
            guard let t = device.makeTexture(descriptor: d) else { return nil }
            bytes.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: base, bytesPerRow: bytes.count)
                }
            }
            return t
        }
        guard let y = dummy(.r8Unorm, [0]), let uv = dummy(.rg8Unorm, [128, 128]) else { return nil }
        dummyY = y
        dummyUV = uv
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer(),
              let cache = cache else { return }

        let now = CACurrentMediaTime()
        if now - settingsLoadedAt > 0.5 {
            settings = ReturnDisplaySettings.load()
            settingsLoadedAt = now
        }
        let display = ReturnDisplay.shared
        let mode = display.currentMode
        let frame = display.latestFrame()
        let camera = settings.localCamera ? display.cameraFrame() : nil

        timingLock.lock()
        let latency = presentLatencyNs
        timingLock.unlock()
        let drawStartNs = hostTimeNs()
        let tDisplay = drawStartNs + Int64(latency)

        let size = view.drawableSize
        var u = ReturnUniforms()
        u.viewport = SIMD4(Float(settings.lensOffsetYMm), Float(size.width), Float(size.height), 1)

        // Оси экрана относительно устройства — по ориентации интерфейса
        let interface = view.window?.windowScene?.interfaceOrientation ?? .landscapeRight
        let deviceFromScreen = ReturnRenderer.deviceFromScreen(interface)
        let qNow = display.gyro.orientation(at: tDisplay)

        var keep: [CVMetalTexture] = []
        var texY: MTLTexture = dummyY, texUV: MTLTexture = dummyUV
        var camY: MTLTexture = dummyY, camUV: MTLTexture = dummyUV

        if let f = frame, mode != .off,
           let y = makeTexture(cache, f.pixelBuffer, plane: 0, format: .r8Unorm),
           let uv = makeTexture(cache, f.pixelBuffer, plane: 1, format: .rg8Unorm) {
            let h = f.header
            texY = y.0; texUV = uv.0
            keep.append(y.1); keep.append(uv.1)

            // M = P⁻¹·A: луч устройства «сейчас» -> оси устройства, под которые ПК нарисовал кадр
            var m = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
            if settings.timewarp, h.tRefNs != 0, let qn = qNow, let qRef = display.gyro.orientation(at: h.tRefNs) {
                let a = qRef.inverse * qn
                m = h.predFromRef.inverse * a
            }
            u.toRendered = ReturnRenderer.matrix(h.eyeFromDevice * m * deviceFromScreen)
            u.rendered = SIMD4(h.tanX, h.tanY, h.layout == 2 ? 2 : 1, h.alpha ? 1 : 0)
            u.color.x = h.fullRange ? 1 : 0
            u.color.y = h.bt709 ? 1 : 0

            // Поле зрения показа: отрендеренное без запаса под доворот, в пропорциях глаза на экране
            let eyeW = mode == .mono ? Double(size.width) : Double(size.width) / 2
            let va = eyeW / max(1, Double(size.height))
            var tx = Double(h.tanX / h.overscan), ty = Double(h.tanY / h.overscan)
            tx = min(tx, ty * va)
            ty = tx / va
            u.display = SIMD4(Float(tx), Float(ty), Float(mode.rawValue), 1)
        } else {
            u.display = SIMD4(1, 1, Float(max(1, mode.rawValue)), 0)
        }

        if mode == .stereoLens {
            let lens = LensModel(settings: settings, screenPixels: ReturnDisplay.landscapeNativeSize())
            u.lens = SIMD4(Float(settings.k1), Float(settings.k2), Float(settings.chroma), Float(lens.maxTan))
            u.lensGeom = SIMD4(Float(lens.screenWmm), Float(lens.screenHmm), Float(settings.interLensMm), Float(lens.screenToLensMm))
        }

        // Фон — своя камера: луч -> камера на момент её кадра (доворот по гироскопу)
        if let c = camera,
           let y = makeTexture(cache, c.pixelBuffer, plane: 0, format: .r8Unorm),
           let uv = makeTexture(cache, c.pixelBuffer, plane: 1, format: .rg8Unorm),
           let h = frame?.header {
            camY = y.0; camUV = uv.0
            keep.append(y.1); keep.append(uv.1)
            var cm = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
            if settings.timewarp, let qn = qNow, let qCam = display.gyro.orientation(at: c.ptsNs) {
                cm = qCam.inverse * qn
            }
            u.toCamera = ReturnRenderer.matrix(h.cameraFromDevice * cm * deviceFromScreen)
            let w = Float(CVPixelBufferGetWidth(c.pixelBuffer)), hh = Float(CVPixelBufferGetHeight(c.pixelBuffer))
            u.camK = SIMD4(c.fx / w, c.fy / hh, c.cx / w, c.cy / hh)
            u.color.z = c.fullRange ? 1 : 0
            u.color.w = c.bt709 ? 1 : 0
        }

        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<ReturnUniforms>.stride, index: 0)
        enc.setFragmentTexture(texY, index: 0)
        enc.setFragmentTexture(texUV, index: 1)
        enc.setFragmentTexture(camY, index: 2)
        enc.setFragmentTexture(camUV, index: 3)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()

        let shown = frame
        drawable.addPresentedHandler { [weak self] d in
            guard let self = self, d.presentedTime > 0 else { return }
            let presentedNs = Int64(d.presentedTime * 1_000_000_000)
            self.timingLock.lock()
            // Сколько реально прошло от начала отрисовки до показа (сглажено)
            let measured = Double(presentedNs - drawStartNs)
            if measured > 0 && measured < 100_000_000 {
                self.presentLatencyNs += 0.1 * (measured - self.presentLatencyNs)
            }
            var firstShow = false
            if let f = shown, f.header.frameId != self.lastAckedFrame {
                self.lastAckedFrame = f.header.frameId
                firstShow = true
            }
            self.timingLock.unlock()
            if firstShow, let f = shown { ReturnDisplay.shared.framePresented(f, displayNs: presentedNs) }
        }
        cmd.present(drawable)
        cmd.addCompletedHandler { _ in _ = keep }   // текстуры живут, пока GPU их читает
        cmd.commit()
    }

    private func makeTexture(_ cache: CVMetalTextureCache, _ pb: CVPixelBuffer, plane: Int,
                             format: MTLPixelFormat) -> (MTLTexture, CVMetalTexture)? {
        guard CVPixelBufferGetPlaneCount(pb) > plane else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(pb, plane)
        let h = CVPixelBufferGetHeightOfPlane(pb, plane)
        var tex: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, format, w, h, plane, &tex) == kCVReturnSuccess,
              let t = tex, let mt = CVMetalTextureGetTexture(t) else { return nil }
        return (mt, t)
    }

    /// Поворот «оси экрана -> оси устройства»: landscapeRight (кнопка/Dynamic Island справа, верх телефона слева) — -90° вокруг z
    static func deviceFromScreen(_ o: UIInterfaceOrientation) -> simd_quatd {
        let roll: Double
        switch o {
        case .landscapeRight: roll = 0
        case .portrait: roll = 90
        case .landscapeLeft: roll = 180
        case .portraitUpsideDown: roll = 270
        default: roll = 0
        }
        return simd_quatd(angle: (roll - 90) * .pi / 180, axis: SIMD3<Double>(0, 0, 1))
    }

    static func matrix(_ q: simd_quatd) -> simd_float4x4 {
        let n = simd_normalize(q)
        let f = simd_quatf(ix: Float(n.imag.x), iy: Float(n.imag.y), iz: Float(n.imag.z), r: Float(n.real))
        return simd_float4x4(f)
    }
}
