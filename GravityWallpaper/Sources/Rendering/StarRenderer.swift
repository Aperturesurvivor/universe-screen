// Layer 2 — Rendering: Internet Star.
//   surface  : 3D procedural sphere with granulated, flowing surface
//   halo     : billboarded corona + solar prominences
//   lensFlare: full-screen NDC quad — anamorphic streak + cross rays + bokeh
import Metal
import simd

/// 16-byte stride; matches LensFlareUniforms in star.metal
struct LensFlareUniforms {
    var screenSize: SIMD2<Float>
    var _pad0: Float = 0
    var _pad1: Float = 0
}

@MainActor
final class StarRenderer {

    private let device: MTLDevice
    private let mesh:   SphereMesh

    private let surfacePipeline:  MTLRenderPipelineState
    private let haloPipeline:     MTLRenderPipelineState
    private let flarePipeline:    MTLRenderPipelineState
    private let surfaceDepth:     MTLDepthStencilState
    private let haloDepth:        MTLDepthStencilState
    private let flareDepth:       MTLDepthStencilState

    private(set) var hasStar: Bool = false
    private var current: StarGPU = StarGPU(
        position:    .zero,
        coreColor:   .zero, midColor: .zero, limbColor: .zero, accentColor: .zero,
        radius:      0,
        pulseRate:   0,
        intensity:   0,
        phase:       0,
        temperature: 0.08,
        stability:   0.14,
        coronaScale: 1.0,
        flareDensity: 0.30,
        seed:        0)

    init(device: MTLDevice, library: MTLLibrary, mesh: SphereMesh,
         sampleCount: Int, depthFormat: MTLPixelFormat) throws {
        self.device = device
        // The star gets its own denser sphere so the displaced surface reads as
        // a true 3D body rather than borrowing the coarser planet tessellation.
        self.mesh   = SphereMesh.make(device: device, latSegments: 80, lonSegments: 120)

        // Surface — opaque, depth read+write
        let s = MTLRenderPipelineDescriptor()
        s.vertexFunction              = library.makeFunction(name: "starSurfaceVertex")
        s.fragmentFunction            = library.makeFunction(name: "starSurfaceFragment")
        s.rasterSampleCount           = sampleCount
        s.depthAttachmentPixelFormat  = depthFormat
        s.colorAttachments[0].pixelFormat = .bgra8Unorm
        surfacePipeline = try device.makeRenderPipelineState(descriptor: s)

        // Halo — additive
        haloPipeline = try Self.makeAdditivePipeline(
            device: device, library: library,
            vertex: "starHaloVertex", fragment: "starHaloFragment",
            sampleCount: sampleCount, depthFormat: depthFormat)

        // Lens flare — additive, full-screen NDC
        flarePipeline = try Self.makeAdditivePipeline(
            device: device, library: library,
            vertex: "starLensFlareVertex", fragment: "starLensFlareFragment",
            sampleCount: sampleCount, depthFormat: depthFormat)

        let dsSurface = MTLDepthStencilDescriptor()
        dsSurface.depthCompareFunction = .less
        dsSurface.isDepthWriteEnabled  = true
        surfaceDepth = device.makeDepthStencilState(descriptor: dsSurface)!

        let dsHalo = MTLDepthStencilDescriptor()
        dsHalo.depthCompareFunction = .lessEqual
        dsHalo.isDepthWriteEnabled  = false
        haloDepth = device.makeDepthStencilState(descriptor: dsHalo)!

        // Lens flare ignores depth entirely — it's a screen-space artifact.
        let dsFlare = MTLDepthStencilDescriptor()
        dsFlare.depthCompareFunction = .always
        dsFlare.isDepthWriteEnabled  = false
        flareDepth = device.makeDepthStencilState(descriptor: dsFlare)!
    }

    private static func makeAdditivePipeline(
        device: MTLDevice, library: MTLLibrary,
        vertex: String, fragment: String,
        sampleCount: Int, depthFormat: MTLPixelFormat) throws -> MTLRenderPipelineState {

        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction              = library.makeFunction(name: vertex)
        d.fragmentFunction            = library.makeFunction(name: fragment)
        d.rasterSampleCount           = sampleCount
        d.depthAttachmentPixelFormat  = depthFormat
        let ca = d.colorAttachments[0]!
        ca.pixelFormat                 = .bgra8Unorm
        ca.isBlendingEnabled           = true
        ca.rgbBlendOperation           = .add
        ca.alphaBlendOperation         = .add
        ca.sourceRGBBlendFactor        = .one
        ca.destinationRGBBlendFactor   = .one
        ca.sourceAlphaBlendFactor      = .one
        ca.destinationAlphaBlendFactor = .one
        return try device.makeRenderPipelineState(descriptor: d)
    }

    func update(star: StarBody?) {
        if let s = star { current = s.gpu; hasStar = true }
        else            { hasStar = false }
    }

    /// Surface + corona/prominences. Drawn between the starfield and the planets
    /// so planet bodies in front depth-occlude the star sphere.
    func drawSurfaceAndHalo(in encoder: MTLRenderCommandEncoder,
                            camera: inout CameraUniforms,
                            labelUniforms: inout LabelUniforms,
                            motion: inout MotionUniforms) {
        guard hasStar else { return }

        var star = current

        // ---- Surface (opaque sphere) ----
        encoder.setRenderPipelineState(surfacePipeline)
        encoder.setDepthStencilState(surfaceDepth)
        encoder.setCullMode(.back)
        encoder.setFrontFacing(.counterClockwise)

        encoder.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&star,   length: MemoryLayout<StarGPU>.size,        index: 1)
        encoder.setVertexBytes(&camera, length: MemoryLayout<CameraUniforms>.size, index: 2)
        encoder.setVertexBytes(&motion, length: MemoryLayout<MotionUniforms>.size, index: 3)
        encoder.setFragmentBytes(&star,   length: MemoryLayout<StarGPU>.size,        index: 1)
        encoder.setFragmentBytes(&camera, length: MemoryLayout<CameraUniforms>.size, index: 2)
        encoder.setFragmentBytes(&motion, length: MemoryLayout<MotionUniforms>.size, index: 3)

        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: mesh.indexCount,
            indexType: .uint32,
            indexBuffer: mesh.indexBuffer,
            indexBufferOffset: 0)

        // ---- Halo (corona + prominences) ----
        encoder.setRenderPipelineState(haloPipeline)
        encoder.setDepthStencilState(haloDepth)
        encoder.setCullMode(.none)

        encoder.setVertexBytes(&star,          length: MemoryLayout<StarGPU>.size,        index: 1)
        encoder.setVertexBytes(&camera,        length: MemoryLayout<CameraUniforms>.size, index: 2)
        encoder.setVertexBytes(&labelUniforms, length: MemoryLayout<LabelUniforms>.size,  index: 3)
        encoder.setFragmentBytes(&star,        length: MemoryLayout<StarGPU>.size,        index: 1)
        encoder.setFragmentBytes(&motion,      length: MemoryLayout<MotionUniforms>.size, index: 3)

        encoder.drawPrimitives(type: .triangleStrip,
                               vertexStart: 0,
                               vertexCount: 4,
                               instanceCount: 1)
    }

    /// Cinematic lens flare. Drawn after planets/asteroids but before labels —
    /// labels stay readable while the flare adds atmosphere everywhere else.
    func drawLensFlare(in encoder: MTLRenderCommandEncoder,
                       camera: inout CameraUniforms,
                       motion: inout MotionUniforms,
                       screenSize: SIMD2<Float>) {
        guard hasStar else { return }

        var star = current
        var u    = LensFlareUniforms(screenSize: screenSize)

        encoder.setRenderPipelineState(flarePipeline)
        encoder.setDepthStencilState(flareDepth)
        encoder.setCullMode(.none)

        encoder.setVertexBytes(&star,   length: MemoryLayout<StarGPU>.size,        index: 1)
        encoder.setVertexBytes(&camera, length: MemoryLayout<CameraUniforms>.size, index: 2)
        encoder.setFragmentBytes(&star,   length: MemoryLayout<StarGPU>.size,           index: 1)
        encoder.setFragmentBytes(&motion, length: MemoryLayout<MotionUniforms>.size,    index: 3)
        encoder.setFragmentBytes(&u,      length: MemoryLayout<LensFlareUniforms>.size, index: 4)

        encoder.drawPrimitives(type: .triangleStrip,
                               vertexStart: 0,
                               vertexCount: 4,
                               instanceCount: 1)
    }
}
