// Layer 2 — Rendering: procedural background stars in NDC. Generated once from
// the universe seed so a given user always sees the same sky.
import Metal
import simd

/// Matches StarPoint in starfield.metal — stride 24 bytes.
struct StarfieldPoint {
    var ndc:        SIMD2<Float>   // 8
    var size:       Float          // 4
    var brightness: Float          // 4
    var phase:      Float          // 4
    var _pad:       Float = 0      // 4
}

struct StarfieldUniformsCPU {
    var screenSize: SIMD2<Float>
    var time:       Float
    var _pad:       Float = 0
}

@MainActor
final class StarfieldRenderer {

    private let device:   MTLDevice
    private let pipeline: MTLRenderPipelineState

    private var pointBuffer: MTLBuffer?
    private(set) var pointCount: Int = 0
    private var generatedKey: UInt64 = 0     // seed + params hash last used

    init(device: MTLDevice, library: MTLLibrary,
         sampleCount: Int, depthFormat: MTLPixelFormat) throws {
        self.device = device

        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction              = library.makeFunction(name: "starfieldVertex")
        d.fragmentFunction            = library.makeFunction(name: "starfieldFragment")
        d.rasterSampleCount           = sampleCount
        d.depthAttachmentPixelFormat  = depthFormat
        let ca = d.colorAttachments[0]!
        ca.pixelFormat                 = .bgra8Unorm
        ca.isBlendingEnabled           = true
        ca.rgbBlendOperation           = .add
        ca.alphaBlendOperation         = .add
        // Soft additive: stars brighten the background but don't blow out
        ca.sourceRGBBlendFactor        = .sourceAlpha
        ca.destinationRGBBlendFactor   = .one
        ca.sourceAlphaBlendFactor      = .one
        ca.destinationAlphaBlendFactor = .one
        pipeline = try device.makeRenderPipelineState(descriptor: d)
    }

    /// Re-generate the starfield from the seed. Cheap; only re-runs when the
    /// seed value (or sky params) changes.
    func regenerateIfNeeded(seed: Seed, params: SkyParams) {
        // Hash the params bits we actually use into the cache key so a fresh
        // SkyParams (e.g. from a parameter rebalance) re-rolls the field.
        var paramKey: UInt64 = 0
        paramKey ^= UInt64(bitPattern: Int64(params.nebulaCount))
        paramKey ^= UInt64(bitPattern: Int64(params.clusterCount)) &<< 8
        paramKey ^= UInt64((params.starDensity   * 1000).bitPattern) &<< 16
        paramKey ^= UInt64((params.bandAngle     * 1000).bitPattern) &<< 32
        paramKey ^= UInt64((params.bandStrength  * 1000).bitPattern) &<< 40
        let key = seed.value &+ paramKey
        if generatedKey == key, pointBuffer != nil { return }
        generatedKey = key

        // Total count: 700..2400, biased by seeded density.
        let count = max(400, Int(700 + params.starDensity * 1700))
        pointCount = count

        // Mix in a magic constant so star layout differs from per-body RNG seeds
        // and from the SkyParams RNG stream.
        var rng = SeededRandom(state: seed.value &+ 0xA5_5A_C3_3C_F0_0F_69_69)

        // Cluster centers — small, dense local groupings.
        struct Cluster { var center: SIMD2<Float>; var radius: Float }
        var clusters: [Cluster] = []
        for _ in 0..<Int(params.clusterCount) {
            clusters.append(Cluster(
                center: SIMD2(rng.float(in: -0.92...0.92),
                              rng.float(in: -0.92...0.92)),
                radius: 0.06 + rng.float() * 0.18))
        }

        // Band axis in NDC. The shader applies aspect-correction so the band
        // line in screen space differs slightly, but the overall direction
        // matches closely on standard 16:10/16:9 displays.
        let ba = params.bandAngle
        let bandCos = cos(ba)
        let bandSin = sin(ba)
        let bandWidthN = max(0.18, params.bandWidth * 0.55)  // tighter in NDC
        let bandBias = params.bandStrength

        // Probability splits — keep cluster/band/uniform contributions sane.
        let pCluster = clusters.isEmpty ? 0 : Float(0.16)
        let pBand    = bandBias * 0.55

        var points: [StarfieldPoint] = []
        points.reserveCapacity(count)

        for _ in 0..<count {
            let mode = rng.float()
            var x: Float
            var y: Float

            if mode < pCluster {
                // Cluster — gaussian-ish via sum of three uniforms.
                let pickIdx = Int(rng.float() * Float(clusters.count))
                let c = clusters[min(pickIdx, clusters.count - 1)]
                let dx = (rng.float() + rng.float() + rng.float() - 1.5) * c.radius * 1.5
                let dy = (rng.float() + rng.float() + rng.float() - 1.5) * c.radius * 1.5
                x = c.center.x + dx
                y = c.center.y + dy
            } else if mode < pCluster + pBand {
                // Banded — uniform along the band axis, sum-of-uniforms perpendicular.
                let along = rng.float(in: -1.05...1.05)
                let perpU = (rng.float() + rng.float() + rng.float() - 1.5) * (2.0 / 3.0)
                let perp = perpU * bandWidthN
                x = along * bandCos - perp * bandSin
                y = along * bandSin + perp * bandCos
            } else {
                // Uniform fill — keep the rest of the sky covered.
                x = rng.float(in: -1...1)
                y = rng.float(in: -1...1)
            }

            // Allow a small bleed past the edge so stars near the screen edge
            // aren't all cut off; the GPU will clip what's outside the quad.
            x = min(max(x, -1.05), 1.05)
            y = min(max(y, -1.05), 1.05)

            // Bias toward smaller/dimmer stars so the rare bright ones pop.
            let brightness = pow(rng.float(), 1.9) * 0.88 + 0.10
            let giant      = pow(rng.float(), 9.0)
            let size       = pow(rng.float(), 2.2) * 2.8 + 0.45 + giant * 4.0

            points.append(StarfieldPoint(
                ndc:        SIMD2(x, y),
                size:       size,
                brightness: brightness,
                phase:      rng.float(in: 0...(2 * .pi))))
        }

        let stride = MemoryLayout<StarfieldPoint>.stride
        pointBuffer = device.makeBuffer(length: count * stride, options: .storageModeShared)
        pointBuffer?.contents().copyMemory(from: &points, byteCount: count * stride)
    }

    func draw(in encoder: MTLRenderCommandEncoder,
              screenSize: SIMD2<Float>,
              time: Float) {
        guard let buf = pointBuffer, pointCount > 0 else { return }

        encoder.setRenderPipelineState(pipeline)
        // No depth state — background is depth-test-disabled.
        encoder.setCullMode(.none)

        var uni = StarfieldUniformsCPU(screenSize: screenSize, time: time)
        encoder.setVertexBuffer(buf, offset: 0, index: 0)
        encoder.setVertexBytes(&uni, length: MemoryLayout<StarfieldUniformsCPU>.size, index: 1)
        encoder.setFragmentBytes(&uni, length: MemoryLayout<StarfieldUniformsCPU>.size, index: 1)

        encoder.drawPrimitives(type: .triangleStrip,
                               vertexStart: 0,
                               vertexCount: 4,
                               instanceCount: pointCount)
    }
}
