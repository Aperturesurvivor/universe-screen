// Layer 2 — Rendering: the Trash → Black Hole.
//   horizon — opaque sphere (depth read+write), solid black with a faint rim.
//             Occludes the starfield/background like any 3D body.
//   glow    — additive billboard: photon ring + soft outer halo. Depth-test
//             on, depth-write off so planets in front overdraw it correctly.
import Metal
import simd

@MainActor
final class BlackHoleRenderer {

    private let device: MTLDevice
    private let mesh:   SphereMesh

    private let horizonPipeline: MTLRenderPipelineState
    private let glowPipeline:    MTLRenderPipelineState
    private let horizonDepth:    MTLDepthStencilState
    private let glowDepth:       MTLDepthStencilState

    private(set) var hasBlackHole: Bool = false
    private var current: BlackHoleGPU = BlackHoleGPU(
        position:  .zero,
        radius:    0,
        intensity: 0)

    init(device: MTLDevice, library: MTLLibrary, mesh: SphereMesh,
         sampleCount: Int, depthFormat: MTLPixelFormat) throws {
        self.device = device
        self.mesh   = SphereMesh.make(device: device, latSegments: 48, lonSegments: 64)

        // Horizon — opaque, depth read+write
        let h = MTLRenderPipelineDescriptor()
        h.vertexFunction              = library.makeFunction(name: "blackHoleHorizonVertex")
        h.fragmentFunction            = library.makeFunction(name: "blackHoleHorizonFragment")
        h.rasterSampleCount           = sampleCount
        h.depthAttachmentPixelFormat  = depthFormat
        h.colorAttachments[0].pixelFormat = .bgra8Unorm
        horizonPipeline = try device.makeRenderPipelineState(descriptor: h)

        // Glow — additive
        let g = MTLRenderPipelineDescriptor()
        g.vertexFunction              = library.makeFunction(name: "blackHoleGlowVertex")
        g.fragmentFunction            = library.makeFunction(name: "blackHoleGlowFragment")
        g.rasterSampleCount           = sampleCount
        g.depthAttachmentPixelFormat  = depthFormat
        let ca = g.colorAttachments[0]!
        ca.pixelFormat                 = .bgra8Unorm
        ca.isBlendingEnabled           = true
        ca.rgbBlendOperation           = .add
        ca.alphaBlendOperation         = .add
        ca.sourceRGBBlendFactor        = .one
        ca.destinationRGBBlendFactor   = .one
        ca.sourceAlphaBlendFactor      = .one
        ca.destinationAlphaBlendFactor = .one
        glowPipeline = try device.makeRenderPipelineState(descriptor: g)

        let dsHorizon = MTLDepthStencilDescriptor()
        dsHorizon.depthCompareFunction = .less
        dsHorizon.isDepthWriteEnabled  = true
        horizonDepth = device.makeDepthStencilState(descriptor: dsHorizon)!

        let dsGlow = MTLDepthStencilDescriptor()
        dsGlow.depthCompareFunction = .lessEqual
        dsGlow.isDepthWriteEnabled  = false
        glowDepth = device.makeDepthStencilState(descriptor: dsGlow)!
    }

    func update(blackHole: BlackHoleBody?) {
        if let b = blackHole { current = b.gpu; hasBlackHole = true }
        else                 { hasBlackHole = false }
    }

    func draw(in encoder: MTLRenderCommandEncoder,
              camera: inout CameraUniforms,
              labelUniforms: inout LabelUniforms,
              motion: inout MotionUniforms) {
        guard hasBlackHole else { return }

        var bh = current

        // ---- Pass 1: event horizon sphere ----
        encoder.setRenderPipelineState(horizonPipeline)
        encoder.setDepthStencilState(horizonDepth)
        encoder.setCullMode(.back)
        encoder.setFrontFacing(.counterClockwise)

        encoder.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&bh,     length: MemoryLayout<BlackHoleGPU>.size,   index: 1)
        encoder.setVertexBytes(&camera, length: MemoryLayout<CameraUniforms>.size, index: 2)
        encoder.setFragmentBytes(&bh,     length: MemoryLayout<BlackHoleGPU>.size,   index: 1)
        encoder.setFragmentBytes(&camera, length: MemoryLayout<CameraUniforms>.size, index: 2)

        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: mesh.indexCount,
            indexType: .uint32,
            indexBuffer: mesh.indexBuffer,
            indexBufferOffset: 0)

        // ---- Pass 2: additive glow billboard ----
        encoder.setRenderPipelineState(glowPipeline)
        encoder.setDepthStencilState(glowDepth)
        encoder.setCullMode(.none)

        encoder.setVertexBytes(&bh,            length: MemoryLayout<BlackHoleGPU>.size,   index: 1)
        encoder.setVertexBytes(&camera,        length: MemoryLayout<CameraUniforms>.size, index: 2)
        encoder.setVertexBytes(&labelUniforms, length: MemoryLayout<LabelUniforms>.size,  index: 3)
        encoder.setFragmentBytes(&bh,     length: MemoryLayout<BlackHoleGPU>.size,   index: 1)
        encoder.setFragmentBytes(&motion, length: MemoryLayout<MotionUniforms>.size, index: 3)

        encoder.drawPrimitives(type: .triangleStrip,
                               vertexStart: 0,
                               vertexCount: 4,
                               instanceCount: 1)
    }
}
