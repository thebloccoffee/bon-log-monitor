import Foundation
import Metal
import MonitorCore

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print((ok ? "PASS " : "FAIL ") + name + (ok ? "" : "  — " + detail()))
    if !ok { failures += 1 }
}
func near(_ a: Double, _ b: Double, _ tol: Double) -> Bool { abs(a - b) <= tol }

// Sony's published anchor: S-Log3 18% grey = 10-bit code 420 = 40.6 IRE.
let greyIre = (420.0 - 64.0) / 876.0
check("S-Log3 code 420 decodes to 0.18", near(ColorMath.slog3ToLinear(greyIre), 0.18, 1e-9),
      "\(ColorMath.slog3ToLinear(greyIre))")
// Sony's published anchor: S-Log2 18% grey = 10-bit code 347.
let slog2Grey = (347.0 - 64.0) / 876.0
check("S-Log2 code 347 decodes to ~0.18", near(ColorMath.slog2ToLinear(slog2Grey), 0.18, 0.003),
      "\(ColorMath.slog2ToLinear(slog2Grey))")

// Encode/decode round trip across the toe/log knee and up to +6 stops.
let roundTripOk = stride(from: -8.0, through: 6.0, by: 0.25).allSatisfy { stops in
    let lin = 0.18 * pow(2, stops)
    return near(ColorMath.slog3ToLinear(ColorMath.linearToSlog3(lin)), lin, lin * 1e-9 + 1e-12)
}
check("S-Log3 encode/decode round trip", roundTripOk)

// Method check: deriving Rec.709 RGB->XYZ must reproduce the canonical luma row.
let y709 = ColorMath.rgbToXyz(ColorMath.rec709Primaries)[1]
check("Rec.709 luma row = 0.2126/0.7152/0.0722",
      zip(y709, [0.2126, 0.7152, 0.0722]).allSatisfy { near($0, $1, 1e-4) }, "\(y709)")

for p in LogProfile.allCases {
    let m = ColorMath.matrix(for: p)
    check("\(p.rawValue) matrix preserves neutral", m.allSatisfy { near($0.reduce(0, +), 1, 1e-6) }, "\(m)")
}

// End to end: an S-Log3 grey chip should read 40.9 IRE in the 709 view.
let grey709 = ColorMath.luma(ColorMath.logToRec709([greyIre, greyIre, greyIre], profile: .slog3SGamut3Cine))
check("S-Log3 grey chip -> 40.9 IRE in Rec.709", near(grey709, 0.409, 0.002), "\(grey709)")
check("grey chip lands in the green false-color band",
      Exposure.falseColor(ire: grey709, skinLo: Exposure.defaultSkinLo, skinHi: Exposure.defaultSkinHi)! == (0.20, 0.80, 0.20))
// One stop over grey (typical light skin) must land in the default salmon band.
let skinIre = ColorMath.linearToSlog3(0.36)
let skin709 = ColorMath.luma(ColorMath.logToRec709([skinIre, skinIre, skinIre], profile: .slog3SGamut3Cine))
check("+1 stop lands in the salmon skin band", skin709 >= Exposure.defaultSkinLo && skin709 < Exposure.defaultSkinHi, "\(skin709)")

// GPU vs CPU: render known log pixels through the real shader and compare.
func gpuCheck() {
    guard let device = MTLCreateSystemDefaultDevice() else { check("Metal device", false, "none"); return }
    let library: MTLLibrary
    do { library = try device.makeLibrary(source: ShaderSource.build(), options: nil) }
    catch { check("shader compiles", false, "\(error)"); return }
    check("shader compiles", true)

    // Coloured chips so a transposed gamut matrix shows up (neutral chips can't catch it).
    let chips: [[Double]] = [
        [greyIre, greyIre, greyIre],
        [0.62, 0.48, 0.40],   // skin-ish log values
        [0.30, 0.55, 0.35],   // greenish
        [0.70, 0.70, 0.70],   // bright
    ]
    let w = chips.count
    let inDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: w, height: 1, mipmapped: false)
    inDesc.usage = .shaderRead
    let input = device.makeTexture(descriptor: inDesc)!
    var px: [Float] = chips.flatMap { chip in chip.map { Float($0) } + [1] }
    input.replace(region: MTLRegionMake2D(0, 0, w, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: w * 16)

    let outDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: w, height: 1, mipmapped: false)
    outDesc.usage = [.renderTarget, .shaderRead]
    outDesc.storageMode = .shared
    let output = device.makeTexture(descriptor: outDesc)!

    let pd = MTLRenderPipelineDescriptor()
    pd.vertexFunction = library.makeFunction(name: "monitorVertex")
    pd.fragmentFunction = library.makeFunction(name: "monitorFragment")
    pd.colorAttachments[0].pixelFormat = .rgba32Float
    let pipeline = try! device.makeRenderPipelineState(descriptor: pd)

    let rp = MTLRenderPassDescriptor()
    rp.colorAttachments[0].texture = output
    rp.colorAttachments[0].loadAction = .clear
    rp.colorAttachments[0].storeAction = .store
    let queue = device.makeCommandQueue()!
    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeRenderCommandEncoder(descriptor: rp)!
    var u = MonitorUniforms()
    u.profile = Float(LogProfile.slog3SGamut3Cine.shaderIndex)
    enc.setRenderPipelineState(pipeline)
    enc.setVertexBytes(&u, length: MemoryLayout<MonitorUniforms>.stride, index: 0)
    enc.setFragmentBytes(&u, length: MemoryLayout<MonitorUniforms>.stride, index: 0)
    enc.setFragmentTexture(input, index: 0)
    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    enc.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()

    var out = [Float](repeating: 0, count: w * 4)
    output.getBytes(&out, bytesPerRow: w * 16, from: MTLRegionMake2D(0, 0, w, 1), mipmapLevel: 0)
    for (i, chip) in chips.enumerated() {
        let cpu = ColorMath.logToRec709(chip, profile: .slog3SGamut3Cine)
        let gpu = (0..<3).map { Double(out[i * 4 + $0]) }
        check("GPU == CPU for chip \(i)", zip(cpu, gpu).allSatisfy { near($0, $1, 1.0 / 512) },
              "cpu \(cpu.map { String(format: "%.4f", $0) }) gpu \(gpu.map { String(format: "%.4f", $0) })")
    }
}
gpuCheck()

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
exit(failures == 0 ? 0 : 1)
