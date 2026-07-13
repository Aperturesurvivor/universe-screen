// Layer 2 — Rendering: planet pipeline. Owns the planet instance buffer
// and the procedural-surface render pipeline state.
import Metal
import simd

@MainActor
final class PlanetRenderer {

    private let device:     MTLDevice
    private let pipeline:   MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let overlayDepthState: MTLDepthStencilState
    private let mesh:       SphereMesh

    private var buffer: MTLBuffer?
    private var focusBuffer: MTLBuffer?
    private var continentBuffer: MTLBuffer?
    private var emptyContinentBuffer: MTLBuffer
    private(set) var instanceCount: Int = 0

    init(device: MTLDevice, library: MTLLibrary, mesh: SphereMesh,
         sampleCount: Int, depthFormat: MTLPixelFormat) throws {
        self.device = device
        self.mesh   = mesh
        self.emptyContinentBuffer = device.makeBuffer(
            length: MemoryLayout<SIMD4<Float>>.stride,
            options: .storageModeShared)!

        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction              = library.makeFunction(name: "planetVertex")
        d.fragmentFunction            = library.makeFunction(name: "planetFragment")
        d.rasterSampleCount           = sampleCount
        d.depthAttachmentPixelFormat  = depthFormat
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: d)

        let ds = MTLDepthStencilDescriptor()
        ds.depthCompareFunction = .less
        ds.isDepthWriteEnabled  = true
        depthState = device.makeDepthStencilState(descriptor: ds)!

        let ods = MTLDepthStencilDescriptor()
        ods.depthCompareFunction = .lessEqual
        ods.isDepthWriteEnabled = true
        overlayDepthState = device.makeDepthStencilState(descriptor: ods)!
    }

    /// Refresh the GPU buffer from the universe. Reuses the existing buffer when
    /// big enough so we don't reallocate every poll.
    func updateBuffer(planets: [PlanetBody]) {
        instanceCount = planets.count
        guard !planets.isEmpty else { return }
        let stride = MemoryLayout<PlanetGPU>.stride
        let need = planets.count * stride
        if buffer == nil || buffer!.length < need {
            buffer = device.makeBuffer(length: need, options: .storageModeShared)
        }
        guard let buf = buffer else { return }
        let ptr = buf.contents().bindMemory(to: PlanetGPU.self, capacity: planets.count)
        for i in 0..<planets.count { ptr[i] = planets[i].gpu }
    }

    /// Issue draw call for all planets. Camera & motion uniforms come from the universe-level renderer.
    func draw(in encoder: MTLRenderCommandEncoder,
              camera: inout CameraUniforms,
              motion: inout MotionUniforms) {
        guard instanceCount > 0, let buf = buffer else { return }
        drawBuffer(buf, instanceCount: instanceCount, in: encoder, camera: &camera, motion: &motion)
    }

    func drawFocused(_ planet: PlanetBody,
                     continents: [SIMD4<Float>],
                     continentBlend: Float = 1,
                     in encoder: MTLRenderCommandEncoder,
                     camera: inout CameraUniforms,
                     motion: inout MotionUniforms) {
        let stride = MemoryLayout<PlanetGPU>.stride
        if focusBuffer == nil || focusBuffer!.length < stride {
            focusBuffer = device.makeBuffer(length: stride, options: .storageModeShared)
        }
        guard let buf = focusBuffer else { return }
        buf.contents().bindMemory(to: PlanetGPU.self, capacity: 1)[0] = planet.gpu
        drawBuffer(buf, instanceCount: 1, continents: continents,
                   continentBlend: continentBlend,
                   depthState: overlayDepthState,
                   in: encoder, camera: &camera, motion: &motion)
    }

    private func drawBuffer(_ buf: MTLBuffer,
                            instanceCount: Int,
                            continents: [SIMD4<Float>] = [],
                            continentBlend: Float = 1,
                            depthState: MTLDepthStencilState? = nil,
                            in encoder: MTLRenderCommandEncoder,
                            camera: inout CameraUniforms,
                            motion: inout MotionUniforms) {
        var focusUniform = PlanetFocusUniform(
            continentCount: UInt32(min(continents.count, 32)),
            continentBlend: continentBlend)
        let continentBuffer = continentBuffer(for: continents)

        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState ?? self.depthState)
        encoder.setCullMode(.back)
        encoder.setFrontFacing(.clockwise)

        encoder.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(buf,               offset: 0, index: 1)
        encoder.setVertexBytes(&camera, length: MemoryLayout<CameraUniforms>.size, index: 2)
        encoder.setVertexBytes(&motion, length: MemoryLayout<MotionUniforms>.size, index: 3)
        encoder.setVertexBytes(&focusUniform, length: MemoryLayout<PlanetFocusUniform>.size, index: 4)
        encoder.setFragmentBytes(&camera, length: MemoryLayout<CameraUniforms>.size, index: 2)
        encoder.setFragmentBytes(&motion, length: MemoryLayout<MotionUniforms>.size, index: 3)
        encoder.setFragmentBytes(&focusUniform, length: MemoryLayout<PlanetFocusUniform>.size, index: 4)
        encoder.setFragmentBuffer(continentBuffer, offset: 0, index: 5)

        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: mesh.indexCount,
            indexType: .uint32,
            indexBuffer: mesh.indexBuffer,
            indexBufferOffset: 0,
            instanceCount: instanceCount)
    }

    private func continentBuffer(for continents: [SIMD4<Float>]) -> MTLBuffer {
        let count = min(continents.count, 32)
        guard count > 0 else { return emptyContinentBuffer }
        let stride = MemoryLayout<SIMD4<Float>>.stride
        if continentBuffer == nil || continentBuffer!.length < count * stride {
            continentBuffer = device.makeBuffer(length: count * stride, options: .storageModeShared)
        }
        guard let buffer = continentBuffer else { return emptyContinentBuffer }
        let ptr = buffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        for i in 0..<count {
            let dir = simd_normalize(SIMD3(continents[i].x, continents[i].y, continents[i].z))
            ptr[i] = SIMD4(dir, continents[i].w)
        }
        return buffer
    }
}

struct PlanetFocusUniform {
    var continentCount: UInt32
    var continentBlend: Float
    var _pad1: UInt32 = 0
    var _pad2: UInt32 = 0
}
