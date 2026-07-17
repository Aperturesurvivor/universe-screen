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

    /// Evenly tessellated sphere with no UV seam or high-valence pole fans.
    /// This is especially useful for displaced procedural bodies: every face
    /// has a similar size, so local displacement cannot expose a pinched pole.
    static func makeIcosphere(device: MTLDevice, subdivisions: Int = 5) -> SphereMesh {
        let phi = Float((1.0 + sqrt(5.0)) * 0.5)
        var positions: [SIMD3<Float>] = [
            SIMD3(-1,  phi,  0), SIMD3( 1,  phi,  0),
            SIMD3(-1, -phi,  0), SIMD3( 1, -phi,  0),
            SIMD3( 0, -1,  phi), SIMD3( 0,  1,  phi),
            SIMD3( 0, -1, -phi), SIMD3( 0,  1, -phi),
            SIMD3( phi,  0, -1), SIMD3( phi,  0,  1),
            SIMD3(-phi,  0, -1), SIMD3(-phi,  0,  1)
        ].map(simd_normalize)

        var faces: [(UInt32, UInt32, UInt32)] = [
            (0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11),
            (1, 5, 9), (5, 11, 4), (11, 10, 2), (10, 7, 6), (7, 1, 8),
            (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9),
            (4, 9, 5), (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1)
        ]

        for _ in 0..<max(0, subdivisions) {
            var midpointCache: [UInt64: UInt32] = [:]

            func midpoint(_ lhs: UInt32, _ rhs: UInt32) -> UInt32 {
                let low = min(lhs, rhs)
                let high = max(lhs, rhs)
                let key = (UInt64(low) << 32) | UInt64(high)
                if let existing = midpointCache[key] { return existing }

                let point = simd_normalize(
                    positions[Int(lhs)] + positions[Int(rhs)])
                let index = UInt32(positions.count)
                positions.append(point)
                midpointCache[key] = index
                return index
            }

            var refined: [(UInt32, UInt32, UInt32)] = []
            refined.reserveCapacity(faces.count * 4)
            for (a, b, c) in faces {
                let ab = midpoint(a, b)
                let bc = midpoint(b, c)
                let ca = midpoint(c, a)
                refined.append(contentsOf: [
                    (a, ab, ca),
                    (b, bc, ab),
                    (c, ca, bc),
                    (ab, bc, ca)
                ])
            }
            faces = refined
        }

        let vertices = positions.map { SIMD4<Float>($0, 0) }
        let indices = faces.flatMap { [$0.0, $0.1, $0.2] }
        let vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<SIMD4<Float>>.stride,
            options: .storageModeShared)!
        let indexBuffer = device.makeBuffer(
            bytes: indices,
            length: indices.count * MemoryLayout<UInt32>.stride,
            options: .storageModeShared)!
        return SphereMesh(
            vertexBuffer: vertexBuffer,
            indexBuffer: indexBuffer,
            indexCount: indices.count)
    }
}
