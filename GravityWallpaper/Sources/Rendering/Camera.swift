// Layer 2 — Rendering: top-down orthographic camera.
// World units = screen points (1 pt = 1 world unit). A planet at world (px, 0, py)
// renders exactly at screen point (px, py). This makes planets line up 1:1 with
// the desktop's folder icons.
import simd

struct Camera {

    /// Set by the renderer from PlanetSystem.screenSize each frame.
    var screenSize: SIMD2<Float> = SIMD2(1920, 1080)
    var height:     Float        = 220       // world units between camera and y=0 plane

    /// > 1 zooms out (shows more world). Smoothly animated by UniverseRenderer.
    var zoomScale: Float = 1.0

    var position: SIMD3<Float> {
        SIMD3(screenSize.x * 0.5, height, screenSize.y * 0.5)
    }
    var target: SIMD3<Float> {
        SIMD3(screenSize.x * 0.5, 0, screenSize.y * 0.5)
    }
    var up: SIMD3<Float> { SIMD3(0, 0, -1) }     // world -Z is "up" on screen

    func viewProjection() -> simd_float4x4 {
        let view = Math.lookAt(eye: position, target: target, up: up)
        let halfW = screenSize.x * 0.5 * zoomScale
        let halfH = screenSize.y * 0.5 * zoomScale
        let proj  = Math.orthographic(left:  -halfW, right: halfW,
                                      bottom: -halfH, top:  halfH,
                                      near: 0.1, far: height + 200)
        return proj * view
    }

    /// Unproject a screen-NDC cursor onto the world y=0 plane.
    /// Accounts for zoomScale so hit-testing stays correct when zoomed.
    func unprojectToGroundPlane(ndc: SIMD2<Float>) -> SIMD3<Float> {
        let halfW = screenSize.x * 0.5 * zoomScale
        let halfH = screenSize.y * 0.5 * zoomScale
        let worldX =  ndc.x * halfW + screenSize.x * 0.5
        let worldZ = -ndc.y * halfH + screenSize.y * 0.5
        return SIMD3(worldX, 0, worldZ)
    }
}
