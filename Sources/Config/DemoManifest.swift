import CoreGraphics
import Foundation

/// Checked-in, synthetic scene data for a repeatable public demo. Demo Mode never
/// accepts live filesystem or Codex records; those integrations remain a separate
/// local product mode.
struct DemoManifest: Codable, Equatable {
    static let supportedSchemaVersion = 1
    static let requiredClassification = "synthetic-public-safe"

    let schemaVersion: Int
    let id: String
    let title: String
    let seed: UInt64
    let referenceTimestamp: String
    let provenance: Provenance
    let worlds: [World]
    let files: [File]
    let agents: [Agent]

    struct Provenance: Codable, Equatable {
        let classification: String
        let source: String
        let rights: String
        let humanReviewRequiredBeforeCommercialExport: Bool
    }

    struct World: Codable, Equatable {
        let id: String
        let label: String
        let sizeBytes: Int64
        let biome: String
    }

    struct File: Codable, Equatable {
        let id: String
        let label: String
        let sizeBytes: Int64
    }

    struct Agent: Codable, Equatable {
        let id: String
        let label: String
        let role: String
        let signal: String
        let worldID: String
    }

    func validated() throws -> DemoManifest {
        var issues: [String] = []

        if schemaVersion != Self.supportedSchemaVersion {
            issues.append("schemaVersion must be \(Self.supportedSchemaVersion)")
        }
        if provenance.classification != Self.requiredClassification {
            issues.append("provenance.classification must be \(Self.requiredClassification)")
        }
        if !provenance.humanReviewRequiredBeforeCommercialExport {
            issues.append("commercial export must retain the human-review gate")
        }
        Self.validateLabel(id, field: "id", issues: &issues)
        Self.validateLabel(title, field: "title", issues: &issues)
        Self.validateLabel(provenance.source, field: "provenance.source", issues: &issues)
        Self.validateLabel(provenance.rights, field: "provenance.rights", issues: &issues)

        guard ISO8601DateFormatter().date(from: referenceTimestamp) != nil else {
            issues.append("referenceTimestamp must be ISO-8601")
            throw DemoManifestError.invalid(issues)
        }

        if worlds.isEmpty { issues.append("at least one world is required") }
        if worlds.count > 12 { issues.append("at most 12 worlds are allowed") }
        if files.count > 24 { issues.append("at most 24 files are allowed") }
        if agents.count > 48 {
            issues.append("agent count exceeds the renderer limit")
        }

        Self.validateUniqueIDs(worlds.map(\.id), field: "world", issues: &issues)
        Self.validateUniqueIDs(files.map(\.id), field: "file", issues: &issues)
        Self.validateUniqueIDs(agents.map(\.id), field: "agent", issues: &issues)

        let worldIDs = Set(worlds.map(\.id))
        for world in worlds {
            Self.validateLabel(world.id, field: "world.id", issues: &issues)
            Self.validateLabel(world.label, field: "world.label", issues: &issues)
            if world.sizeBytes < 0 { issues.append("world.sizeBytes cannot be negative") }
            if DemoBiome(rawValue: world.biome) == nil {
                issues.append("world.biome is unsupported: \(world.biome)")
            }
        }
        for file in files {
            Self.validateLabel(file.id, field: "file.id", issues: &issues)
            Self.validateLabel(file.label, field: "file.label", issues: &issues)
            if file.sizeBytes < 0 { issues.append("file.sizeBytes cannot be negative") }
        }
        for agent in agents {
            Self.validateLabel(agent.id, field: "agent.id", issues: &issues)
            Self.validateLabel(agent.label, field: "agent.label", issues: &issues)
            if DemoAgentRole(rawValue: agent.role) == nil {
                issues.append("agent.role is unsupported: \(agent.role)")
            }
            if DemoAgentSignal(rawValue: agent.signal) == nil {
                issues.append("agent.signal is unsupported: \(agent.signal)")
            }
            if !worldIDs.contains(agent.worldID) {
                issues.append("agent.worldID does not reference a world: \(agent.worldID)")
            }
        }

        guard issues.isEmpty else { throw DemoManifestError.invalid(issues) }
        return self
    }

    func makeScene(screenSize: CGSize) throws -> DemoScene {
        let manifest = try validated()
        guard let referenceDate = ISO8601DateFormatter().date(from: manifest.referenceTimestamp) else {
            throw DemoManifestError.invalid(["referenceTimestamp must be ISO-8601"])
        }

        let rootURL = URL(fileURLWithPath: "/UniverseScreenSyntheticDemo", isDirectory: true)
        let orderedWorlds = manifest.worlds.sorted { $0.id < $1.id }
        let worldURLs = Dictionary(uniqueKeysWithValues: orderedWorlds.map {
            ($0.id, rootURL.appendingPathComponent($0.label, isDirectory: true))
        })
        let folders = orderedWorlds.map { world in
            FolderInfo(
                url: worldURLs[world.id]!,
                sizeBytes: world.sizeBytes,
                biome: DemoBiome(rawValue: world.biome)!.biome,
                iconPosition: nil)
        }
        let files = manifest.files.sorted { $0.id < $1.id }.map { file in
            FileInfo(
                url: rootURL.appendingPathComponent(file.label, isDirectory: false),
                sizeBytes: file.sizeBytes,
                iconPosition: nil)
        }
        let agents = manifest.agents.sorted { $0.id < $1.id }.map { agent in
            let worldURL = worldURLs[agent.worldID]!
            return CodexAgentActivity(
                id: "synthetic-\(agent.id)",
                parentID: nil,
                displayName: agent.label,
                role: DemoAgentRole(rawValue: agent.role)!.role,
                lifecycle: .active,
                signal: DemoAgentSignal(rawValue: agent.signal)!.signal,
                workspaceURL: worldURL,
                locationURL: worldURL.appendingPathComponent("Synthetic Work", isDirectory: true),
                startedAt: referenceDate,
                lastEventAt: referenceDate)
        }

        return DemoScene(
            manifestID: manifest.id,
            rootURL: rootURL,
            seed: Seed(value: manifest.seed),
            folders: folders,
            files: files,
            agents: agents,
            screenSize: screenSize)
    }

    static func decode(contentsOf url: URL) throws -> DemoManifest {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(DemoManifest.self, from: data).validated()
    }

    static func bundledSampleURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "sample-manifest", withExtension: "json", subdirectory: "Demo")
            ?? bundle.url(forResource: "sample-manifest", withExtension: "json", subdirectory: "Resources/Demo")
    }

    private static func validateUniqueIDs(
        _ ids: [String],
        field: String,
        issues: inout [String]
    ) {
        if Set(ids).count != ids.count { issues.append("\(field) IDs must be unique") }
    }

    /// Structural leak prevention, not a claim that arbitrary text was reviewed.
    /// Commercial use remains gated by the manifest classification and human review.
    private static func validateLabel(
        _ value: String,
        field: String,
        issues: inout [String]
    ) {
        let allowed = CharacterSet.alphanumerics
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: "-_."))
        let obviousPrivateMarkers = ["/", "\\", "@", "://", "~", "$", "{"]
        if value.isEmpty || value.count > 64 {
            issues.append("\(field) must contain 1...64 characters")
        }
        if value.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            issues.append("\(field) contains a disallowed character")
        }
        if obviousPrivateMarkers.contains(where: value.contains) {
            issues.append("\(field) resembles a path, address, URL, or template token")
        }
    }
}

struct DemoScene {
    let manifestID: String
    let rootURL: URL
    let seed: Seed
    let folders: [FolderInfo]
    let files: [FileInfo]
    let agents: [CodexAgentActivity]
    let screenSize: CGSize
}

enum DemoManifestError: LocalizedError, Equatable {
    case invalid([String])

    var errorDescription: String? {
        switch self {
        case .invalid(let issues):
            "Demo manifest rejected: " + issues.joined(separator: "; ")
        }
    }
}

private enum DemoBiome: String {
    case lush, sandy, ocean, crimson, rocky, golden

    var biome: Biome {
        switch self {
        case .lush: .lush
        case .sandy: .sandy
        case .ocean: .ocean
        case .crimson: .crimson
        case .rocky: .rocky
        case .golden: .golden
        }
    }
}

private enum DemoAgentRole: String {
    case primary, subagent

    var role: CodexAgentRole {
        switch self {
        case .primary: .primary
        case .subagent: .subagent
        }
    }
}

private enum DemoAgentSignal: String {
    case starting, thinking, usingTool, communicating, working, waiting

    var signal: CodexAgentSignal {
        switch self {
        case .starting: .starting
        case .thinking: .thinking
        case .usingTool: .usingTool
        case .communicating: .communicating
        case .working: .working
        case .waiting: .waiting
        }
    }
}

struct DemoExportPreset: Codable, Equatable {
    let schemaVersion: Int
    let id: String
    let durationSeconds: Int
    let width: Int
    let height: Int
    let framesPerSecond: Int
    let container: String
    let codec: String
    let audio: String
    let contentClassification: String

    var expectedFrameCount: Int { durationSeconds * framesPerSecond }

    func validated() throws -> DemoExportPreset {
        var issues: [String] = []
        if schemaVersion != 1 { issues.append("schemaVersion must be 1") }
        if durationSeconds != 15 { issues.append("durationSeconds must be 15") }
        if width != 1_920 || height != 1_080 { issues.append("dimensions must be 1920x1080") }
        if framesPerSecond != 30 { issues.append("framesPerSecond must be 30") }
        if container != "mp4" { issues.append("container must be mp4") }
        if codec != "h264" { issues.append("codec must be h264") }
        if audio != "none" { issues.append("audio must be none") }
        if contentClassification != DemoManifest.requiredClassification {
            issues.append("contentClassification must be synthetic-public-safe")
        }
        guard issues.isEmpty else { throw DemoManifestError.invalid(issues) }
        return self
    }

    static func decode(contentsOf url: URL) throws -> DemoExportPreset {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(DemoExportPreset.self, from: data).validated()
    }

    static func bundledURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "export-1080p-15s", withExtension: "json", subdirectory: "Demo")
            ?? bundle.url(forResource: "export-1080p-15s", withExtension: "json", subdirectory: "Resources/Demo")
    }
}
