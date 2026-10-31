import CoreVideo
import ImageIO
import MetalKit
import MonitorCore
import SwiftUI

/// Draws the latest camera frame through the log -> 709 / zebra / false-color shader.
final class MonitorRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let loader: MTKTextureLoader
    private var textureCache: CVMetalTextureCache?
    private var lastImage: CGImage?
    private var lastImageTexture: MTLTexture?
    private let startTime = CACurrentMediaTime()

    var model: MonitorModel?

    init?(view: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        loader = MTKTextureLoader(device: device)
        do {
            let library = try device.makeLibrary(source: ShaderSource.build(), options: nil)
            let pd = MTLRenderPipelineDescriptor()
            pd.vertexFunction = library.makeFunction(name: "monitorVertex")
            pd.fragmentFunction = library.makeFunction(name: "monitorFragment")
            pd.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: pd)
        } catch {
            NSLog("Monitor shader failed: \(error)")
            return nil
        }
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        super.init()
        view.device = device
        // Raw values straight to the display, like a monitor: no sRGB decode or
        // colour matching, so the shader's 709 output is what you see.
        view.colorPixelFormat = .bgra8Unorm
        view.colorspace = nil
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.preferredFramesPerSecond = 60
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let model, let rp = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: rp)
        else { return }

        if let frame = model.camera.currentFrame(), let tex = texture(for: frame) {
            var u = model.uniforms()
            u.time = Float(CACurrentMediaTime() - startTime)
            // Aspect fit inside the drawable.
            let viewAspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
            let texAspect = Float(tex.width) / Float(max(tex.height, 1))
            model.frameAspect = Double(texAspect)
            u.fitScale = texAspect > viewAspect ? SIMD2(1, viewAspect / texAspect) : SIMD2(texAspect / viewAspect, 1)
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBytes(&u, length: MemoryLayout<MonitorUniforms>.stride, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<MonitorUniforms>.stride, index: 0)
            enc.setFragmentTexture(tex, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
            renderForPhone(cb: cb, source: tex, uniforms: u, hub: model.phone.hub)
        } else {
            enc.endEncoding()
        }
        cb.present(drawable)
        cb.commit()
    }

    // MARK: Phone view

    private static let phoneInterval: CFTimeInterval = 1.0 / 15
    private var lastPhoneFrame: CFTimeInterval = 0
    private var phoneTarget: MTLTexture?
    /// One encode in flight at a time; if the CPU falls behind, skip frames.
    private var phoneEncoding = false
    private let phoneQueue = DispatchQueue(label: "sonylogmonitor.phone.encode")

    /// Same shader pass at the camera's own resolution (no letterbox), read back and
    /// JPEG-encoded for the phones watching /stream.
    private func renderForPhone(cb: MTLCommandBuffer, source: MTLTexture, uniforms: MonitorUniforms, hub: PhoneFrameHub) {
        let now = CACurrentMediaTime()
        guard device.hasUnifiedMemory, hub.hasClients, !phoneEncoding, now - lastPhoneFrame >= Self.phoneInterval
        else { return }
        lastPhoneFrame = now

        let w = min(source.width, 1280)
        let h = max(1, source.height * w / max(source.width, 1))
        if phoneTarget?.width != w || phoneTarget?.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget]
            d.storageMode = .shared
            phoneTarget = device.makeTexture(descriptor: d)
        }
        guard let target = phoneTarget else { return }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        var u = uniforms
        u.fitScale = SIMD2(1, 1)
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&u, length: MemoryLayout<MonitorUniforms>.stride, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<MonitorUniforms>.stride, index: 0)
        enc.setFragmentTexture(source, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()

        phoneEncoding = true
        cb.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            target.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            self.phoneQueue.async {
                if let jpeg = Self.jpeg(bgra: bytes, width: w, height: h) { hub.publish(jpeg: jpeg) }
                DispatchQueue.main.async { self.phoneEncoding = false }
            }
        }
    }

    private static func jpeg(bgra: [UInt8], width: Int, height: Int) -> Data? {
        guard let provider = CGDataProvider(data: Data(bgra) as CFData),
              let img = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    private func texture(for frame: Frame) -> MTLTexture? {
        switch frame {
        case .pixelBuffer(let buf):
            guard let cache = textureCache else { return nil }
            var cvTex: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(
                nil, cache, buf, nil, .bgra8Unorm,
                CVPixelBufferGetWidth(buf), CVPixelBufferGetHeight(buf), 0, &cvTex
            )
            return cvTex.flatMap(CVMetalTextureGetTexture)
        case .image(let img):
            if img === lastImage, let lastImageTexture { return lastImageTexture }
            // SRGB: false keeps the raw code values; an sRGB texture would linearize them.
            let tex = try? loader.newTexture(cgImage: img, options: [
                .SRGB: false, .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            ])
            lastImage = img
            lastImageTexture = tex
            return tex
        }
    }
}

struct MonitorView: NSViewRepresentable {
    @ObservedObject var model: MonitorModel

    final class Coordinator { var renderer: MonitorRenderer? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        let renderer = MonitorRenderer(view: view)
        renderer?.model = model
        view.delegate = renderer
        context.coordinator.renderer = renderer
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.renderer?.model = model
    }
}
