// Layer 2 — Rendering: text labels above any labelled body. Body-kind agnostic —
// takes (position, radius, name) tuples so future kinds can opt in.
import Metal
import simd

// 16 bytes — matches LabelTarget in labels.metal
struct LabelTarget {
    /// xyz = world-space anchor of the body, w = body radius
    var positionAndRadius: SIMD4<Float>
}

// 32 bytes — matches LabelUniforms in labels.metal
struct LabelUniforms {
    var cameraRight: SIMD4<Float>
    var cameraUp:    SIMD4<Float>
    var worldHeight: Float
    var layerAspect: Float
    var _pad0: Float = 0
    var _pad1: Float = 0
}

@MainActor
final class LabelRenderer {

    private let device:     MTLDevice
    private let pipeline:   MTLRenderPipelineState
    private let depthState: MTLDepthStencilState

    private let atlas: LabelAtlas
    private var targetBuffer:    MTLBuffer?
    /// Per-instance SIMD2<Float>: x=widthFraction, y=heightFraction (of texture layer).
    private var pillFracsBuffer: MTLBuffer?
    private var currentNames: [String] = []
    private(set) var instanceCount: Int = 0

    init(device: MTLDevice, library: MTLLibrary,
         sampleCount: Int, depthFormat: MTLPixelFormat) throws {
        self.device = device
        self.atlas  = LabelAtlas(device: device)

        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction              = library.makeFunction(name: "labelVertex")
        d.fragmentFunction            = library.makeFunction(name: "labelFragment")
        d.rasterSampleCount           = sampleCount
        d.depthAttachmentPixelFormat  = depthFormat
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
        ds.depthCompareFunction = .lessEqual
        ds.isDepthWriteEnabled  = false
        depthState = device.makeDepthStencilState(descriptor: ds)!
    }

    /// Full rebuild — atlas + per-instance buffers. Expensive (text rendering).
    /// Only call when the set of names changes.
    func updateLabels(positions: [SIMD3<Float>], radii: [Float], names: [String]) {
        let n = min(positions.count, radii.count, names.count)
        instanceCount = n
        let activeNames = Array(names.prefix(n))
        if currentNames != activeNames || pillFracsBuffer == nil {
            currentNames = activeNames
            atlas.rebuild(names: activeNames)

            // Pack widthFrac + heightFrac into one SIMD2<Float> per instance.
            let stride = MemoryLayout<SIMD2<Float>>.stride
            let buf = device.makeBuffer(length: max(stride, n * stride), options: .storageModeShared)
            if n > 0, let buf {
                let ptr = buf.contents().bindMemory(to: SIMD2<Float>.self, capacity: n)
                for i in 0..<n {
                    ptr[i] = SIMD2(atlas.widthFractions[i], atlas.heightFractions[i])
                }
            }
            pillFracsBuffer = buf
        }

        rewriteTargets(positions: positions, radii: radii)
    }

    /// Cheap positions-only update — just rewrites the target buffer.
    /// Skips atlas rebuild + width-fractions rebuild. Call this on every poll.
    func updateLabelPositions(positions: [SIMD3<Float>], radii: [Float]) {
        let n = min(positions.count, radii.count, instanceCount)
        guard n > 0 else { return }
        rewriteTargets(positions: positions, radii: radii)
    }

    func updateLabelPositions(planets: [PlanetBody]) {
        let n = min(planets.count, instanceCount)
        guard n > 0 else { return }
        let tStride = MemoryLayout<LabelTarget>.stride
        if targetBuffer == nil || targetBuffer!.length < n * tStride {
            targetBuffer = device.makeBuffer(length: n * tStride, options: .storageModeShared)
        }
        guard let buf = targetBuffer else { return }
        let ptr = buf.contents().bindMemory(to: LabelTarget.self, capacity: n)
        for i in 0..<n {
            ptr[i] = LabelTarget(positionAndRadius: SIMD4(planets[i].position, planets[i].radius))
        }
    }

    private func rewriteTargets(positions: [SIMD3<Float>], radii: [Float]) {
        let n = min(positions.count, radii.count)
        guard n > 0 else { targetBuffer = nil; return }
        let tStride = MemoryLayout<LabelTarget>.stride
        // Reuse the existing buffer if it's big enough — avoids reallocation churn
        if targetBuffer == nil || targetBuffer!.length < n * tStride {
            targetBuffer = device.makeBuffer(length: n * tStride, options: .storageModeShared)
        }
        guard let buf = targetBuffer else { return }
        let ptr = buf.contents().bindMemory(to: LabelTarget.self, capacity: n)
        for i in 0..<n {
            ptr[i] = LabelTarget(positionAndRadius: SIMD4(positions[i], radii[i]))
        }
    }

    func draw(in encoder: MTLRenderCommandEncoder,
              camera: inout CameraUniforms,
              cameraRight: SIMD3<Float>,
              cameraUp: SIMD3<Float>) {
        guard instanceCount > 0,
              let target = targetBuffer,
              let pillFracs = pillFracsBuffer,
              let atlasTex = atlas.texture else { return }

        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)

        var labelUni = LabelUniforms(
            cameraRight: SIMD4(cameraRight, 0),
            cameraUp:    SIMD4(cameraUp, 0),
            worldHeight: 24.0,
            layerAspect: Float(LabelAtlas.layerWidth) / Float(LabelAtlas.layerHeight))

        encoder.setVertexBuffer(target, offset: 0, index: 1)
        encoder.setVertexBytes(&camera,    length: MemoryLayout<CameraUniforms>.size, index: 2)
        encoder.setVertexBytes(&labelUni,  length: MemoryLayout<LabelUniforms>.size,  index: 3)
        encoder.setVertexBuffer(pillFracs, offset: 0, index: 4)
        encoder.setFragmentTexture(atlasTex, index: 0)

        encoder.drawPrimitives(type: .triangleStrip,
                               vertexStart: 0,
                               vertexCount: 4,
                               instanceCount: instanceCount)
    }
}
