// Layer 1 — Data: detect default browser and map its bundle ID to a 4-stop
// star palette. Each color drives a specific shading slot in the surface +
// corona shaders so every browser produces a visually distinct sun.
//
//   core   = brightest center of the visible disc
//   mid    = transition tone between core and limb
//   limb   = edge color, also seeds the limb glow / corona base
//   accent = highlight pops in cloud peaks + flare loops
import AppKit
import simd

struct BrowserInfo {
    let bundleId: String
    let name:     String
    let url:      URL?
    let theme:    BrowserTheme
}

struct BrowserTheme {
    let core:   SIMD3<Float>
    let mid:    SIMD3<Float>
    let limb:   SIMD3<Float>
    let accent: SIMD3<Float>
}

enum DefaultBrowser {

    @MainActor
    static func current() -> BrowserInfo {
        let probe  = URL(string: "https://example.com")!
        let appURL = NSWorkspace.shared.urlForApplication(toOpen: probe)

        let bundleId: String
        let name:     String
        if let appURL,
           let bundle = Bundle(url: appURL) {
            bundleId = bundle.bundleIdentifier ?? "unknown"
            name     = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                    ?? (bundle.infoDictionary?["CFBundleName"] as? String)
                    ?? appURL.deletingPathExtension().lastPathComponent
        } else {
            bundleId = "unknown"
            name     = "Web"
        }
        return BrowserInfo(
            bundleId: bundleId,
            name:     name,
            url:      appURL,
            theme:    theme(for: bundleId))
    }

    static func theme(for bundleId: String) -> BrowserTheme {
        switch bundleId.lowercased() {

        // Safari → vibrant blue core, white highlights, red corona
        case "com.apple.safari":
            return BrowserTheme(
                core:   SIMD3(0.55, 0.85, 1.00),
                mid:    SIMD3(0.20, 0.55, 0.95),
                limb:   SIMD3(0.95, 0.30, 0.25),
                accent: SIMD3(1.00, 0.95, 0.92))

        // Chrome → red/yellow dominant, green/blue accents
        case "com.google.chrome", "com.google.chrome.canary", "com.google.chrome.beta":
            return BrowserTheme(
                core:   SIMD3(1.00, 0.95, 0.45),
                mid:    SIMD3(0.95, 0.40, 0.20),
                limb:   SIMD3(0.65, 0.18, 0.10),
                accent: SIMD3(0.30, 0.85, 0.45))

        // Firefox → fiery orange-red, purple/white accents
        case "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly":
            return BrowserTheme(
                core:   SIMD3(1.00, 0.85, 0.45),
                mid:    SIMD3(1.00, 0.45, 0.10),
                limb:   SIMD3(0.70, 0.15, 0.05),
                accent: SIMD3(0.78, 0.35, 0.95))

        // Edge → cyan/blue dominant
        case "com.microsoft.edgemac", "com.microsoft.edgemac.beta", "com.microsoft.edgemac.dev":
            return BrowserTheme(
                core:   SIMD3(0.55, 0.92, 1.00),
                mid:    SIMD3(0.10, 0.60, 0.95),
                limb:   SIMD3(0.05, 0.25, 0.75),
                accent: SIMD3(0.40, 1.00, 0.85))

        // Brave → fierce orange-red with bright gold accents
        case "com.brave.browser":
            return BrowserTheme(
                core:   SIMD3(1.00, 0.80, 0.35),
                mid:    SIMD3(1.00, 0.45, 0.15),
                limb:   SIMD3(0.55, 0.10, 0.05),
                accent: SIMD3(1.00, 0.90, 0.30))

        // Vivaldi → red/black with vibrant red highlights
        case "com.vivaldi.vivaldi":
            return BrowserTheme(
                core:   SIMD3(1.00, 0.75, 0.55),
                mid:    SIMD3(0.95, 0.25, 0.20),
                limb:   SIMD3(0.45, 0.05, 0.05),
                accent: SIMD3(1.00, 0.55, 0.30))

        // Arc → pink/purple/blue gradient
        case "company.thebrowser.browser", "company.thebrowser.arc":
            return BrowserTheme(
                core:   SIMD3(1.00, 0.90, 1.00),
                mid:    SIMD3(0.90, 0.45, 0.95),
                limb:   SIMD3(0.40, 0.55, 1.00),
                accent: SIMD3(1.00, 0.70, 0.90))

        // DuckDuckGo → orange/purple
        case "com.duckduckgo.macos.browser":
            return BrowserTheme(
                core:   SIMD3(1.00, 0.85, 0.50),
                mid:    SIMD3(0.95, 0.50, 0.20),
                limb:   SIMD3(0.40, 0.10, 0.55),
                accent: SIMD3(0.85, 0.65, 0.95))

        // Default — sun-like white-yellow → orange-red
        default:
            return BrowserTheme(
                core:   SIMD3(1.00, 0.95, 0.78),
                mid:    SIMD3(1.00, 0.70, 0.30),
                limb:   SIMD3(0.95, 0.32, 0.10),
                accent: SIMD3(1.00, 0.85, 0.45))
        }
    }
}
