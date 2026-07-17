// Layer 2 — Rendering: instanced low-poly Codex spacecraft, twin engine glow,
// and curved exhaust ribbons. Agent instance data uses setVertexBytes so each
// command buffer owns an immutable copy; this avoids overwriting an MTLBuffer
// while an earlier frame is still reading it.
import Metal
import simd

private struct AgentMeshVertex {
    var position: SIMD4<Float>
    /// xyz = flat face normal, w = material id encoded as a Float.
    var normalAndMaterial: SIMD4<Float>
}

private enum AgentRendererSetupError: Error {
    case depthState
    case glowDepthState
    case meshAllocation
}

@MainActor
final class AgentRenderer {
    static let maxVisibleAgents = 48
    static let trailSegmentCount = 36

    private let shipPipeline: MTLRenderPipelineState
    private let trailPipeline: MTLRenderPipelineState
    private let enginePipeline: MTLRenderPipelineState
    private let shipDepth: MTLDepthStencilState
    private let glowDepth: MTLDepthStencilState
    private let meshBuffer: MTLBuffer
    private let meshVertexCount: Int

    private var instances: [AgentGPU] = []
    private(set) var agentCount = 0

    init(device: MTLDevice,
         library: MTLLibrary,
         sampleCount: Int,
         depthFormat: MTLPixelFormat) throws {
        let ship = MTLRenderPipelineDescriptor()
        ship.label = "Agent spacecraft"
        ship.vertexFunction = library.makeFunction(name: "agentShipVertex")
        ship.fragmentFunction = library.makeFunction(name: "agentShipFragment")
        ship.rasterSampleCount = sampleCount
        ship.depthAttachmentPixelFormat = depthFormat
        ship.colorAttachments[0].pixelFormat = .bgra8Unorm
        shipPipeline = try device.makeRenderPipelineState(descriptor: ship)

        trailPipeline = try Self.makeAdditivePipeline(
            device: device,
            library: library,
            label: "Agent trail",
            vertex: "agentTrailVertex",
            fragment: "agentTrailFragment",
            sampleCount: sampleCount,
            depthFormat: depthFormat)

        enginePipeline = try Self.makeAdditivePipeline(
            device: device,
            library: library,
            label: "Agent engines",
            vertex: "agentEngineVertex",
            fragment: "agentEngineFragment",
            sampleCount: sampleCount,
            depthFormat: depthFormat)

        let opaqueDepth = MTLDepthStencilDescriptor()
        opaqueDepth.depthCompareFunction = .lessEqual
        opaqueDepth.isDepthWriteEnabled = true
        guard let shipDepth = device.makeDepthStencilState(descriptor: opaqueDepth) else {
            throw AgentRendererSetupError.depthState
        }
        self.shipDepth = shipDepth

        let additiveDepth = MTLDepthStencilDescriptor()
        additiveDepth.depthCompareFunction = .lessEqual
        additiveDepth.isDepthWriteEnabled = false
        guard let glowDepth = device.makeDepthStencilState(descriptor: additiveDepth) else {
            throw AgentRendererSetupError.glowDepthState
        }
        self.glowDepth = glowDepth

        let vertices = Self.makeShipMesh()
        meshVertexCount = vertices.count
        guard let meshBuffer = device.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<AgentMeshVertex>.stride,
            options: .storageModeShared) else {
            throw AgentRendererSetupError.meshAllocation
        }
        meshBuffer.label = "Agent low-poly probe mesh"
        self.meshBuffer = meshBuffer
    }

    func update(agents: [AgentBody]) {
        instances = agents.prefix(Self.maxVisibleAgents).map(\.gpu)
        agentCount = instances.count
    }

    /// Draw after opaque celestial bodies and before labels. Trails and engines
    /// depth-test against planets but never write depth; the ship itself does.
    func draw(in encoder: MTLRenderCommandEncoder,
              camera: inout CameraUniforms,
              motion: inout MotionUniforms) {
        guard !instances.isEmpty else { return }

        instances.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }

            // Curved ribbon behind each ship.
            encoder.pushDebugGroup("Agent trails")
            encoder.setRenderPipelineState(trailPipeline)
            encoder.setDepthStencilState(glowDepth)
            encoder.setCullMode(.none)
            encoder.setVertexBytes(baseAddress, length: bytes.count, index: 1)
            encoder.setVertexBytes(&camera, length: MemoryLayout<CameraUniforms>.stride, index: 2)
            encoder.setVertexBytes(&motion, length: MemoryLayout<MotionUniforms>.stride, index: 3)
            encoder.setFragmentBytes(&motion, length: MemoryLayout<MotionUniforms>.stride, index: 3)
            encoder.drawPrimitives(
                type: .triangleStrip,
                vertexStart: 0,
                vertexCount: (Self.trailSegmentCount + 1) * 2,
                instanceCount: agentCount)
            encoder.popDebugGroup()

            // Twin analytic engine flames (two instances per spacecraft).
            encoder.pushDebugGroup("Agent engines")
            encoder.setRenderPipelineState(enginePipeline)
            encoder.setDepthStencilState(glowDepth)
            encoder.setCullMode(.none)
            encoder.setVertexBytes(baseAddress, length: bytes.count, index: 1)
            encoder.setVertexBytes(&camera, length: MemoryLayout<CameraUniforms>.stride, index: 2)
            encoder.setVertexBytes(&motion, length: MemoryLayout<MotionUniforms>.stride, index: 3)
            encoder.setFragmentBytes(&motion, length: MemoryLayout<MotionUniforms>.stride, index: 3)
            encoder.drawPrimitives(
                type: .triangleStrip,
                vertexStart: 0,
                vertexCount: 4,
                instanceCount: agentCount * 2)
            encoder.popDebugGroup()

            // Faceted graphite-and-Codex-blue probe hull.
            encoder.pushDebugGroup("Agent spacecraft")
            encoder.setRenderPipelineState(shipPipeline)
            encoder.setDepthStencilState(shipDepth)
            encoder.setCullMode(.none)
            encoder.setVertexBuffer(meshBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(baseAddress, length: bytes.count, index: 1)
            encoder.setVertexBytes(&camera, length: MemoryLayout<CameraUniforms>.stride, index: 2)
            encoder.setVertexBytes(&motion, length: MemoryLayout<MotionUniforms>.stride, index: 3)
            encoder.setFragmentBytes(&camera, length: MemoryLayout<CameraUniforms>.stride, index: 2)
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: meshVertexCount,
                instanceCount: agentCount)
            encoder.popDebugGroup()
        }
    }

    private static func makeAdditivePipeline(device: MTLDevice,
                                             library: MTLLibrary,
                                             label: String,
                                             vertex: String,
                                             fragment: String,
                                             sampleCount: Int,
                                             depthFormat: MTLPixelFormat) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = label
        descriptor.vertexFunction = library.makeFunction(name: vertex)
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        descriptor.rasterSampleCount = sampleCount
        descriptor.depthAttachmentPixelFormat = depthFormat
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm
        color.isBlendingEnabled = true
        color.rgbBlendOperation = .add
        color.alphaBlendOperation = .add
        color.sourceRGBBlendFactor = .one
        color.destinationRGBBlendFactor = .one
        color.sourceAlphaBlendFactor = .one
        color.destinationAlphaBlendFactor = .one
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static func makeShipMesh() -> [AgentMeshVertex] {
        typealias P = SIMD3<Float>
        var output: [AgentMeshVertex] = []
        output.reserveCapacity(150)

        func triangle(_ a: P, _ b: P, _ c: P, material: Float) {
            let crossProduct = simd_cross(b - a, c - a)
            let lengthSquared = simd_length_squared(crossProduct)
            let normal = lengthSquared > 0.000_001
                ? crossProduct / sqrt(lengthSquared)
                : P(0, 1, 0)
            let packedNormal = SIMD4(normal, material)
            output.append(AgentMeshVertex(position: SIMD4(a, 1), normalAndMaterial: packedNormal))
            output.append(AgentMeshVertex(position: SIMD4(b, 1), normalAndMaterial: packedNormal))
            output.append(AgentMeshVertex(position: SIMD4(c, 1), normalAndMaterial: packedNormal))
        }

        func quad(_ a: P, _ b: P, _ c: P, _ d: P, material: Float) {
            triangle(a, b, c, material: material)
            triangle(a, c, d, material: material)
        }

        // Angular central fuselage. Local +Z is forward.
        let nose = P(0, 0.02, 1.55)
        let topFront = P(0, 0.38, 0.38)
        let bottomFront = P(0, -0.15, 0.30)
        let leftMid = P(-0.38, 0.01, 0.22)
        let rightMid = P(0.38, 0.01, 0.22)
        let topRear = P(0, 0.27, -0.73)
        let bottomRear = P(0, -0.11, -0.73)
        let leftRear = P(-0.25, 0.00, -0.65)
        let rightRear = P(0.25, 0.00, -0.65)

        triangle(nose, leftMid, topFront, material: 0)
        triangle(nose, topFront, rightMid, material: 0)
        triangle(nose, bottomFront, leftMid, material: 0)
        triangle(nose, rightMid, bottomFront, material: 0)
        quad(leftMid, leftRear, topRear, topFront, material: 0)
        quad(topFront, topRear, rightRear, rightMid, material: 0)
        quad(leftMid, bottomFront, bottomRear, leftRear, material: 0)
        quad(rightMid, rightRear, bottomRear, bottomFront, material: 0)
        triangle(leftRear, bottomRear, topRear, material: 1)
        triangle(topRear, bottomRear, rightRear, material: 1)

        // Swept wedge wings with a bright Codex-blue upper panel.
        func wing(sign: Float) {
            let rootFrontTop = P(sign * 0.28, 0.055, 0.30)
            let tipFrontTop = P(sign * 1.17, 0.025, -0.02)
            let tipBackTop = P(sign * 0.84, 0.025, -0.64)
            let rootBackTop = P(sign * 0.23, 0.055, -0.48)
            let rootFrontBottom = P(rootFrontTop.x, -0.055, rootFrontTop.z)
            let tipFrontBottom = P(tipFrontTop.x, -0.040, tipFrontTop.z)
            let tipBackBottom = P(tipBackTop.x, -0.040, tipBackTop.z)
            let rootBackBottom = P(rootBackTop.x, -0.055, rootBackTop.z)

            quad(rootFrontTop, tipFrontTop, tipBackTop, rootBackTop, material: 1)
            quad(rootBackBottom, tipBackBottom, tipFrontBottom, rootFrontBottom, material: 0)
            quad(tipFrontTop, tipFrontBottom, tipBackBottom, tipBackTop, material: 0)
            quad(tipBackTop, tipBackBottom, rootBackBottom, rootBackTop, material: 0)
            quad(rootFrontTop, rootFrontBottom, tipFrontBottom, tipFrontTop, material: 0)
        }
        wing(sign: -1)
        wing(sign: 1)

        // Raised crystalline cockpit.
        let canopyA = P(-0.16, 0.25, 0.42)
        let canopyB = P(0.16, 0.25, 0.42)
        let canopyC = P(0.12, 0.25, -0.10)
        let canopyD = P(-0.12, 0.25, -0.10)
        let canopyPeak = P(0, 0.49, 0.13)
        triangle(canopyA, canopyB, canopyPeak, material: 2)
        triangle(canopyB, canopyC, canopyPeak, material: 2)
        triangle(canopyC, canopyD, canopyPeak, material: 2)
        triangle(canopyD, canopyA, canopyPeak, material: 2)

        // Two compact rear engine pods.
        func enginePod(sign: Float) {
            let x = sign * 0.29
            let frontTop = P(x, 0.13, -0.48)
            let backTop = P(x, 0.12, -0.91)
            let left = P(x - 0.11, 0.00, -0.62)
            let right = P(x + 0.11, 0.00, -0.62)
            let backBottom = P(x, -0.08, -0.91)
            triangle(frontTop, left, backTop, material: 0)
            triangle(frontTop, backTop, right, material: 0)
            triangle(left, backBottom, backTop, material: 1)
            triangle(right, backTop, backBottom, material: 1)
            triangle(frontTop, right, backBottom, material: 0)
            triangle(frontTop, backBottom, left, material: 0)
        }
        enginePod(sign: -1)
        enginePod(sign: 1)

        return output
    }
}
