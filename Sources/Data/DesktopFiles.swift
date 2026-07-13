// Layer 1 — Data: model for a non-folder desktop item (powers asteroid bodies).
// The actual enumeration now lives in DesktopScanner so we get folders + files
// from a single background pass.
import Foundation

struct FileInfo: Identifiable {
    let url: URL
    let sizeBytes: Int64
    let iconPosition: CGPoint?
    var id: URL { url }
}
