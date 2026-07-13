// Layer 2 — Rendering: procedural deep-space backdrop.
// Draws a seeded full-screen nebula / dust / vignette pass before the starfield.
import Metal
import simd

/// Seed-derived "sky personality." Drives the background shader and is also
/// consumed by StarfieldRenderer so the star distribution lines up with the
/// galactic band and overall composition.
struct SkyParams {
    var bandAngle:    Float   // -π..π, in q-space (aspect-corrected NDC)
    var bandWidth:    Float   // 0.45..1.20
    var bandStrength: Float   // 0..1, biased low (most skies have a faint band)
    var nebulaCount:  Int32   // 2..7
    var shapeStyle:   Int32   // 0..2 (billowy / filamentary / pillars)
    var galaxyCount:  Int32   // 0..3 distant smudges
    var paletteShift: Int32   // 0..7 — rotates the per-nebula color palette
    var dustAmount:   Float   // 0.40..1.10 — strength of dust-lane occlusion
    var grainAmount:  Float   // 0.55..1.30 — strength of stardust grains
    var overallTint:  Float   // 0..1 — global hue bias of empty space
    var clusterCount: Int32   // 0..3 — local star clusters in the starfield
    var starDensity:  Float   // 0.5..1.4 — multiplier on starfield count

    static func from(seed: Seed) -> SkyParams {
        // Distinct mix-in so this RNG stream doesn't collide with body-RNG seeds
        // or the starfield's existing RNG stream.
        var rng = SeededRandom(state: seed.value &+ 0x53A1_FE17_C0DE_B0B5)

        let bandAngle    = rng.float(in: -Float.pi ... Float.pi)
        let bandStrength = pow(rng.float(), 1.4)        // most skies have a quiet band
        let bandWidth    = 0.45 + rng.float() * 0.75

        // Nebula count: most skies 2-5, occasional rare 6-7 nebula-rich sky.
        let nebRoll = rng.float()
        let nebulaCount: Int32
        if nebRoll < 0.50 {
            nebulaCount = Int32(2 + Int(rng.float() * 2))   // 2..3
        } else if nebRoll < 0.92 {
            nebulaCount = Int32(4 + Int(rng.float() * 2))   // 4..5
        } else {
            nebulaCount = Int32(6 + Int(rng.float() * 2))   // 6..7
        }

        let shapeStyle   = Int32(rng.float() * 3.0)
        let galaxyCount  = Int32(rng.float() * 4.0)
        let paletteShift = Int32(rng.float() * 8.0)
        let dustAmount   = 0.40 + rng.float() * 0.70
        let grainAmount  = 0.55 + rng.float() * 0.75
        let overallTint  = rng.float()
        let clusterCount = Int32(rng.float() * 4.0)
        let starDensity  = 0.5 + rng.float() * 0.9

        return SkyParams(
            bandAngle:    bandAngle,
            bandWidth:    bandWidth,
            bandStrength: bandStrength,
            nebulaCount:  nebulaCount,
            shapeStyle:   shapeStyle,
            galaxyCount:  galaxyCount,
            paletteShift: paletteShift,
            dustAmount:   dustAmount,
            grainAmount:  grainAmount,
            overallTint:  overallTint,
            clusterCount: clusterCount,
            starDensity:  starDensity)
    }
}

/// Mirrors `BackgroundUniforms` in starfield.metal. 64-byte struct, 8-byte aligned.
struct BackgroundUniformsCPU {
    var screenSize:   SIMD2<Float>
    var time:         Float
    var seedLo:       Float
    var seedHi:       Float
    var bandAngle:    Float
    var bandWidth:    Float
    var bandStrength: Float
    var nebulaCount:  Float
    var shapeStyle:   Float
    var galaxyCount:  Float
    var paletteShift: Float
    var dustAmount:   Float
    var grainAmount:  Float
    var overallTint:  Float
    var _pad:         Float = 0
}

@MainActor
final class BackgroundRenderer {

    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let copyPipeline: MTLRenderPipelineState

    private var cachedSeed: UInt64? = nil
    private var cachedParams = SkyParams(
        bandAngle: 0, bandWidth: 0.6, bandStrength: 0.4,
        nebulaCount: 4, shapeStyle: 0, galaxyCount: 1, paletteShift: 0,
        dustAmount: 0.7, grainAmount: 0.8, overallTint: 0.5,
        clusterCount: 1, starDensity: 1.0)
    private var cachedTexture: MTLTexture?
    private var cachedTextureKey: UInt64 = 0
    private var cachedSize: SIMD2<Int32> = .zero

    init(device: MTLDevice, library: MTLLibrary,
         sampleCount: Int, depthFormat: MTLPixelFormat) throws {
        self.device = device

        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction              = library.makeFunction(name: "backgroundVertex")
        d.fragmentFunction            = library.makeFunction(name: "backgroundFragment")
        d.rasterSampleCount           = 1
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        d.colorAttachments[0].isBlendingEnabled = false
        pipeline = try device.makeRenderPipelineState(descriptor: d)

        let c = MTLRenderPipelineDescriptor()
        c.vertexFunction = library.makeFunction(name: "backgroundTextureVertex")
        c.fragmentFunction = library.makeFunction(name: "backgroundTextureFragment")
        c.rasterSampleCount = sampleCount
        c.depthAttachmentPixelFormat = depthFormat
        c.colorAttachments[0].pixelFormat = .bgra8Unorm
        c.colorAttachments[0].isBlendingEnabled = false
        copyPipeline = try device.makeRenderPipelineState(descriptor: c)
    }

    /// Returns the cached SkyParams for `seed`, deriving them on first call.
    func params(for seed: Seed) -> SkyParams {
        if cachedSeed == seed.value { return cachedParams }
        cachedParams = SkyParams.from(seed: seed)
        cachedSeed   = seed.value
        return cachedParams
    }

    func updateCacheIfNeeded(commandBuffer: MTLCommandBuffer,
                             screenSize: SIMD2<Float>,
                             time: Float,
                             seed: Seed) {
        let width = max(1, Int(screenSize.x.rounded(.up)))
        let height = max(1, Int(screenSize.y.rounded(.up)))
        let sizeKey = SIMD2<Int32>(Int32(width), Int32(height))
        let key = seed.value
        guard cachedTexture == nil || cachedTextureKey != key || cachedSize != sizeKey else { return }

        cachedTextureKey = key
        cachedSize = sizeKey

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        cachedTexture = device.makeTexture(descriptor: desc)
        guard let tex = cachedTexture else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = tex
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.01, green: 0.01, blue: 0.04, alpha: 1)

        let p = params(for: seed)
        var u = BackgroundUniformsCPU(
            screenSize:   screenSize,
            time:         time,
            seedLo:       Float(seed.value & 0xFFFF_FFFF),
            seedHi:       Float((seed.value >> 32) & 0xFFFF_FFFF),
            bandAngle:    p.bandAngle,
            bandWidth:    p.bandWidth,
            bandStrength: p.bandStrength,
            nebulaCount:  Float(p.nebulaCount),
            shapeStyle:   Float(p.shapeStyle),
            galaxyCount:  Float(p.galaxyCount),
            paletteShift: Float(p.paletteShift),
            dustAmount:   p.dustAmount,
            grainAmount:  p.grainAmount,
            overallTint:  p.overallTint)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setCullMode(.none)
        encoder.setVertexBytes(&u, length: MemoryLayout<BackgroundUniformsCPU>.stride, index: 0)
        encoder.setFragmentBytes(&u, length: MemoryLayout<BackgroundUniformsCPU>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    func draw(in encoder: MTLRenderCommandEncoder) {
        guard let tex = cachedTexture else { return }
        encoder.setRenderPipelineState(copyPipeline)
        encoder.setCullMode(.none)
        encoder.setFragmentTexture(tex, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
}
