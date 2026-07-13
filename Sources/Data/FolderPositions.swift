// Layer 1 — Data: read desktop icon positions from Finder via AppleScript.
// Thread-safe: returns an immutable result; main-actor mirrors are kept in
// `FinderFetchState` (also main-actor) for the UI to read.
import AppKit
import Foundation

struct FinderFetchResult {
    let positions: [String: CGPoint]
    let errorCode: Int
    let errorMessage: String
}

enum FinderIconPositions {

    /// Background-thread-safe AppleScript fetch.
    static func fetch() -> FinderFetchResult {
        let script = """
        tell application "Finder"
            set output to ""
            try
                repeat with theItem in (every item of desktop)
                    try
                        set p to position of theItem
                        set output to output & (name of theItem) & "\\t" ¬
                            & (item 1 of p as text) & "\\t" ¬
                            & (item 2 of p as text) & linefeed
                    end try
                end repeat
            end try
            return output
        end tell
        """
        guard let appleScript = NSAppleScript(source: script) else {
            return FinderFetchResult(positions: [:], errorCode: -1,
                                     errorMessage: "Couldn't compile AppleScript")
        }

        var error: NSDictionary?
        let descriptor = appleScript.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? -1
            let msg  = (error[NSAppleScript.errorMessage] as? String) ?? "Unknown"
            NSLog("Universe Screen Finder fetch failed: code=\(code) msg=\(msg)")
            return FinderFetchResult(positions: [:], errorCode: code, errorMessage: msg)
        }

        let raw = descriptor.stringValue ?? ""
        var out: [String: CGPoint] = [:]
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t")
            guard parts.count == 3,
                  let x = Double(parts[1]),
                  let y = Double(parts[2]) else { continue }
            out[String(parts[0])] = CGPoint(x: x, y: y)
        }
        return FinderFetchResult(positions: out, errorCode: 0, errorMessage: "")
    }

    static func openAutomationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
        NSWorkspace.shared.open(url)
    }

    static func resetAppleEventsPermission() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "AppleEvents", Bundle.main.bundleIdentifier ?? ""]
        try? task.run()
        task.waitUntilExit()
    }
}

/// Last-fetch state visible to UI. Always written from the main actor after
/// a background fetch completes.
@MainActor
enum FinderFetchState {
    static private(set) var lastResultCount: Int = 0
    static private(set) var lastErrorCode: Int = 0
    static private(set) var lastErrorMessage: String = ""

    static func record(_ r: FinderFetchResult) {
        lastResultCount  = r.positions.count
        lastErrorCode    = r.errorCode
        lastErrorMessage = r.errorMessage
    }
}
