// Layer 2 — Rendering: asteroid pipeline. Same sphere mesh, different shader,
// different palette. Drawn after planets so depth keeps everything correct.
import Metal

@MainActor
final class AsteroidRenderer {

    private let device:     MTLDevice
    private let pipeline:   MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let mesh:       SphereMesh

    private var buffer: MTLBuffer?
    private(set) var instanceCount: Int = 0

    init(device: MTLDevice, library: MTLLibrary, mesh: SphereMesh,
         sampleCount: Int, depthFormat: MTLPixelFormat) throws {
        self.device = device
        self.mesh   = mesh

        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction              = library.makeFunction(name: "asteroidVertex")
        d.fragmentFunction            = library.makeFunction(name: "asteroidFragment")
        d.rasterSampleCount           = sampleCount
        d.depthAttachmentPixelFormat  = depthFormat
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: d)

        let ds = MTLDepthStencilDescriptor()
        ds.depthCompareFunction = .less
        ds.isDepthWriteEnabled  = true
        depthState = device.makeDepthStencilState(descriptor: ds)!
    }

    func updateBuffer(asteroids: [AsteroidBody]) {
        instanceCount = asteroids.count
        guard !asteroids.isEmpty else { return }
        let stride = MemoryLayout<AsteroidGPU>.stride
        let need = asteroids.count * stride
        if buffer == nil || buffer!.length < need {
            buffer = device.makeBuffer(length: need, options: .storageModeShared)
        }
        guard let buf = buffer else { return }
        let ptr = buf.contents().bindMemory(to: AsteroidGPU.self, capacity: asteroids.count)
        for i in 0..<asteroids.count { ptr[i] = asteroids[i].gpu }
    }

    func draw(in encoder: MTLRenderCommandEncoder,
              camera: inout CameraUniforms,
              motion: inout MotionUniforms) {
        guard instanceCount > 0, let buf = buffer else { return }

        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.back)
        encoder.setFrontFacing(.counterClockwise)

        encoder.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(buf,               offset: 0, index: 1)
        encoder.setVertexBytes(&camera, length: MemoryLayout<CameraUniforms>.size, index: 2)
        encoder.setVertexBytes(&motion, length: MemoryLayout<MotionUniforms>.size, index: 3)
        encoder.setFragmentBytes(&camera, length: MemoryLayout<CameraUniforms>.size, index: 2)

        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: mesh.indexCount,
            indexType: .uint32,
            indexBuffer: mesh.indexBuffer,
            indexBufferOffset: 0,
            instanceCount: instanceCount)
    }
}
