// Layer 2 — Rendering: indexed UV sphere generated once and instanced per planet
import Metal
import simd

struct SphereMesh {
    let vertexBuffer: MTLBuffer    // SIMD4<Float> stride 16; xyz = unit sphere
    let indexBuffer:  MTLBuffer    // UInt32
    let indexCount:   Int

    /// Tessellation: latSegments × lonSegments quads ≈ 2·lat·lon triangles.
    /// Bumped in Phase 3 for smoother procedural displacement.
    static func make(device: MTLDevice, latSegments: Int = 48, lonSegments: Int = 72) -> SphereMesh {
        var verts: [SIMD4<Float>] = [SIMD4(0, 1, 0, 0)]
        verts.reserveCapacity((latSegments - 1) * (lonSegments + 1) + 2)
        for lat in 1..<latSegments {
            let theta = Float(lat) / Float(latSegments) * .pi      // 0 (north pole) → π (south pole)
            let sinT  = sin(theta), cosT = cos(theta)
            for lon in 0...lonSegments {
                let phi  = Float(lon) / Float(lonSegments) * 2 * .pi
                verts.append(SIMD4(sinT * cos(phi), cosT, sinT * sin(phi), 0))
            }
        }
        let southPole = UInt32(verts.count)
        verts.append(SIMD4(0, -1, 0, 0))

        var idx: [UInt32] = []
        idx.reserveCapacity(latSegments * lonSegments * 6)
        let stride = lonSegments + 1
        for lon in 0..<lonSegments {
            let a = UInt32(1 + lon)
            let b = UInt32(1 + lon + 1)
            idx.append(contentsOf: [0, a, b])
        }
        if latSegments > 2 {
            for lat in 0..<(latSegments - 2) {
                let row0 = 1 + lat * stride
                let row1 = row0 + stride
                for lon in 0..<lonSegments {
                    let a = UInt32(row0 + lon)
                    let b = a + 1
                    let c = UInt32(row1 + lon)
                    let d = c + 1
                    idx.append(contentsOf: [a, c, b,  b, c, d])
                }
            }
        }
        let lastRow = 1 + max(0, latSegments - 2) * stride
        for lon in 0..<lonSegments {
            let a = UInt32(lastRow + lon)
            let b = UInt32(lastRow + lon + 1)
            idx.append(contentsOf: [a, southPole, b])
        }

        let vBuf = device.makeBuffer(
            bytes: verts,
            length: verts.count * MemoryLayout<SIMD4<Float>>.stride,
            options: .storageModeShared)!
        let iBuf = device.makeBuffer(
            bytes: idx,
            length: idx.count * MemoryLayout<UInt32>.stride,
            options: .storageModeShared)!
        return SphereMesh(vertexBuffer: vBuf, indexBuffer: iBuf, indexCount: idx.count)
    }
}
