// Layer 3 — App: wires Engine + Data + Rendering + UI together at launch.
// All desktop scanning is dispatched off the main thread.
import AppKit
import Metal

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var wallpaperControllers: [WallpaperWindowController] = []
    private var menuBar:              MenuBarController?
    private var watcher:              DesktopWatcher?
    private var positionTimer:        Timer?
    private var network:              NetworkMonitor?

    private let config        = SimulationConfig()
    private var universe:     Universe?
    private var renderer:     UniverseRenderer?

    /// While the control-panel popover is open we suspend desktop polling and
    /// FSEvents-triggered scans so the main run loop stays free for slider
    /// drags and the next click on the status item.
    private var desktopWorkPaused = false
    /// In-flight scan results that completed while the panel was open get
    /// stashed here and replayed on close so the universe doesn't visibly
    /// rebuild under the user's cursor.
    private var deferredSnap: (DesktopSnapshot, CGSize)?
    private var starRefreshScheduled = false
    private var positionPollInFlight = false

    /// Pending full-rebuild after a seed slider drag. Reset on each tick so we
    /// only re-scan the desktop after the user pauses scrubbing.
    private var pendingSeedRebuild: DispatchWorkItem?
    private var desktopScanGeneration = 0

    private static let positionPollInterval:  TimeInterval = 1.5

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return showFatalAlert("This Mac doesn't support Metal.")
        }

        do {
            let seed     = Seed.loadOrGenerate()
            let universe = Universe(seed: seed)
            let renderer = try UniverseRenderer(device: device, universe: universe, config: config)
            self.universe = universe
            self.renderer = renderer

            for screen in NSScreen.screens {
                let ctrl = WallpaperWindowController.make(
                    covering: screen, device: device, renderer: renderer)
                wallpaperControllers.append(ctrl)
            }

            menuBar = MenuBarController(
                config: config,
                onQuit: { NSApplication.shared.terminate(nil) },
                onResetAndRetry: { [weak self] in self?.refreshFromDesktop() },
                onGamifiedToggle: { [weak self] on in self?.setGamifiedMode(on) },
                onStarChange: { [weak self] in self?.scheduleStarRefresh() },
                onSeedChange: { [weak self] value in self?.applySeed(value) })
            menuBar?.panelVC.setInitialSeed(seed)
            // Force the panel's view hierarchy to build now so the first
            // status-bar click doesn't pay the lazy-load cost.
            _ = menuBar?.panelVC.view
            // Pause main-thread-heavy desktop work while the panel is open so
            // slider drags stay smooth and the next click reopens instantly.
            menuBar?.onPanelWillShow = { [weak self] in self?.desktopWorkPaused = true }
            menuBar?.onPanelDidClose = { [weak self] in
                guard let self else { return }
                self.desktopWorkPaused = false
                if let (snap, sz) = self.deferredSnap {
                    self.deferredSnap = nil
                    self.apply(snap, screenSize: sz)
                }
            }

            // Initial star + scan + live updates
            refreshStar()
            refreshFromDesktop()

            network = NetworkMonitor()
            network?.start { [weak self] in
                guard let self else { return }
                if let net = self.network {
                    self.config.applyNetworkScores(
                        temperature:  net.temperatureScore,
                        intensity:    net.intensityScore,
                        stability:    net.stabilityScore,
                        coronaScale:  net.coronaScaleScore,
                        flareDensity: net.flareDensityScore)
                }
                self.refreshStar()
                self.menuBar?.panelVC.refreshLabels()
            }

            watcher = DesktopWatcher { [weak self] in
                guard let self, !self.desktopWorkPaused else { return }
                self.refreshFromDesktop()
            }
            watcher?.start()

            positionTimer = Timer.scheduledTimer(
                timeInterval: Self.positionPollInterval, target: self,
                selector: #selector(pollPositions),
                userInfo: nil, repeats: true)

        } catch {
            showFatalAlert(error.localizedDescription)
        }
    }

    @objc private func pollPositions() {
        if desktopWorkPaused || positionPollInFlight { return }
        positionPollInFlight = true
        // AppleScript on background; cheap renderer refresh on main.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = FinderIconPositions.fetch()
            Task { @MainActor in
                guard let self else { return }
                self.positionPollInFlight = false
                guard !self.desktopWorkPaused else { return }
                FinderFetchState.record(result)
                guard let universe = self.universe else { return }
                if universe.updatePositions(result.positions) {
                    self.renderer?.refreshPositionsOnly()
                }
            }
        }
    }

    /// Apply a new seed from the seed slider. Updates the universe + cheap
    /// renderers immediately so the background and starfield re-roll while the
    /// user is still scrubbing, and debounces the heavier full-body rebuild
    /// (planets/asteroids re-rolling biomes) until the user pauses.
    private func applySeed(_ value: UInt64) {
        guard let universe = universe else { return }
        let newSeed = Seed(value: value)
        universe.setSeed(newSeed)
        menuBar?.panelVC.seedDisplay = newSeed.displayString
        menuBar?.panelVC.refreshLabels()

        // Cheap visual refresh — star + background + starfield read seed live.
        refreshStar()
        renderer?.refreshFromUniverse()

        pendingSeedRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshFromDesktop() }
        pendingSeedRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30, execute: work)
    }

    /// Coalesces rapid star-slider drags so we run `refreshStar` at most once
    /// per main-runloop tick instead of for every continuous slider event.
    private func scheduleStarRefresh() {
        if starRefreshScheduled { return }
        starRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.starRefreshScheduled = false
            self.refreshStar()
        }
    }

    /// Two-phase scan:
    ///  • Quick scan (no recursive sizes) → instant universe update
    ///  • Deep scan (real sizes) → second update once sizes resolve
    /// Both phases run on a background queue; main is only touched to apply results.
    private func refreshFromDesktop() {
        desktopScanGeneration += 1
        let generation = desktopScanGeneration
        let screenSize = NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let positions = FinderIconPositions.fetch()
            let quickSnap = DesktopScanner.snapshot(positionResult: positions, withSizes: false)

            Task { @MainActor in
                guard let self, generation == self.desktopScanGeneration else { return }
                self.apply(quickSnap, screenSize: screenSize)
            }

            DispatchQueue.global(qos: .background).async { [weak self] in
                let deepSnap = DesktopScanner.snapshot(positionResult: positions, withSizes: true)
                Task { @MainActor in
                    guard let self, generation == self.desktopScanGeneration else { return }
                    self.apply(deepSnap, screenSize: screenSize)
                }
            }
        }
    }

    @MainActor
    private func apply(_ snap: DesktopSnapshot, screenSize: CGSize, force: Bool = false) {
        // If a scan completes while the panel is open, hold the result so we
        // don't visibly rebuild the universe under the user. Newer snaps
        // overwrite older ones — only the latest matters at replay time.
        if desktopWorkPaused {
            deferredSnap = (snap, screenSize)
            return
        }

        FinderFetchState.record(snap.positionResult)
        guard let universe = universe, let renderer = renderer else { return }

        // Defensive: if AppleScript came back with no positions but the desktop
        // still has items and we already had positioned bodies, treat it as a
        // transient Finder/AppleEvents failure. Rebuilding here would flip
        // `usingFinderPositions` to false and snap every body to fallback
        // layout — exactly the "everything reset" symptom.
        // `force` bypasses this when we know the folder set actually changed.
        let positionsMissing = snap.positionResult.positions.isEmpty
        let desktopNotEmpty  = !snap.folders.isEmpty || !snap.files.isEmpty
        if !force && positionsMissing && desktopNotEmpty && universe.usingFinderPositions {
            menuBar?.panelVC.refreshLabels()
            return
        }

        universe.update(folders: snap.folders, files: snap.files, screenSize: screenSize)
        renderer.refreshFromUniverse()

        config.planetCount    = universe.planets.count
        config.asteroidCount  = universe.asteroids.count
        config.positionSource = universe.usingFinderPositions ? "Finder" : "auto"
        menuBar?.panelVC.refreshLabels()
    }

    private func setGamifiedMode(_ on: Bool) {
        for ctrl in wallpaperControllers { ctrl.setGamifiedMode(on) }
    }

    private func refreshStar() {
        guard let universe = universe, let renderer = renderer else { return }
        let screenSize = NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)
        let browser    = DefaultBrowser.current()
        let online     = network?.isOnline ?? true
        universe.updateStar(browser: browser,
                            isOnline:     online,
                            temperature:  config.starTemperature,
                            intensity:    config.starIntensity,
                            stability:    config.starStability,
                            coronaScale:  config.starCoronaScale,
                            flareDensity: config.starFlareDensity,
                            screenSize:   screenSize)
        renderer.refreshStar()
    }

    private func showFatalAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText     = "Universe Screen"
        alert.informativeText = message
        alert.runModal()
        NSApplication.shared.terminate(nil)
    }
}
