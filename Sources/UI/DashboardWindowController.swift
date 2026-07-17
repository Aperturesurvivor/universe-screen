import AppKit
import SwiftUI

/// Owns the native mission-control window and supplies source-picker/reveal
/// fallbacks when the host has not provided custom callbacks.
@MainActor
public final class DashboardWindowController: NSWindowController, NSWindowDelegate {
    public let model: DashboardModel

    private let hostChooseSource: (() -> Void)?
    private let hostRevealSource: ((URL) -> Void)?
    private var hostingController: NSHostingController<DashboardView>?

    public init(model: DashboardModel) {
        self.model = model
        self.hostChooseSource = model.callbacks.onChooseSource
        self.hostRevealSource = model.callbacks.onRevealSource

        let rootView = DashboardView(model: model)
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)

        super.init(window: window)

        self.hostingController = hostingController
        configure(window)
        installNativeFallbacks()
    }

    public convenience init(
        rootURL: URL? = nil,
        callbacks: DashboardCallbacks = DashboardCallbacks()
    ) {
        self.init(model: DashboardModel(rootURL: rootURL, callbacks: callbacks))
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("DashboardWindowController does not support storyboards")
    }

    public func present() {
        guard let window else { return }
        if !window.isVisible { window.center() }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func dismiss() {
        close()
    }

    /// Keep Mission Control visible above the capture-safe universe curtain.
    public func setDemoPresentationMode(_ enabled: Bool) {
        window?.level = enabled
            ? NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            : .normal
    }

    public func chooseSourceFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Source Universe"
        panel.message = "Immediate folders become project worlds; files become asteroids."
        panel.prompt = "Choose Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.resolvesAliases = true
        panel.directoryURL = model.rootURL ?? FileManager.default.homeDirectoryForCurrentUser

        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.setRootURL(url, notify: true)
    }

    public func revealSourceFolder(_ url: URL? = nil) {
        guard let url = url ?? model.rootURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public func windowWillClose(_ notification: Notification) {
        // The controller deliberately retains its hosting tree so `present()` can
        // reopen the dashboard without rebuilding model state.
    }

    private func configure(_ window: NSWindow) {
        window.title = "Universe Screen — Mission Control"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 900, height: 700))
        window.minSize = NSSize(width: 760, height: 620)
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .documentWindow
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.backgroundColor = NSColor(
            calibratedRed: 0.02,
            green: 0.025,
            blue: 0.06,
            alpha: 1
        )
        window.delegate = self
    }

    private func installNativeFallbacks() {
        model.callbacks.onChooseSource = { [weak self] in
            guard let self else { return }
            if let hostChooseSource = self.hostChooseSource { hostChooseSource() }
            else { self.chooseSourceFolder() }
        }

        model.callbacks.onRevealSource = { [weak self] url in
            guard let self else { return }
            if let hostRevealSource = self.hostRevealSource { hostRevealSource(url) }
            else { self.revealSourceFolder(url) }
        }
    }
}
