// Right-handed, +Y up, camera looks down -Z (standard Metal convention).
import simd

enum Math {

    /// Right-handed perspective projection. Maps view -Z to clip [0, 1] (Metal convention).
    static func perspective(fovYRadians: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovYRadians * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return simd_float4x4(columns: (
            SIMD4(x, 0, 0,  0),
            SIMD4(0, y, 0,  0),
            SIMD4(0, 0, z, -1),
            SIMD4(0, 0, z * near, 0)
        ))
    }

    /// Right-handed orthographic projection. Maps view -Z to clip [0, 1] (Metal convention).
    static func orthographic(left: Float, right: Float, bottom: Float, top: Float,
                             near: Float, far: Float) -> simd_float4x4 {
        let rl = right - left
        let tb = top - bottom
        let fn = far - near
        return simd_float4x4(columns: (
            SIMD4( 2 / rl,            0,                  0,            0),
            SIMD4( 0,                 2 / tb,             0,            0),
            SIMD4( 0,                 0,                 -1 / fn,       0),
            SIMD4(-(right + left)/rl, -(top + bottom)/tb, -near / fn,   1)
        ))
    }

    /// Right-handed lookAt view matrix.
    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let z = simd_normalize(eye - target)         // forward (camera looks toward -z)
        let x = simd_normalize(simd_cross(up, z))    // right
        let y = simd_cross(z, x)                     // recomputed up (orthonormal)
        let t = SIMD3(-simd_dot(x, eye),
                      -simd_dot(y, eye),
                      -simd_dot(z, eye))
        return simd_float4x4(columns: (
            SIMD4(x.x, y.x, z.x, 0),
            SIMD4(x.y, y.y, z.y, 0),
            SIMD4(x.z, y.z, z.z, 0),
            SIMD4(t.x, t.y, t.z, 1)
        ))
    }
}
