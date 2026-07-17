// Layer 3 — UI: NSStatusBar item that shows the control-panel popover
import AppKit

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {

    private let statusItem: NSStatusItem
    private let popover    = NSPopover()
    private let onOpenDashboard: (() -> Void)?
    let panelVC:   ControlPanelViewController

    /// Fired right before the popover starts showing. Use this to pause
    /// background work that competes with the main run loop.
    var onPanelWillShow: (() -> Void)?
    /// Fired after the popover has finished closing.
    var onPanelDidClose: (() -> Void)?

    init(config: SimulationConfig,
         onOpenDashboard: (() -> Void)? = nil,
         onQuit: @escaping () -> Void,
         onResetAndRetry: @escaping () -> Void,
         onGamifiedToggle: @escaping (Bool) -> Void,
         onStarChange: @escaping () -> Void,
         onSeedChange: @escaping (UInt64) -> Void) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.onOpenDashboard = onOpenDashboard
        panelVC    = ControlPanelViewController(
            config: config,
            onQuit: onQuit,
            onResetAndRetry: onResetAndRetry,
            onGamifiedToggle: onGamifiedToggle,
            onStarChange: onStarChange,
            onSeedChange: onSeedChange)
        super.init()

        if let btn = statusItem.button {
            btn.image  = NSImage(systemSymbolName: "sparkles",
                                 accessibilityDescription: "Universe Screen")
            btn.target = self
            btn.action = #selector(togglePanel)
        }

        popover.contentViewController = panelVC
        popover.contentSize            = NSSize(width: 320, height: 600)
        popover.behavior               = .transient
        popover.delegate               = self
    }

    @objc private func togglePanel() {
        if let onOpenDashboard {
            onOpenDashboard()
        } else if popover.isShown {
            popover.performClose(nil)
        } else if let btn = statusItem.button {
            popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
        }
    }

    // MARK: - NSPopoverDelegate
    func popoverWillShow(_ notification: Notification) { onPanelWillShow?() }
    func popoverDidClose(_ notification: Notification) { onPanelDidClose?() }
}
