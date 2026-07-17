// Layer 1 — Data: scans a selected workspace root, computes folder sizes, and watches changes.
// Every scan path runs on a background queue; results are dispatched back to main.
import Foundation
import CoreServices

// MARK: - Models

enum Biome: UInt32, CaseIterable {
    case lush     = 0
    case sandy    = 1
    case ocean    = 2
    case crimson  = 3
    case rocky    = 4
    case golden   = 5

    static func infer(from url: URL) -> Biome {
        switch url.lastPathComponent.lowercased() {
        case "documents":             return .lush
        case "downloads":             return .sandy
        case "pictures", "photos":    return .ocean
        case "movies", "videos":      return .crimson
        case "music":                 return .golden
        default:
            let h = stableHash(url.lastPathComponent)
            return Biome(rawValue: h % 6) ?? .rocky
        }
    }
}

struct FolderInfo: Identifiable {
    let url: URL
    let sizeBytes: Int64
    let biome: Biome
    let iconPosition: CGPoint?
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

struct DesktopSnapshot {
    let folders: [FolderInfo]
    let files:   [FileInfo]
    let positionResult: FinderFetchResult
}

struct FolderContentItem: Identifiable {
    let url: URL
    let sizeBytes: Int64
    let isDirectory: Bool

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

enum FolderContentScanner {
    static let maxItems = 28

    static func scan(_ folderURL: URL) -> [FolderContentItem] {
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .isPackageKey
        ]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles])) ?? []

        return urls.compactMap { url -> FolderContentItem? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let isDirectory = values.isDirectory == true && values.isPackage != true
            let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            return FolderContentItem(url: url, sizeBytes: size, isDirectory: isDirectory)
        }
        .sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
            if $0.sizeBytes != $1.sizeBytes { return $0.sizeBytes > $1.sizeBytes }
            return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
        .prefix(maxItems)
        .map { $0 }
    }

}

// FNV-1a 32-bit
func stableHash(_ s: String) -> UInt32 {
    var h: UInt32 = 0x811c9dc5
    for byte in s.utf8 {
        h ^= UInt32(byte)
        h = h &* 0x01000193
    }
    return h
}

// MARK: - Scanner

enum DesktopScanner {

    static var desktopURL: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
    }

    /// FAST scan: directory list + AppleScript positions, **no recursive sizes**.
    /// Folder sizeBytes is 0 in the result — call `deepScan` for real sizes.
    /// All work happens on a background queue; the completion is dispatched to main.
    static func quickScan(rootURL: URL = desktopURL,
                          maxFolders: Int? = nil,
                          _ completion: @escaping @MainActor (DesktopSnapshot) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let positions = rootURL.standardizedFileURL == desktopURL.standardizedFileURL
                ? FinderIconPositions.fetch()
                : FinderFetchResult(positions: [:], errorCode: 0, errorMessage: "")
            let snap = snapshot(rootURL: rootURL, positionResult: positions,
                                withSizes: false, maxFolders: maxFolders)
            DispatchQueue.main.async { completion(snap) }
        }
    }

    /// Returns the set of folder names on the Desktop. No AppleScript, no sizes.
    /// Safe to call from any thread — `DesktopScanner` has no actor isolation.
    static func folderNames(rootURL: URL = desktopURL) -> Set<String> {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])) ?? []
        return Set(items.compactMap { u -> String? in
            guard (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else { return nil }
            return u.lastPathComponent
        })
    }

    /// INSTANT scan: directory listing only — no AppleScript, no sizes, < 1 ms.
    /// Planets appear at their orbital-slot positions immediately.
    /// Always follow with quickScan / deepScan for real positions and sizes.
    static func fileSystemOnlyScan(rootURL: URL = desktopURL,
                                   maxFolders: Int? = nil,
                                   _ completion: @escaping @MainActor (DesktopSnapshot) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let empty   = FinderFetchResult(positions: [:], errorCode: 0, errorMessage: "")
            let snap = snapshot(rootURL: rootURL, positionResult: empty,
                                withSizes: false, maxFolders: maxFolders)
            DispatchQueue.main.async { completion(snap) }
        }
    }

    static func snapshot(rootURL: URL = desktopURL,
                         positionResult: FinderFetchResult,
                         withSizes: Bool,
                         maxFolders: Int? = nil,
                         maxFiles: Int = 96) -> DesktopSnapshot {
        let folders = enumerateFolders(rootURL: rootURL,
                                       positions: positionResult.positions,
                                       withSizes: withSizes,
                                       maxFolders: maxFolders)
        let files = enumerateFiles(rootURL: rootURL,
                                   positions: positionResult.positions,
                                   maxFiles: maxFiles)
        return DesktopSnapshot(folders: folders, files: files, positionResult: positionResult)
    }

    /// DEEP scan: same as quickScan but folders include real recursive sizes.
    /// Always background — sizes can be expensive.
    static func deepScan(rootURL: URL = desktopURL,
                         maxFolders: Int? = nil,
                         _ completion: @escaping @MainActor (DesktopSnapshot) -> Void) {
        DispatchQueue.global(qos: .background).async {
            let positions = rootURL.standardizedFileURL == desktopURL.standardizedFileURL
                ? FinderIconPositions.fetch()
                : FinderFetchResult(positions: [:], errorCode: 0, errorMessage: "")
            let snap = snapshot(rootURL: rootURL, positionResult: positions,
                                withSizes: true, maxFolders: maxFolders)
            DispatchQueue.main.async { completion(snap) }
        }
    }

    // MARK: - Internals (run on background)

    private static func enumerateFolders(rootURL: URL,
                                         positions: [String: CGPoint],
                                         withSizes: Bool,
                                         maxFolders: Int?) -> [FolderInfo] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])) ?? []

        var dirs = urls.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }

        // Large workspace roots remain legible by showing the most recently active
        // projects first. Stable name ordering breaks equal-date ties deterministically.
        dirs.sort { lhs, rhs in
            let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                ?? .distantPast
            let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
        }
        if let maxFolders { dirs = Array(dirs.prefix(max(1, maxFolders))) }

        return dirs.map { folder in
            FolderInfo(
                url: folder,
                sizeBytes: withSizes ? folderSize(folder) : 0,
                biome: Biome.infer(from: folder),
                iconPosition: positions[folder.lastPathComponent])
        }
    }

    private static func enumerateFiles(rootURL: URL,
                                       positions: [String: CGPoint],
                                       maxFiles: Int) -> [FileInfo] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey,
                                         .totalFileAllocatedSizeKey,
                                         .fileAllocatedSizeKey,
                                         .contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []

        var result: [FileInfo] = []
        result.reserveCapacity(urls.count)
        for f in urls {
            guard let v = try? f.resourceValues(forKeys: [.isDirectoryKey,
                                                          .totalFileAllocatedSizeKey,
                                                          .fileAllocatedSizeKey,
                                                          .contentModificationDateKey]) else { continue }
            if v.isDirectory == true { continue }
            let size = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            result.append(FileInfo(
                url: f,
                sizeBytes: size,
                iconPosition: positions[f.lastPathComponent]))
        }
        let sortedFiles = result.sorted(by: { (lhs: FileInfo, rhs: FileInfo) -> Bool in
            let keys = Set([URLResourceKey.contentModificationDateKey])
            let left = (try? lhs.url.resourceValues(forKeys: keys))?.contentModificationDate
                ?? .distantPast
            let right = (try? rhs.url.resourceValues(forKeys: keys))?.contentModificationDate
                ?? .distantPast
            if left != right { return left > right }
            return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
        })
        return Array(sortedFiles.prefix(max(1, maxFiles)))
    }

    /// Recursive size in bytes (allocated). Capped at 200k entries.
    private static func folderSize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let e = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return 0 }

        var visited = 0
        for case let f as URL in e {
            visited += 1
            if visited > 200_000 { break }
            if let v = try? f.resourceValues(forKeys: Set(keys)) {
                total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            }
        }
        return total
    }
}

// MARK: - Watcher (FSEvents) with built-in debouncing

@MainActor
final class DesktopWatcher {

    private var stream: FSEventStreamRef?
    private let onChange: () -> Void
    private let url: URL
    private var lastFire: Date = .distantPast
    private static let minInterval: TimeInterval = 1.5

    init(url: URL = DesktopScanner.desktopURL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    @discardableResult
    func start() -> Bool {
        stop()
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let cb: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DesktopWatcher>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async { watcher.fire() }
        }

        stream = FSEventStreamCreate(
            nil, cb, &ctx,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            UInt32(kFSEventStreamCreateFlagNone))

        guard let stream else { return false }
        FSEventStreamSetDispatchQueue(stream, .main)
        return FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func fire() {
        let now = Date()
        if now.timeIntervalSince(lastFire) < Self.minInterval { return }
        lastFire = now
        onChange()
    }

    nonisolated deinit { /* AppDelegate explicitly stops the stream before replacement. */ }
}
