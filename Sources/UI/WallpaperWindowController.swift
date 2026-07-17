// Layer 3 — UI: borderless window. Window level switches between desktop-wallpaper
// (default) and above-icons (Gamified Mode). Window receives clicks itself so
// it can both hit-test our planets AND absorb clicks meant for Finder icons.
import AppKit
import MetalKit
import CoreGraphics
import simd

@MainActor
final class WallpaperWindowController: NSWindowController {

    private let renderer: UniverseRenderer
    private let mtkView:  WallpaperMTKView
    private weak var screenRef: NSScreen?
    private var mouseMonitor: Any?
    private var gamifiedMode = false
    private var demoPresentationMode = false

    static let desktopLevelKey:     Int = 2     // kCGDesktopWindowLevelKey
    static let desktopIconLevelKey: Int = 18    // kCGDesktopIconWindowLevelKey

    private init(window: NSWindow, mtkView: WallpaperMTKView,
                 renderer: UniverseRenderer, screen: NSScreen) {
        self.mtkView   = mtkView
        self.renderer  = renderer
        self.screenRef = screen
        super.init(window: window)
    }
    required init?(coder: NSCoder) { fatalError("storyboards not used") }

    static func make(covering screen: NSScreen,
                     device: MTLDevice,
                     renderer: UniverseRenderer) -> WallpaperWindowController {

        let win = NonActivatingWindow(
            contentRect: screen.frame,
            styleMask:   .borderless,
            backing:     .buffered,
            defer:       false,
            screen:      screen)
        win.level              = Self.windowLevel(gamified: false)
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        win.isOpaque           = true
        win.hasShadow          = false
        win.backgroundColor    = .black
        // Receive mouse events so we can absorb them in Gamified Mode and
        // hit-test our planets in any mode. Higher-level windows (apps, Finder
        // icons when not gamified) get first crack at clicks naturally.
        win.ignoresMouseEvents = false

        let localBounds = CGRect(origin: .zero, size: screen.frame.size)
        let view = WallpaperMTKView(frame: localBounds, device: device)
        view.delegate                 = renderer
        view.preferredFramesPerSecond = 30
        view.enableSetNeedsDisplay    = false
        view.isPaused                 = false
        view.colorPixelFormat         = .bgra8Unorm
        view.depthStencilPixelFormat  = UniverseRenderer.depthFormat
        view.sampleCount              = UniverseRenderer.sampleCount
        view.framebufferOnly          = true
        win.contentView               = view

        win.orderFront(nil)

        let ctrl = WallpaperWindowController(window: win, mtkView: view,
                                             renderer: renderer, screen: screen)
        view.onClick = { [weak ctrl] localPoint, sizeInPoints in
            ctrl?.handleClick(at: localPoint, viewSize: sizeInPoints)
        }
        view.onDoubleClick = { [weak ctrl] localPoint, sizeInPoints in
            ctrl?.handleDoubleClick(at: localPoint, viewSize: sizeInPoints)
        }
        view.onDrag = { [weak ctrl] delta in
            ctrl?.renderer.rotateFocusedPlanet(delta: SIMD2(Float(delta.width), Float(delta.height)))
        }
        ctrl.startTrackingCursor(screen: screen)
        return ctrl
    }

    /// Flip the window level. Hides desktop icons by sitting above them.
    func setGamifiedMode(_ on: Bool) {
        gamifiedMode = on
        refreshWindowLevel()
    }

    /// Demo Mode doubles as a capture-safe privacy curtain. It elevates only
    /// this screen's universe above ordinary app windows; Mission Control is
    /// placed one level higher by its own controller.
    func setDemoPresentationMode(_ on: Bool) {
        demoPresentationMode = on
        refreshWindowLevel()
    }

    func setTargetFPS(_ fps: Int) {
        mtkView.preferredFramesPerSecond = fps >= 60 ? 60 : 30
    }

    func setUniverseVisible(_ visible: Bool) {
        if visible {
            window?.orderFrontRegardless()
        } else {
            window?.orderOut(nil)
        }
    }

    private func refreshWindowLevel() {
        window?.level = Self.windowLevel(
            gamified: gamifiedMode,
            demoPresentation: demoPresentationMode)
    }

    private static func windowLevel(
        gamified: Bool,
        demoPresentation: Bool = false
    ) -> NSWindow.Level {
        if demoPresentation { return .screenSaver }
        let key = gamified ? desktopIconLevelKey : desktopLevelKey
        let raw = Int(CGWindowLevelForKey(CGWindowLevelKey(rawValue: Int32(key))!))
        return NSWindow.Level(rawValue: gamified ? raw + 1 : raw)
    }

    // MARK: - Click handling

    private func handleClick(at localPoint: NSPoint, viewSize: NSSize) {
        guard viewSize.width > 1, viewSize.height > 1 else { return }
        if renderer.isFocusedOnPlanet {
            return
        }
        let nx = Float(localPoint.x / viewSize.width)  * 2 - 1
        let ny = Float(localPoint.y / viewSize.height) * 2 - 1
        if let body = renderer.bodyAtNDC(SIMD2(nx, ny)),
           body.kind != .planet,
           let url  = body.actionURL {
            NSWorkspace.shared.open(url)
        }
        // No body? In Gamified Mode the click is silently absorbed (icons stay hidden).
    }

    private func handleDoubleClick(at localPoint: NSPoint, viewSize: NSSize) {
        guard viewSize.width > 1, viewSize.height > 1 else { return }
        if renderer.isFocusedOnPlanet {
            renderer.exitPlanetFocus()
            return
        }
        let nx = Float(localPoint.x / viewSize.width)  * 2 - 1
        let ny = Float(localPoint.y / viewSize.height) * 2 - 1
        if !renderer.focusPlanet(atNDC: SIMD2(nx, ny)) {
            renderer.exitPlanetFocus()
        }
    }

    // MARK: - Cursor tracking (mouseMoved still uses a global monitor so it
    // works when the window isn't key).

    private func startTrackingCursor(screen: NSScreen) {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let global = NSEvent.mouseLocation
                let w = screen.frame.width
                let h = screen.frame.height
                let nx = Float((global.x - screen.frame.origin.x) / w) * 2 - 1
                let ny = Float((global.y - screen.frame.origin.y) / h) * 2 - 1
                self.renderer.cursorNDC = SIMD2(nx, ny)
            }
        }
    }

    nonisolated deinit { /* monitor lives for the app's lifetime */ }
}

// MARK: - Window subclass: never become key (no focus-stealing) but still receive clicks

final class NonActivatingWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - View subclass: forwards mouseDown to a closure
// `acceptsFirstMouse` returns true so the very first click in a non-key
// window still fires mouseDown immediately.

final class WallpaperMTKView: MTKView {
    var onClick: ((NSPoint, NSSize) -> Void)?
    var onDoubleClick: ((NSPoint, NSSize) -> Void)?
    var onDrag: ((NSSize) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if event.clickCount >= 2 {
            onDoubleClick?(p, bounds.size)
        } else {
            onClick?(p, bounds.size)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(NSSize(width: event.deltaX, height: event.deltaY))
    }
}
