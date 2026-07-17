// Layer 2 — Rendering: top-level MTKViewDelegate.
// Owns the per-kind renderers and dispatches them in a single render pass.
import Metal
import MetalKit
import simd

enum RendererError: LocalizedError {
    case noCommandQueue, noMetalLibrary, pipelineError(String)
    var errorDescription: String? {
        switch self {
        case .noCommandQueue:        return "Failed to create render command queue"
        case .noMetalLibrary:        return "Default Metal library not found"
        case .pipelineError(let m):  return "Render pipeline: \(m)"
        }
    }
}

@MainActor
final class UniverseRenderer: NSObject, MTKViewDelegate {

    static let sampleCount = 1
    static let depthFormat: MTLPixelFormat = .depth32Float

    private let device: MTLDevice
    private let queue:  MTLCommandQueue
    private let mesh:   SphereMesh

    private let planetRenderer:    PlanetRenderer
    private let asteroidRenderer:  AsteroidRenderer
    private let agentRenderer:     AgentRenderer
    private let labelRenderer:     LabelRenderer
    private let starRenderer:      StarRenderer
    private let blackHoleRenderer: BlackHoleRenderer
    private let backgroundRenderer: BackgroundRenderer
    private let starfieldRenderer: StarfieldRenderer
    private let orbitRingRenderer: OrbitRingRenderer

    let universe: Universe
    let config:   SimulationConfig
    var camera   = Camera()

    private var drawableSize: SIMD2<Float> = .zero
    private let startTime = CACurrentMediaTime()
    private var lastFrameTime    = CACurrentMediaTime()
    private var lastLabelUploadTime = CACurrentMediaTime()
    private var fpsWindowStart = CACurrentMediaTime()
    private var fpsFrameCount = 0
    private var currentZoomScale: Float = 1.0
    private var targetZoomScale:  Float = 1.0
    private var focus: FocusState?

    /// Cursor in NDC ([-1, 1]²); set by WallpaperWindowController.
    var cursorNDC: SIMD2<Float> = .zero

    var isFocusedOnPlanet: Bool { focus != nil }

    private struct FocusState {
        var planet: PlanetBody
        var items: [FolderContentItem]
        var continents: [SIMD4<Float>]
        var startNDC: SIMD2<Float>
        var startNDCRadius: Float
        var yaw: Float = 0.35
        var pitch: Float = 0.18
        var progress: Float = 0
        var targetProgress: Float = 1

        var labelNames: [String] {
            items.isEmpty ? ["Empty folder"] : items.map(\.name)
        }
    }

    init(device: MTLDevice, universe: Universe, config: SimulationConfig) throws {
        self.device   = device
        self.universe = universe
        self.config   = config

        guard let q = device.makeCommandQueue() else { throw RendererError.noCommandQueue }
        queue = q

        guard let lib = device.makeDefaultLibrary() else { throw RendererError.noMetalLibrary }

        // The procedural fragment shaders supply most of the visual detail. A
        // moderate surface mesh keeps planets smooth while avoiding tens of
        // thousands of unnecessary triangles for every tiny asteroid.
        mesh = SphereMesh.make(device: device, latSegments: 64, lonSegments: 96)
        let asteroidMesh = SphereMesh.make(device: device, latSegments: 20, lonSegments: 32)

        do {
            planetRenderer    = try PlanetRenderer(device: device, library: lib, mesh: mesh,
                                                   sampleCount: Self.sampleCount,
                                                   depthFormat: Self.depthFormat)
            asteroidRenderer  = try AsteroidRenderer(device: device, library: lib, mesh: asteroidMesh,
                                                     sampleCount: Self.sampleCount,
                                                     depthFormat: Self.depthFormat)
            agentRenderer     = try AgentRenderer(device: device, library: lib,
                                                  sampleCount: Self.sampleCount,
                                                  depthFormat: Self.depthFormat)
            labelRenderer     = try LabelRenderer(device: device, library: lib,
                                                  sampleCount: Self.sampleCount,
                                                  depthFormat: Self.depthFormat)
            starRenderer      = try StarRenderer(device: device, library: lib, mesh: mesh,
                                                 sampleCount: Self.sampleCount,
                                                 depthFormat: Self.depthFormat)
            blackHoleRenderer = try BlackHoleRenderer(device: device, library: lib, mesh: mesh,
                                                      sampleCount: Self.sampleCount,
                                                      depthFormat: Self.depthFormat)
            backgroundRenderer = try BackgroundRenderer(device: device, library: lib,
                                                        sampleCount: Self.sampleCount,
                                                        depthFormat: Self.depthFormat)
            starfieldRenderer = try StarfieldRenderer(device: device, library: lib,
                                                      sampleCount: Self.sampleCount,
                                                      depthFormat: Self.depthFormat)
            orbitRingRenderer = try OrbitRingRenderer(device: device, library: lib,
                                                      sampleCount: Self.sampleCount,
                                                      depthFormat: Self.depthFormat)
        } catch {
            throw RendererError.pipelineError(error.localizedDescription)
        }

        super.init()
    }

    /// FULL refresh — rebuilds the label atlas (text rendering). Use after a
    /// scan that may have added/removed/renamed bodies.
    func refreshFromUniverse() {
        if focus != nil { return }
        planetRenderer.updateBuffer(planets: universe.planets)
        asteroidRenderer.updateBuffer(asteroids: universe.asteroids)
        agentRenderer.update(agents: config.showCodexAgents ? universe.agents : [])
        starRenderer.update(star: universe.star)
        blackHoleRenderer.update(blackHole: universe.blackHole)
        starfieldRenderer.regenerateIfNeeded(
            seed:   universe.seed,
            params: backgroundRenderer.params(for: universe.seed))
        rebuildOrbitalLabels()
        let starCenter = SIMD3(Float(universe.screenSize.width)  * 0.5,
                               0,
                               Float(universe.screenSize.height) * 0.5)
        orbitRingRenderer.update(ringRadii: universe.shellRadii, starCenter: starCenter)
    }

    /// CHEAP refresh — just rewrites position/radius into existing buffers.
    /// Use on the position-poll path so we don't re-render every label texture
    /// every 400 ms.
    func refreshPositionsOnly() {
        if focus != nil { return }
        planetRenderer.updateBuffer(planets: universe.planets)
        asteroidRenderer.updateBuffer(asteroids: universe.asteroids)
        agentRenderer.update(agents: config.showCodexAgents ? universe.agents : [])
        updateOrbitalLabelPositions()
    }

    func refreshAgents() {
        guard focus == nil else { return }
        agentRenderer.update(agents: config.showCodexAgents ? universe.agents : [])
        rebuildOrbitalLabels()
    }

    private func rebuildOrbitalLabels() {
        let visibleAgents = config.showCodexAgents ? universe.agents : []
        labelRenderer.updateLabels(
            positions: universe.planets.map(\.position) + visibleAgents.map(\.position),
            radii: universe.planets.map(\.radius) + visibleAgents.map(\.radius),
            names: universe.planets.map(\.name) + visibleAgents.map(\.name))
    }

    private func updateOrbitalLabelPositions() {
        let visibleAgents = config.showCodexAgents ? universe.agents : []
        labelRenderer.updateLabelPositions(
            positions: universe.planets.map(\.position) + visibleAgents.map(\.position),
            radii: universe.planets.map(\.radius) + visibleAgents.map(\.radius))
    }

    /// Star-only update — for browser change / network state flip.
    func refreshStar() {
        starRenderer.update(star: universe.star)
    }

    var currentDrawableSize: CGSize? {
        drawableSize == .zero ? nil : CGSize(width: Double(drawableSize.x), height: Double(drawableSize.y))
    }

    /// Hit-test a click in NDC against the universe.
    func bodyAtNDC(_ ndc: SIMD2<Float>) -> (any CelestialBody)? {
        if focus != nil { return nil }
        syncCameraToUniverse()
        let world = camera.unprojectToGroundPlane(ndc: ndc)
        return universe.body(atWorld: world)
    }

    @discardableResult
    func focusPlanet(atNDC ndc: SIMD2<Float>) -> Bool {
        syncCameraToUniverse()
        let world = camera.unprojectToGroundPlane(ndc: ndc)
        guard let planet = universe.body(atWorld: world) as? PlanetBody,
              let url = planet.actionURL else { return false }

        let items = FolderContentScanner.scan(url)
        let continents = Self.continents(for: items, fallbackSeed: planet.stableId)
        let startNDC = projectedNDC(for: planet.position)
        let startNDCRadius = planet.radius / max(1, camera.screenSize.y * 0.5 * camera.zoomScale)
        focus = FocusState(
            planet: planet,
            items: items,
            continents: continents,
            startNDC: startNDC,
            startNDCRadius: startNDCRadius)
        labelRenderer.updateLabels(
            positions: focusLabelPositions(),
            radii: focusLabelRadii(),
            names: focus?.labelNames ?? [])
        return true
    }

    func exitPlanetFocus() {
        guard var activeFocus = focus else { return }
        activeFocus.targetProgress = 0
        focus = activeFocus
    }

    func rotateFocusedPlanet(delta: SIMD2<Float>) {
        guard var f = focus else { return }
        f.yaw -= delta.x * 0.008
        f.pitch = min(1.15, max(-1.15, f.pitch + delta.y * 0.008))
        focus = f
    }

    private func syncCameraToUniverse() {
        let s = universe.screenSize
        if s.width > 1, s.height > 1 {
            camera.screenSize = SIMD2(Float(s.width), Float(s.height))
        }
    }

    private func focusRadius() -> Float {
        max(130, min(drawableSize.x, drawableSize.y) * 0.22)
    }

    private func smootherStep(_ t: Float) -> Float {
        let x = min(1, max(0, t))
        return x * x * x * (x * (x * 6 - 15) + 10)
    }

    private func focusedPlanet(center: SIMD3<Float>, radius: Float) -> PlanetBody? {
        guard var f = focus else { return nil }
        f.planet.position = center
        f.planet.radius = radius
        f.planet.spinSpeed = 0
        return f.planet
    }

    private func focusScene() -> (CameraUniforms, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, Float) {
        let radius = focusRadius()
        let rawProgress = focus?.progress ?? 1
        let progress = smootherStep(rawProgress)
        let distance = simd_mix(radius * 4.9, radius * 3.25, progress)
        let yaw = focus?.yaw ?? 0
        let pitch = focus?.pitch ?? 0
        let eye = SIMD3<Float>(
            sin(yaw) * cos(pitch) * distance,
            sin(pitch) * distance,
            cos(yaw) * cos(pitch) * distance)
        let view = Math.lookAt(eye: eye, target: .zero, up: SIMD3(0, 1, 0))
        let aspect = max(0.1, drawableSize.x / max(drawableSize.y, 1))
        let proj = Math.perspective(fovYRadians: 48 * .pi / 180, aspect: aspect, near: 1, far: radius * 12)
        let viewInv = simd_inverse(view)
        let camRight = SIMD3(viewInv.columns.0.x, viewInv.columns.0.y, viewInv.columns.0.z)
        let camUp = SIMD3(viewInv.columns.1.x, viewInv.columns.1.y, viewInv.columns.1.z)
        let light = SIMD3(radius * -2.2, radius * 2.4, radius * 2.8)
        let halfH = tan((48 * .pi / 180) * 0.5) * distance
        let halfW = halfH * aspect
        let startNDC = focus?.startNDC ?? .zero
        let startCenter = camRight * (startNDC.x * halfW) + camUp * (startNDC.y * halfH)
        let center = startCenter * (1 - progress)
        let startRadius = (focus?.startNDCRadius ?? 0.05) * halfH
        let planetRadius = simd_mix(startRadius, radius, progress)
        return (
            CameraUniforms(
                viewProjection: proj * view,
                cameraPos: SIMD4(eye, 1),
                lightPos: SIMD4(light, 1)),
            camRight,
            camUp,
            center,
            planetRadius
        )
    }

    private func focusLabelPositions(center: SIMD3<Float>? = nil, radius overrideRadius: Float? = nil) -> [SIMD3<Float>] {
        guard let focus else { return [] }
        let radius = overrideRadius ?? focusRadius()
        let center = center ?? .zero
        let continents = focus.continents.isEmpty ? [SIMD4<Float>(0.2, 0.35, 0.92, 0.25)] : focus.continents
        return continents.map {
            center + simd_normalize(SIMD3($0.x, $0.y, $0.z)) * (radius * 1.12)
        }
    }

    private func focusLabelRadii(radius overrideRadius: Float? = nil) -> [Float] {
        guard let focus else { return [] }
        let count = max(1, focus.labelNames.count)
        let radius = overrideRadius ?? focusRadius()
        return Array(repeating: max(8, radius * 0.045), count: count)
    }

    private static func continents(for items: [FolderContentItem],
                                   fallbackSeed: String) -> [SIMD4<Float>] {
        let entries: [(index: Int, id: String, size: Float)]
        if items.isEmpty {
            entries = [(0, fallbackSeed, 1)]
        } else {
            entries = items.enumerated().map {
                ($0.offset, $0.element.url.absoluteString, Float(max(1, $0.element.sizeBytes)))
            }
        }
        let total = max(1, entries.reduce(Float(0)) { $0 + $1.size })
        let sorted = entries.sorted { $0.size > $1.size }
        var placedByIndex = Array(repeating: SIMD4<Float>(0, 0, 1, 0.22), count: entries.count)
        var placed: [(dir: SIMD3<Float>, radius: Float)] = []
        let golden: Float = .pi * (3 - sqrt(5))

        for entry in sorted {
            let fraction = max(0.015, min(0.55, entry.size / total))
            let angularRadius = min(0.56, max(0.16, 0.16 + sqrt(fraction) * 0.46))
            let h = stableHash64(entry.id)
            var bestDir = SIMD3<Float>(0, 0, 1)

            for attempt in 0..<96 {
                let t = (Float(attempt) + 0.5) / 96.0
                let jitter = Float((h >> UInt64(attempt % 24)) & 0xFF) / 255.0
                let y = 1.0 - 2.0 * fmod(t + jitter * 0.37, 1.0)
                let r = sqrt(max(0.001, 1 - y * y))
                let theta = Float(attempt) * golden + Float(h & 0xFFFF) / 65535.0 * 2 * .pi
                let dir = simd_normalize(SIMD3(cos(theta) * r, y, sin(theta) * r))
                let clear = placed.allSatisfy { existing in
                    let minAngle = angularRadius + existing.radius + 0.08
                    return dot(dir, existing.dir) < cos(minAngle)
                }
                bestDir = dir
                if clear { break }
            }

            placed.append((bestDir, angularRadius))
            placedByIndex[entry.index] = SIMD4(bestDir, angularRadius)
        }
        return placedByIndex
    }

    private func projectedNDC(for worldPosition: SIMD3<Float>) -> SIMD2<Float> {
        let clip = camera.viewProjection() * SIMD4(worldPosition, 1)
        guard abs(clip.w) > 0.0001 else { return .zero }
        return SIMD2(clip.x / clip.w, clip.y / clip.w)
    }

    private func drawOrbitalScene(in enc: MTLRenderCommandEncoder,
                                  time: Float,
                                  cursorWorld: SIMD3<Float>,
                                  includeLabels: Bool) {
        let starWorldXZ: SIMD3<Float>
        let starHeight:  Float
        if let s = universe.star {
            starWorldXZ = s.position
            starHeight  = max(56, s.radius * 0.78)
        } else {
            starWorldXZ = SIMD3(camera.screenSize.x * 0.5, 0, camera.screenSize.y * 0.5)
            starHeight  = 96
        }
        var camUni = CameraUniforms(
            viewProjection: camera.viewProjection(),
            cameraPos:      SIMD4(camera.position, 1),
            lightPos:       SIMD4(starWorldXZ.x, starHeight, starWorldXZ.z, 1))

        var motionUni = MotionUniforms(
            time:               time,
            motionAmount:       config.motionAmount,
            cursorPushStrength: 0,
            cursorEnabled:      0,
            cursorWorldPos:     SIMD4(cursorWorld, 1))

        let viewM    = Math.lookAt(eye: camera.position, target: camera.target, up: camera.up)
        let viewInv  = simd_inverse(viewM)
        let camRight = SIMD3(viewInv.columns.0.x, viewInv.columns.0.y, viewInv.columns.0.z)
        let camUp    = SIMD3(viewInv.columns.1.x, viewInv.columns.1.y, viewInv.columns.1.z)
        var labelUni = LabelUniforms(
            cameraRight: SIMD4(camRight, 0),
            cameraUp:    SIMD4(camUp, 0),
            worldHeight: 36.0,
            layerAspect: Float(LabelAtlas.layerWidth) / Float(LabelAtlas.layerHeight))

        backgroundRenderer.draw      (in: enc)
        starfieldRenderer.draw       (in: enc, screenSize: drawableSize, time: time)
        orbitRingRenderer.draw       (in: enc, camera: &camUni)
        blackHoleRenderer.draw       (in: enc, camera: &camUni,
                                      labelUniforms: &labelUni, motion: &motionUni)
        starRenderer.drawSurfaceAndHalo(in: enc, camera: &camUni,
                                        labelUniforms: &labelUni, motion: &motionUni)
        planetRenderer.draw          (in: enc, camera: &camUni, motion: &motionUni)
        asteroidRenderer.draw        (in: enc, camera: &camUni, motion: &motionUni)
        agentRenderer.draw           (in: enc, camera: &camUni, motion: &motionUni)
        starRenderer.drawLensFlare   (in: enc, camera: &camUni, motion: &motionUni,
                                      screenSize: drawableSize)
        if includeLabels {
            labelRenderer.draw       (in: enc, camera: &camUni,
                                      cameraRight: camRight, cameraUp: camUp)
        }
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        drawableSize = SIMD2(Float(size.width), Float(size.height))
    }

    func draw(in view: MTKView) {
        if drawableSize == .zero, view.drawableSize.width > 0 {
            mtkView(view, drawableSizeWillChange: view.drawableSize)
        }

        guard let drawable = view.currentDrawable,
              let passDesc = view.currentRenderPassDescriptor else { return }

        syncCameraToUniverse()
        let cursorWorld = camera.unprojectToGroundPlane(ndc: cursorNDC)

        // Advance orbits and push updated positions to the GPU.
        let now = CACurrentMediaTime()
        fpsFrameCount += 1
        let fpsElapsed = now - fpsWindowStart
        if fpsElapsed >= 1.0 {
            config.measuredFPS = Double(fpsFrameCount) / fpsElapsed
            fpsFrameCount = 0
            fpsWindowStart = now
        }
        let dt  = Float(now - lastFrameTime)
        let time = Float(now - startTime)
        lastFrameTime = now
        if focus == nil {
            universe.tick(deltaTime: dt)
            planetRenderer.updateBuffer(planets: universe.planets)
            agentRenderer.update(agents: config.showCodexAgents ? universe.agents : [])
            if now - lastLabelUploadTime >= 1.0 / 15.0 {
                lastLabelUploadTime = now
                updateOrbitalLabelPositions()
            }
        } else if var activeFocus = focus {
            planetRenderer.updateBuffer(planets: universe.planets.filter { $0.stableId != activeFocus.planet.stableId })
            asteroidRenderer.updateBuffer(asteroids: universe.asteroids)
            activeFocus.progress += (activeFocus.targetProgress - activeFocus.progress) * (1 - exp(-dt / 0.42))
            focus = activeFocus
            if activeFocus.targetProgress == 0, activeFocus.progress < 0.015 {
                focus = nil
                refreshFromUniverse()
            }
        }

        // Smooth zoom — expand the viewport just enough to keep the outermost shell on screen.
        if focus == nil, let outerR = universe.shellRadii.last {
            let screenHalfMin = Float(min(universe.screenSize.width,
                                          universe.screenSize.height)) * 0.5
            let margin: Float = 80
            targetZoomScale = max(1.0, (outerR + margin) / screenHalfMin)
        }
        // Exponential-decay lerp with a ~1.5 s time constant.
        let lerpRate = 1 - exp(-dt / 1.5)
        currentZoomScale += (targetZoomScale - currentZoomScale) * lerpRate
        camera.zoomScale = currentZoomScale

        passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0.01, green: 0.01, blue: 0.04, alpha: 1)
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.depthAttachment.clearDepth     = 1.0
        passDesc.depthAttachment.loadAction     = .clear

        guard let cmd = queue.makeCommandBuffer() else { return }
        backgroundRenderer.updateCacheIfNeeded(
            commandBuffer: cmd,
            screenSize: drawableSize,
            time: time,
            seed: universe.seed)

        guard let enc = cmd.makeRenderCommandEncoder(descriptor: passDesc) else { return }

        if focus != nil {
            let transitionProgress = smootherStep(focus?.progress ?? 1)
            var (focusCamUni, focusRight, focusUp, focusCenter, planetRadius) = focusScene()
            var focusMotionUni = MotionUniforms(
                time: time,
                motionAmount: 0,
                cursorPushStrength: 0,
                cursorEnabled: 0,
                cursorWorldPos: SIMD4(0, 0, 0, 1))
            labelRenderer.updateLabelPositions(
                positions: focusLabelPositions(center: focusCenter, radius: planetRadius),
                radii: focusLabelRadii(radius: planetRadius))

            if transitionProgress < 0.985 {
                drawOrbitalScene(in: enc, time: time, cursorWorld: cursorWorld, includeLabels: false)
            } else {
                backgroundRenderer.draw(in: enc)
                starfieldRenderer.draw(in: enc, screenSize: drawableSize, time: time)
            }
            if let planet = focusedPlanet(center: focusCenter, radius: planetRadius) {
                planetRenderer.drawFocused(
                    planet,
                    continents: focus?.continents ?? [],
                    continentBlend: transitionProgress > 0.04 ? 1 : 0,
                    in: enc,
                    camera: &focusCamUni,
                    motion: &focusMotionUni)
            }
            if (focus?.progress ?? 0) > 0.58 {
                labelRenderer.draw(in: enc, camera: &focusCamUni,
                                   cameraRight: focusRight, cameraUp: focusUp)
            }
            enc.endEncoding()
            cmd.present(drawable)
            cmd.commit()
            return
        }

        drawOrbitalScene(in: enc, time: time, cursorWorld: cursorWorld, includeLabels: true)

        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}
