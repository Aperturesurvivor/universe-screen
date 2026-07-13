# Universe Screen — Project Roadmap

> Living source of truth for the Gamified Desktop project. Update phase status as work lands.

---

## 1. Vision

A fully immersive, real-time gamified desktop that turns macOS into a living personal solar system.

- Every folder on the desktop becomes a unique procedural 3D planet (Sebastian Lague style).
- The Internet is the glowing central star; pulses & beams reflect real network activity.
- Active processes & AI agents appear as spaceships flying between planets and the star.
- Driven by real-time data (FSEvents, NWPathMonitor, NSWorkspace), procedural graphics, and gentle kinematic motion (no real gravity — planets stay in roughly fixed orbital slots).

**Feel target:** cinematic, premium-screensaver / high-end indie sci-fi quality. 60–120 fps on all M-series Macs.

---

## 2. Final Feature Set

| Feature | Description |
|---|---|
| **Procedural planets** | Sebastian Lague style: layered noise, vertex displacement, oceans, biomes, atmospheric scattering, dynamic star lighting. |
| **Folder → Planet** | Every Desktop folder = a planet. Size = real storage usage. Biome themed by folder type (Documents = lush, Downloads = rocky, etc.). |
| **Internet Star** | Central reactive star. Color & pulse based on `NWPathMonitor`. Shoots data beams during network activity. |
| **Spaceship agents** | Stylized probes for filesystem/process activity. Per-app colors (e.g. blue for Claude Code). Glowing thrusters + trails, dock on planets. |
| **Kinematic motion** | Planets occupy fixed orbital slots and exhibit only gentle motion: slow rotation around the star, slight axial bob/wobble, self-spin, and a small temporary disturbance when the cursor passes near. **No N-body gravity.** Planets stay in roughly the same place at all times. |
| **Gamified Desktop Mode** | Toggle: hide native Finder icons, replace with planets. One-click restore. |
| **Click interaction** | Click planet → opens folder. Optional smooth camera zoom into surface (sub-folders = surface features). |
| **Controls** | SwiftUI menu-bar popover: gravity, sim speed, planet count, toggles. |
| **Performance mode** | Auto-throttle / pause when on battery or Mac is idle. |
| **Multi-monitor** | Each screen gets its own solar system (or mirrored). |

---

## 3. Architecture (3-Layer System)

| Layer | Files | Responsibility |
|---|---|---|
| **1. Simulation / Data** | `Sources/Physics/` | Metal compute kernels: kinematic planet motion (fixed orbital slots + drift), procedural planet generation. Filesystem & network monitors. |
| **2. Rendering** | `Sources/Rendering/` | Full-screen Metal view at desktop window level. 3D scene draw (planets, star, ships, particles, post-fx). |
| **3. UI / Application** | `Sources/UI/`, `AppDelegate`, `main` | SwiftUI menu-bar app + popover. Window-level management. Toggles. Eventually WidgetKit. |

Single lightweight menu-bar app (`LSUIElement = YES`). No main window.

---

## 4. Build Phases

### ✅ Phase 0 — MVP (shipped)
2D N-body gravity wallpaper. AppKit menu-bar control panel. Cursor as gravity well. Metal compute shader. Desktop-level borderless window.
- Files: `gravity.metal`, `render.metal`, `PhysicsEngine.swift`, `WallpaperRenderer.swift`, `WallpaperWindowController.swift`, `MenuBarController.swift`, `ControlPanelViewController.swift`, `SimulationConfig.swift`, `AppDelegate.swift`, `main.swift`

### ✅ Phase 1 — 2D → 3D foundation (shipped)
Switch to a 3D Metal pipeline. Camera, perspective projection, depth buffer, MSAA. Render planets as flat-shaded UV spheres orbiting the origin. Convert simulation to 3D (`float3` positions/velocities). Cursor unprojected to orbital plane.

Adds: `Camera.swift`, `SphereMesh.swift`, `MathHelpers.swift`. Rewrites: shaders + `PhysicsEngine` structs + `WallpaperRenderer`.

> ℹ️ The N-body gravity kernel currently driving Phase 1 is **scaffolding only** — it's a convenient way to verify the 3D rendering pipeline. It will be replaced in Phase 2 by a kinematic "fixed orbital slot + idle drift + cursor disturbance" kernel. No real gravity in the final product.

### ✅ Phase 2 — Folder → Planet mapping (+ kinematic motion model) (shipped)
- `DesktopScanner` enumerates `~/Desktop` (folders only), with background recursive size computation (200k-entry safety cap).
- `Biome.infer(from:)` maps well-known folders (Documents, Downloads, Pictures, …) and falls back to a stable per-name choice.
- `PlanetSystem` derives a **fixed orbital slot** per folder from a deterministic FNV-1a hash of the name (angle, radius, y, phase) and a log-scaled visual radius from byte size.
- Motion is now purely kinematic, baked into the **vertex shader**: `slotCenter + idle wobble + cursor disturbance`. The N-body compute kernel and `gravity.metal` were removed.
- `DesktopWatcher` (FSEvents) re-scans the desktop on changes (1 s coalescing).
- `ClickHandler` global `.leftMouseDown` monitor → unproject NDC → ray-sphere intersection → `NSWorkspace.shared.open(url)`.
- Control panel sliders updated: Motion · Cursor push · Cursor toggle, plus a planet-count status line.

> Files added: `Data/DesktopFolders.swift`, `Simulation/PlanetSystem.swift`, `UI/ClickHandler.swift`. Removed: `Physics/`.

### ✅ Phase 3 — Procedural planets, Finder positions, labels (shipped)
- **Procedural planets**: Stefan Gustavson 3D simplex noise + 5-octave fbm in the vertex shader. Per-vertex radial displacement up to ±16% of planet radius, biased toward oceans. Sphere tessellation bumped to 64×96 for smooth surfaces.
- **Biome shading**: per-biome 6-stop palette (deep water → shallow → beach → lowland → highland → peak) blended by elevation. Specular highlight only on water; rim atmosphere glow over everything. Flat-shaded normals via `dfdx/dfdy` give the classic Lague faceted-terrain look on land while staying smooth on oceans.
- **Folder positions**: `FinderIconPositions` reads icon coords via AppleScript (`NSAppleEventsUsageDescription` triggers the one-time automation prompt). Coords mapped to the world y=0 plane: Finder x → world x, Finder y → world z (flipped for camera). Hash fallback if Finder access is denied.
- **Labels**: `LabelAtlas` pre-renders each name with Core Graphics into a slice of a `texture2d_array`; `labels.metal` draws billboarded quads above each planet, sampled by `instance_id`. Per-instance `widthFractions` so short names don't get squashed.

> Files added: `Data/FolderPositions.swift`, `Rendering/LabelAtlas.swift`, `Rendering/labels.metal`. `WallpaperRenderer` is now `@MainActor` (Core Graphics requires it).

### ✅ Phase 4 — Engine architecture + Gamified Mode (shipped)
- **Engine layer**: `CelestialBody` protocol + concrete `PlanetBody` / `AsteroidBody`. `Universe` orchestrator owns typed arrays per kind (one MTLBuffer per kind). Stub kinds for `star`, `blackHole`, `warpGate`, `station`.
- **Seed system**: `Seed` (UInt64) + xorshift64 `SeededRandom`, FNV-1a 64-bit `stableHash64`. Seed persists in UserDefaults; per-body RNG seeded from `(universeSeed + stableHash(bodyId))`. Shareable display string `u-XXXX…`.
- **Renderer split**: `UniverseRenderer` (top-level MTKViewDelegate) dispatches to `PlanetRenderer`, `AsteroidRenderer`, `LabelRenderer`. Each per-kind renderer owns its pipeline + instance buffer. Shared `noise.h` for simplex / fbm.
- **Asteroids**: new shader (heavier displacement, 3 rock palettes, flat shading via `dfdx/dfdy`). Backed by `DesktopFilesScanner` for non-folder desktop items. Click → `NSWorkspace.shared.open(url)`.
- **LabelRenderer body-agnostic**: takes `[(position, radius, name)]` rather than coupling to `PlanetGPU`.
- **Gamified Mode toggle**: checkbox in popover. ON ⇒ window level promoted from `kCGDesktopWindowLevelKey` to `kCGDesktopIconWindowLevelKey + 1` so the window covers Finder icons. No Finder mutation, no crash safety needed.
- **Migration**: removed `Simulation/PlanetSystem.swift`, `Rendering/WallpaperRenderer.swift`, the `Simulation/` directory.

> Files added: `Engine/Seed.swift`, `Engine/CelestialBody.swift`, `Engine/Universe.swift`, `Bodies/PlanetBody.swift`, `Bodies/AsteroidBody.swift`, `Data/DesktopFiles.swift`, `Rendering/SharedUniforms.swift`, `Rendering/PlanetRenderer.swift`, `Rendering/AsteroidRenderer.swift`, `Rendering/LabelRenderer.swift`, `Rendering/UniverseRenderer.swift`, `Rendering/asteroid.metal`, `Rendering/noise.h`.

### ✅ Phase 5 — Internet Star + Starfield (shipped)
- **StarBody** + **StarGPU** (64-byte stride). One per universe, themed by default browser.
- **DefaultBrowser**: `NSWorkspace.shared.urlForApplication(toOpen:)` against `https://example.com`. Bundle-id → palette table covering Safari, Chrome, Firefox, Edge, Brave, Opera, Vivaldi, Arc, DuckDuckGo, with a generic warm-white fallback.
- **NetworkMonitor**: `NWPathMonitor` wrapper. `isOnline` flips drive `pulseRate` (1.4 ↔ 0.4 Hz) and `brightness` (1.0 ↔ 0.45).
- **star.metal**: billboarded glow with bright core + exponential halo + 4-pointed light rays + slow pulse modulated by `time × pulseRate`. Additive blend. Depth test on, depth write off (planets occlude the star where they overlap).
- **starfield.metal**: 700 procedural NDC-space dots, sized & brightnessed via biased `pow()` curves so dim stars dominate and rare bright ones pop. Twinkle from `sin(time + perStarPhase)`. Generated once per seed.
- **StarRenderer / StarfieldRenderer**: each owns its pipeline; `UniverseRenderer.draw` runs `starfield → star → planets → asteroids → labels`.
- **Click**: clicking the star opens the default browser (`NSWorkspace.shared.open(actionURL)`).

### Phase 6 — Special bodies
- Trash → black hole.
- Mail → warp gate.
- Messages → broadcasting station.
- Click visual feedback (pulse outward).

### Phase 5 — Spaceship agents
- Low-poly probe meshes, instanced rendering.
- A→B path animation with thrust trails.
- `DispatchSource` for filesystem writes; `NSWorkspace.runningApplications` KVO for process spawn/exit.
- Per-app colors (Claude Code = blue, etc.).

### Phase 6 — Gamified Desktop Mode
- Toggle hides Finder desktop icons (`defaults write com.apple.finder CreateDesktop -bool false; killall Finder`) + restore on exit.
- Window-level promotion above desktop icons (or replace them entirely).

### Phase 7 — Polish
- SwiftUI rewrite of popover.
- Battery-aware throttling (`IOPSCopyPowerSourcesInfo`) + idle detection.
- Multi-monitor independent scenes.
- First-launch onboarding.
- `.dmg` packaging + notarization.

---

## 5. Visual Style (locked)

- **Planets:** Sebastian Lague procedural — vertex displacement, multi-octave noise, ocean specular, atmospheric glow, dynamic star lighting.
- **Star:** Bright volumetric reactive glow, lens flares, particle corona.
- **Spaceships:** Low-poly stylized sci-fi probes, glowing thrusters, faint trails.
- **Background:** Deep space with subtle stars, nebulae, parallax.
- **Color palette:** Dynamic, reacts to macOS light/dark mode and internet status.

---

## 6. Performance Targets

- 60–120 fps on all M-series Macs (incl. base M1/M2).
- Negligible battery impact when idle (auto-pause).
- Coexists with normal Finder; toggleable any time.

---

## 7. Build & Run

```zsh
cd GravityWallpaper
./bootstrap.sh        # installs xcodegen if needed, generates .xcodeproj, opens Xcode
# then ⌘R in Xcode
```

Or from CLI:
```zsh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project GravityWallpaper.xcodeproj -scheme GravityWallpaper -configuration Debug build
```

---

## 8. Conventions

- Metal struct ↔ Swift struct: byte layouts must match exactly. Document offsets in comments. Use `MemoryLayout<T>.stride` (not `.size`) when writing buffers.
- 3D world units: roughly "tens of units" for orbital radii. Star at origin, camera at ~(0, 60, 180) looking at origin.
- Coordinate convention: right-handed, +Y up. Camera looks down -Z.
- Threading: physics/render on main; AppKit-isolated UI classes annotated `@MainActor` (Swift 6 strict concurrency is on).
