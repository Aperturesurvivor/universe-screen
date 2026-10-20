// Shared per-frame uniforms used by every per-kind body renderer.
import simd

/// 96 bytes — matches `CameraUniforms` in every body shader.
struct CameraUniforms {
    var viewProjection: simd_float4x4   // 64
    var cameraPos:      SIMD4<Float>    // 16 (.xyz used)
    var lightPos:       SIMD4<Float>    // 16 (.xyz used; future "Star")
}

/// 32 bytes — matches `MotionUniforms` in every body shader.
struct MotionUniforms {
    var time:               Float        // offset  0
    var motionAmount:       Float        // offset  4
    var cursorPushStrength: Float        // offset  8
    var cursorEnabled:      UInt32       // offset 12
    var cursorWorldPos:     SIMD4<Float> // offset 16 (.xyz used)
}
