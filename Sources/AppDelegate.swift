// Layer 3 — App: wires Engine + Data + Rendering + UI together at launch.
// All desktop scanning is dispatched off the main thread.
import AppKit
import Combine
import Metal

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var wallpaperControllers: [WallpaperWindowController] = []
    private var menuBar:              MenuBarController?
    private var watcher:              DesktopWatcher?
    private var sourceWatcherLive = false
    private var positionTimer:        Timer?
    private var network:              NetworkMonitor?
    private var dashboard:            DashboardWindowController?
    private let codexMonitor = CodexActivityMonitor()
    private var codexObservation: AnyCancellable?
    private var fpsObservation: AnyCancellable?

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

            // A renderer owns mutable frame buffers and timing state. Keep one
            // renderer on the primary screen until each display has an isolated
            // renderer; sharing one across displays can double-tick the universe.
            if let screen = NSScreen.main ?? NSScreen.screens.first {
                let ctrl = WallpaperWindowController.make(
                    covering: screen, device: device, renderer: renderer)
                ctrl.setGamifiedMode(config.gamifiedMode)
                ctrl.setTargetFPS(config.targetFPS)
                wallpaperControllers.append(ctrl)
            }

            configureDashboard()

            menuBar = MenuBarController(
                config: config,
                onOpenDashboard: { [weak self] in self?.dashboard?.present() },
                onQuit: { NSApplication.shared.terminate(nil) },
                onResetAndRetry: { [weak self] in self?.refreshFromSource() },
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
            refreshFromSource()

            codexObservation = codexMonitor.$snapshot.sink { [weak self] snapshot in
                Task { @MainActor in self?.applyCodex(snapshot) }
            }
            fpsObservation = config.$measuredFPS.sink { [weak self] value in
                Task { @MainActor in self?.dashboard?.model.setMeasuredFPS(value) }
            }
            codexMonitor.start()

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

            restartSourceWatcher()

            positionTimer = Timer.scheduledTimer(
                timeInterval: Self.positionPollInterval, target: self,
                selector: #selector(pollPositions),
                userInfo: nil, repeats: true)

            dashboard?.present()

        } catch {
            showFatalAlert(error.localizedDescription)
        }
    }

    @objc private func pollPositions() {
        guard isDesktopSource else { return }
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
        let work = DispatchWorkItem { [weak self] in self?.refreshFromSource() }
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
    private func refreshFromSource() {
        desktopScanGeneration += 1
        let generation = desktopScanGeneration
        let screenSize = NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)
        let rootURL = config.sourceURL
        let maxWorlds = config.maxWorlds
        let useFinderPositions = rootURL.standardizedFileURL == DesktopScanner.desktopURL.standardizedFileURL

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let positions = useFinderPositions
                ? FinderIconPositions.fetch()
                : FinderFetchResult(positions: [:], errorCode: 0, errorMessage: "")
            let quickSnap = DesktopScanner.snapshot(
                rootURL: rootURL,
                positionResult: positions,
                withSizes: false,
                maxFolders: maxWorlds)

            Task { @MainActor in
                guard let self, generation == self.desktopScanGeneration else { return }
                self.apply(quickSnap, screenSize: screenSize)
            }

            DispatchQueue.global(qos: .background).async { [weak self] in
                let deepSnap = DesktopScanner.snapshot(
                    rootURL: rootURL,
                    positionResult: positions,
                    withSizes: true,
                    maxFolders: maxWorlds)
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
        if isDesktopSource && !force && positionsMissing && desktopNotEmpty && universe.usingFinderPositions {
            menuBar?.panelVC.refreshLabels()
            return
        }

        universe.update(folders: snap.folders, files: snap.files, screenSize: screenSize)
        universe.updateAgents(from: codexMonitor.snapshot.agents)
        renderer.refreshFromUniverse()

        config.planetCount    = universe.planets.count
        config.asteroidCount  = universe.asteroids.count
        config.positionSource = universe.usingFinderPositions ? "Finder" : "orbital"
        config.filesystemLive = sourceWatcherLive
        config.projectNames   = universe.planets.map(\.name)
        dashboard?.model.setFilesystemState(
            sourceWatcherLive ? .live : .attention,
            detail: sourceWatcherLive
                ? "Watching \(config.sourceURL.lastPathComponent)"
                : "Loaded once · live updates unavailable")
        dashboard?.model.updateMetrics(
            folders: universe.planets.count,
            files: universe.asteroids.count,
            activeAgents: config.activeAgentCount)
        menuBar?.panelVC.refreshLabels()
    }

    private var isDesktopSource: Bool {
        config.sourceURL.standardizedFileURL == DesktopScanner.desktopURL.standardizedFileURL
    }

    private func restartSourceWatcher() {
        watcher?.stop()
        sourceWatcherLive = false
        watcher = DesktopWatcher(url: config.sourceURL) { [weak self] in
            guard let self, !self.desktopWorkPaused else { return }
            self.refreshFromSource()
        }
        sourceWatcherLive = watcher?.start() ?? false
        config.filesystemLive = sourceWatcherLive
        if !sourceWatcherLive {
            dashboard?.model.setFilesystemState(
                .attention,
                detail: "Loaded once · live updates unavailable")
        }
    }

    /// Re-roots the universe without restarting the app. Dashboard folder selection
    /// flows through this method so the watcher and in-flight scan generation change
    /// atomically from the user's point of view.
    func setSourceURL(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }
        desktopScanGeneration += 1
        deferredSnap = nil
        config.sourceURL = url.standardizedFileURL
        config.filesystemLive = false
        dashboard?.model.setRootURL(config.sourceURL)
        dashboard?.model.setFilesystemState(.connecting, detail: "Indexing project worlds…")
        restartSourceWatcher()
        refreshFromSource()
        applyCodex(codexMonitor.snapshot)
    }

    private func applyCodex(_ snapshot: CodexActivitySnapshot) {
        guard let universe, let renderer else { return }
        universe.updateAgents(from: snapshot.agents)
        renderer.refreshAgents()

        config.activeAgentCount = snapshot.activeCount
        config.codexLive = snapshot.availability == .available || snapshot.availability == .partial
        config.agentSummaries = snapshot.activeAgents.map(\.displayName)
        dashboard?.model.updateMetrics(
            folders: config.planetCount,
            files: config.asteroidCount,
            activeAgents: snapshot.activeCount)
        dashboard?.model.setAgentNames(snapshot.activeAgents.map(\.displayName))

        switch snapshot.availability {
        case .available:
            let detail = snapshot.activeCount == 0
                ? "Ready · start a Codex task to launch a ship"
                : "\(snapshot.activeCount) live · local metadata only"
            dashboard?.model.setCodexState(.live, detail: detail)
        case .partial:
            dashboard?.model.setCodexState(
                .attention,
                detail: "Live with partial local metadata")
        case .sessionsDirectoryMissing:
            dashboard?.model.setCodexState(.disconnected, detail: "No local Codex sessions found")
        case .unavailable:
            dashboard?.model.setCodexState(.attention, detail: "Local Codex activity is unavailable")
        case .notStarted:
            dashboard?.model.setCodexState(.connecting, detail: "Reading local activity metadata…")
        }
    }

    private func configureDashboard() {
        var callbacks = DashboardCallbacks()
        callbacks.onSourceChanged = { [weak self] url in self?.setSourceURL(url) }
        callbacks.onEnterUniverse = { [weak self] in self?.setUniverseVisible(true) }
        callbacks.onExitUniverse = { [weak self] in self?.setUniverseVisible(false) }
        callbacks.onPrivacyModeChanged = { [weak self] enabled in
            self?.config.privacyMode = enabled
        }
        callbacks.onShowAgentsChanged = { [weak self] enabled in
            self?.config.showCodexAgents = enabled
            self?.renderer?.refreshFromUniverse()
        }
        callbacks.onGamifiedModeChanged = { [weak self] enabled in
            self?.setGamifiedMode(enabled)
        }
        callbacks.onDemoModeChanged = { [weak self] enabled in
            self?.applyDemoMode(enabled)
        }
        callbacks.onAppearanceChanged = { [weak self] preset in
            self?.applyAppearance(preset)
        }
        callbacks.onPerformanceModeChanged = { [weak self] mode in
            self?.setTargetFPS(mode == .fidelity ? 60 : 30)
        }
        callbacks.onMotionAmountChanged = { [weak self] amount in
            self?.config.motionAmount = Float(amount * 2)
        }
        callbacks.onGlowAmountChanged = { [weak self] amount in
            guard let self else { return }
            self.config.starCoronaScale = Float(0.55 + amount * 1.25)
            self.config.starIntensity = Float(0.55 + amount * 0.45)
            self.scheduleStarRefresh()
        }
        callbacks.onWorldLimitChanged = { [weak self] limit in
            guard let self else { return }
            self.config.maxWorlds = limit
            self.dashboard?.model.setFilesystemState(.connecting, detail: "Rebuilding project orbits…")
            self.refreshFromSource()
        }

        let model = DashboardModel(
            rootURL: config.sourceURL,
            isUniverseRunning: true,
            filesystemState: .connecting,
            codexState: .connecting,
            filesystemDetail: "Indexing project worlds…",
            codexDetail: "Reading local activity metadata…",
            privacyMode: config.privacyMode,
            showAgents: config.showCodexAgents,
            gamifiedMode: config.gamifiedMode,
            appearance: .natural,
            performanceMode: config.targetFPS >= 60 ? .fidelity : .adaptive,
            motionAmount: Double(config.motionAmount) * 0.5,
            glowAmount: 0.72,
            worldLimit: config.maxWorlds,
            measuredFPS: config.measuredFPS,
            callbacks: callbacks)
        dashboard = DashboardWindowController(model: model)
    }

    private func applyDemoMode(_ enabled: Bool) {
        // Demo Mode is presentation-oriented, not synthetic: it hides full paths,
        // applies a cinematic treatment, and creates a capture-safe curtain on the
        // main display while retaining real filesystem and Codex telemetry streams.
        if enabled {
            config.privacyMode = true
            dashboard?.model.setPrivacyMode(true, notify: false)
            dashboard?.model.setAppearance(.cinematic, notify: true)
        }
        for controller in wallpaperControllers {
            controller.setDemoPresentationMode(enabled)
        }
        dashboard?.setDemoPresentationMode(enabled)
    }

    private func applyAppearance(_ preset: DashboardAppearancePreset) {
        switch preset {
        case .natural:
            config.starIntensity = 0.85
            config.starCoronaScale = 1.0
            config.starFlareDensity = 0.30
        case .cinematic:
            config.starIntensity = 1.0
            config.starCoronaScale = 1.42
            config.starFlareDensity = 0.42
        case .minimal:
            config.starIntensity = 0.68
            config.starCoronaScale = 0.72
            config.starFlareDensity = 0.10
        }
        scheduleStarRefresh()
    }

    private func setGamifiedMode(_ on: Bool) {
        config.gamifiedMode = on
        for ctrl in wallpaperControllers { ctrl.setGamifiedMode(on) }
    }

    func setUniverseVisible(_ visible: Bool) {
        config.universeVisible = visible
        for ctrl in wallpaperControllers { ctrl.setUniverseVisible(visible) }
    }

    func setTargetFPS(_ fps: Int) {
        config.targetFPS = fps
        for ctrl in wallpaperControllers { ctrl.setTargetFPS(config.targetFPS) }
    }

    private func refreshStar() {
        guard let universe = universe, let renderer = renderer else { return }
        let screenSize = NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)
        let browser    = DefaultBrowser.current()
        let online     = network?.isOnline ?? true
        universe.updateStar(
            browser: browser,
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

    func applicationWillTerminate(_ notification: Notification) {
        codexMonitor.stop()
        codexObservation?.cancel()
        fpsObservation?.cancel()
        watcher?.stop()
        positionTimer?.invalidate()
    }
}
