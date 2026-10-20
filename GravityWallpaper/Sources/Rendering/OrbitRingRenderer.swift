// Renders faint circular orbit rings — one per planet — as instanced line strips.
import Metal
import simd

/// 32-byte GPU layout matching `OrbitRingGPU` in orbit_ring.metal.
struct OrbitRingGPU {
    var center: SIMD4<Float>
    var radius: Float
    var alpha:  Float
    var _pad0:  Float = 0
    var _pad1:  Float = 0
}

@MainActor
final class OrbitRingRenderer {

    static let segCount = 96

    private let device:     MTLDevice
    private let pipeline:   MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private var ringBuffer: MTLBuffer?
    private(set) var ringCount: Int = 0

    init(device: MTLDevice, library: MTLLibrary,
         sampleCount: Int, depthFormat: MTLPixelFormat) throws {
        self.device = device

        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction             = library.makeFunction(name: "orbitRingVertex")
        d.fragmentFunction           = library.makeFunction(name: "orbitRingFragment")
        d.rasterSampleCount          = sampleCount
        d.depthAttachmentPixelFormat = depthFormat
        let ca = d.colorAttachments[0]!
        ca.pixelFormat                 = .bgra8Unorm
        ca.isBlendingEnabled           = true
        ca.rgbBlendOperation           = .add
        ca.alphaBlendOperation         = .add
        ca.sourceRGBBlendFactor        = .sourceAlpha
        ca.destinationRGBBlendFactor   = .oneMinusSourceAlpha
        ca.sourceAlphaBlendFactor      = .one
        ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: d)

        let ds = MTLDepthStencilDescriptor()
        ds.depthCompareFunction = .always
        ds.isDepthWriteEnabled  = false
        depthState = device.makeDepthStencilState(descriptor: ds)!
    }

    /// One ring per occupied shell. Pass `universe.shellRadii` — already deduplicated.
    func update(ringRadii: [Float], starCenter: SIMD3<Float>) {
        ringCount = ringRadii.count
        guard !ringRadii.isEmpty else { return }
        let stride = MemoryLayout<OrbitRingGPU>.stride
        let need   = ringRadii.count * stride
        if ringBuffer == nil || ringBuffer!.length < need {
            ringBuffer = device.makeBuffer(length: need, options: .storageModeShared)
        }
        guard let buf = ringBuffer else { return }
        let ptr = buf.contents().bindMemory(to: OrbitRingGPU.self, capacity: ringRadii.count)
        let c4  = SIMD4(starCenter, 0)
        for i in 0..<ringRadii.count {
            ptr[i] = OrbitRingGPU(center: c4, radius: ringRadii[i], alpha: 0.11)
        }
    }

    func draw(in encoder: MTLRenderCommandEncoder, camera: inout CameraUniforms) {
        guard ringCount > 0, let buf = ringBuffer else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setVertexBuffer(buf, offset: 0, index: 0)
        encoder.setVertexBytes(&camera, length: MemoryLayout<CameraUniforms>.size, index: 1)
        encoder.drawPrimitives(type: .lineStrip,
                               vertexStart: 0,
                               vertexCount: Self.segCount + 1,
                               instanceCount: ringCount)
    }
}
