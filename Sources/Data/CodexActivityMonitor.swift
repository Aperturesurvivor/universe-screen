// Privacy-safe local telemetry for active Codex sessions.
//
// This monitor retains only identity, lifecycle, timing, workspace, sanitized
// filesystem location, and event-category metadata from Codex rollout JSONL.
// It never stores prompts, messages, reasoning text, raw tool arguments, patches,
// command output, or tool output.
import Combine
import Foundation

public enum CodexActivityAvailability: String, Sendable, Equatable {
    case notStarted
    case available
    case partial
    case sessionsDirectoryMissing
    case unavailable
}

public enum CodexAgentLifecycle: String, Sendable, Equatable {
    case active
    case completed
    case aborted
    case stale
}

/// A deliberately coarse activity category suitable for animation. No tool names,
/// command text, message text, or reasoning content leave the parser.
public enum CodexAgentSignal: String, Sendable, Equatable {
    case starting
    case thinking
    case usingTool
    case communicating
    case working
    case waiting
    case finished
    case interrupted
}

public enum CodexAgentRole: String, Sendable, Equatable {
    case primary
    case subagent
}

public struct CodexAgentActivity: Identifiable, Sendable, Equatable {
    /// A stable pseudonymous hash of the Codex thread identifier. The raw thread
    /// UUID never leaves the private parser.
    public let id: String
    public let parentID: String?
    public let displayName: String
    public let role: CodexAgentRole
    public let lifecycle: CodexAgentLifecycle
    public let signal: CodexAgentSignal

    /// Workspace metadata used to associate a ship with a selected project planet.
    /// UI should display the selected planet name, not this raw URL.
    public let workspaceURL: URL?
    /// Most recent filesystem location extracted from a recognized structured
    /// tool field. Raw tool arguments are discarded after sanitization.
    public let locationURL: URL?
    public let startedAt: Date?
    public let lastEventAt: Date

    public init(
        id: String,
        parentID: String?,
        displayName: String,
        role: CodexAgentRole,
        lifecycle: CodexAgentLifecycle,
        signal: CodexAgentSignal,
        workspaceURL: URL?,
        locationURL: URL? = nil,
        startedAt: Date?,
        lastEventAt: Date
    ) {
        self.id = id
        self.parentID = parentID
        self.displayName = displayName
        self.role = role
        self.lifecycle = lifecycle
        self.signal = signal
        self.workspaceURL = workspaceURL
        self.locationURL = locationURL
        self.startedAt = startedAt
        self.lastEventAt = lastEventAt
    }
}

public struct CodexActivitySnapshot: Sendable, Equatable {
    public let availability: CodexActivityAvailability
    public let agents: [CodexAgentActivity]
    public let updatedAt: Date
    public let discardedRecordCount: Int

    public var activeAgents: [CodexAgentActivity] {
        agents.filter { $0.lifecycle == .active }
    }

    public var activeCount: Int { activeAgents.count }

    public static let notStarted = CodexActivitySnapshot(
        availability: .notStarted,
        agents: [],
        updatedAt: .distantPast,
        discardedRecordCount: 0
    )

    public init(
        availability: CodexActivityAvailability,
        agents: [CodexAgentActivity],
        updatedAt: Date,
        discardedRecordCount: Int
    ) {
        self.availability = availability
        self.agents = agents
        self.updatedAt = updatedAt
        self.discardedRecordCount = discardedRecordCount
    }
}

public struct CodexActivityMonitorConfiguration: Sendable, Equatable {
    public var pollInterval: TimeInterval
    public var discoveryLookback: TimeInterval
    public var staleAfter: TimeInterval
    public var completedRetention: TimeInterval
    public var staleRetention: TimeInterval
    public var maxTrackedFiles: Int
    public var maxInitialFileBytes: Int
    public var oversizedFileTailBytes: Int

    public static let `default` = CodexActivityMonitorConfiguration(
        pollInterval: 0.75,
        discoveryLookback: 24 * 60 * 60,
        staleAfter: 15 * 60,
        completedRetention: 12,
        staleRetention: 60,
        maxTrackedFiles: 128,
        maxInitialFileBytes: 8 * 1_024 * 1_024,
        oversizedFileTailBytes: 2 * 1_024 * 1_024
    )

    public init(
        pollInterval: TimeInterval,
        discoveryLookback: TimeInterval,
        staleAfter: TimeInterval,
        completedRetention: TimeInterval,
        staleRetention: TimeInterval,
        maxTrackedFiles: Int,
        maxInitialFileBytes: Int,
        oversizedFileTailBytes: Int
    ) {
        self.pollInterval = max(0.2, pollInterval)
        self.discoveryLookback = max(60, discoveryLookback)
        self.staleAfter = max(30, staleAfter)
        self.completedRetention = max(0, completedRetention)
        self.staleRetention = max(0, staleRetention)
        self.maxTrackedFiles = max(1, maxTrackedFiles)
        self.maxInitialFileBytes = max(64 * 1_024, maxInitialFileBytes)
        self.oversizedFileTailBytes = max(64 * 1_024, oversizedFileTailBytes)
    }
}

/// Main-actor observable facade for AppDelegate, dashboard, and renderer wiring.
///
/// `start()` begins lightweight polling. `refreshNow()` is also public so callers
/// can explicitly refresh after enabling telemetry or changing the universe root.
@MainActor
public final class CodexActivityMonitor: ObservableObject {
    public static var defaultSessionsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    @Published public private(set) var snapshot: CodexActivitySnapshot = .notStarted

    public var isRunning: Bool { pollingTask != nil }

    private let configuration: CodexActivityMonitorConfiguration
    private let tailer: CodexSessionTailer
    private var pollingTask: Task<Void, Never>?
    private var refreshIsRunning = false

    public init(
        sessionsDirectory: URL = CodexActivityMonitor.defaultSessionsDirectory,
        configuration: CodexActivityMonitorConfiguration = .default
    ) {
        self.configuration = configuration
        self.tailer = CodexSessionTailer(
            sessionsDirectory: sessionsDirectory,
            configuration: configuration
        )
    }

    public func start() {
        guard pollingTask == nil else { return }

        pollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshNow()
                if Task.isCancelled { break }

                let nanoseconds = UInt64(
                    min(self.configuration.pollInterval, 3_600) * 1_000_000_000
                )
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    break
                }
            }
        }
    }

    public func stop(clearSnapshot: Bool = false) {
        pollingTask?.cancel()
        pollingTask = nil
        refreshIsRunning = false
        if clearSnapshot {
            snapshot = .notStarted
        }
    }

    public func refreshNow() async {
        guard !refreshIsRunning else { return }
        refreshIsRunning = true
        defer { refreshIsRunning = false }

        let next = await tailer.scan(now: Date())
        if !Task.isCancelled {
            snapshot = next
        }
    }
}

// MARK: - Incremental rollout tailer

private actor CodexSessionTailer {
    private let sessionsDirectory: URL
    private let configuration: CodexActivityMonitorConfiguration
    private var states: [URL: SessionState] = [:]

    private let fractionalISO8601: ISO8601DateFormatter
    private let plainISO8601: ISO8601DateFormatter

    init(
        sessionsDirectory: URL,
        configuration: CodexActivityMonitorConfiguration
    ) {
        self.sessionsDirectory = sessionsDirectory.standardizedFileURL
        self.configuration = configuration

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        fractionalISO8601 = fractional

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        plainISO8601 = plain
    }

    func scan(now: Date) -> CodexActivitySnapshot {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: sessionsDirectory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            states.removeAll(keepingCapacity: false)
            return CodexActivitySnapshot(
                availability: .sessionsDirectoryMissing,
                agents: [],
                updatedAt: now,
                discardedRecordCount: 0
            )
        }

        let discovery = discoverRollouts(now: now)
        var readFailureCount = discovery.failedResourceReads
        var discardedRecordCount = 0
        let discoveredURLs = Set(discovery.files.map(\.url))

        for candidate in discovery.files {
            var state = states[candidate.url] ?? SessionState()
            state.modificationDate = candidate.modificationDate

            do {
                try ingest(candidate: candidate, into: &state)
            } catch {
                // Never expose an error string: it may contain a private path.
                readFailureCount += 1
            }

            discardedRecordCount += state.discardedRecordCount
            states[candidate.url] = state
        }

        // Rollouts have unique names and do not rotate in normal operation. Keep
        // only this scan's bounded candidate set so a long-running app cannot
        // accumulate one cursor for every historical session it has ever seen.
        states = states.filter { discoveredURLs.contains($0.key) }

        let agents = states.values.compactMap { activity(from: $0, now: now) }
            .sorted {
                if $0.lifecycle == .active, $1.lifecycle != .active { return true }
                if $0.lifecycle != .active, $1.lifecycle == .active { return false }
                return $0.lastEventAt > $1.lastEventAt
            }

        let availability: CodexActivityAvailability
        if readFailureCount == 0, discardedRecordCount == 0 {
            availability = .available
        } else if agents.isEmpty {
            availability = .unavailable
        } else {
            availability = .partial
        }

        return CodexActivitySnapshot(
            availability: availability,
            agents: agents,
            updatedAt: now,
            discardedRecordCount: discardedRecordCount
        )
    }

    private func discoverRollouts(now: Date) -> DiscoveryResult {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .contentModificationDateKey,
            .fileSizeKey
        ]

        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return DiscoveryResult(files: [], failedResourceReads: 1)
        }

        var candidates: [RolloutCandidate] = []
        var failedResourceReads = 0

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            do {
                let values = try url.resourceValues(forKeys: Set(keys))
                guard values.isRegularFile == true,
                      let modified = values.contentModificationDate,
                      let size = values.fileSize,
                      now.timeIntervalSince(modified) <= configuration.discoveryLookback
                else { continue }

                candidates.append(RolloutCandidate(
                    url: url.standardizedFileURL,
                    modificationDate: modified,
                    fileSize: UInt64(max(0, size))
                ))
            } catch {
                failedResourceReads += 1
            }
        }

        candidates.sort { $0.modificationDate > $1.modificationDate }
        if candidates.count > configuration.maxTrackedFiles {
            candidates.removeSubrange(configuration.maxTrackedFiles...)
        }
        return DiscoveryResult(
            files: candidates,
            failedResourceReads: failedResourceReads
        )
    }

    private func ingest(candidate: RolloutCandidate, into state: inout SessionState) throws {
        if candidate.fileSize < state.offset {
            state = SessionState()
            state.modificationDate = candidate.modificationDate
        }

        guard candidate.fileSize > state.offset || state.identity == nil else { return }

        if state.offset == 0,
           candidate.fileSize > UInt64(configuration.maxInitialFileBytes) {
            try ingestOversizedInitialFile(candidate, into: &state)
            return
        }

        let handle = try FileHandle(forReadingFrom: candidate.url)
        defer { try? handle.close() }
        try handle.seek(toOffset: state.offset)
        let data = try handle.readToEnd() ?? Data()
        state.offset += UInt64(data.count)
        consume(data, into: &state, discardLeadingPartialLine: false)
    }

    private func ingestOversizedInitialFile(
        _ candidate: RolloutCandidate,
        into state: inout SessionState
    ) throws {
        let handle = try FileHandle(forReadingFrom: candidate.url)
        defer { try? handle.close() }

        // The first rollout line is session_meta. Read a bounded header window;
        // current Codex metadata is much smaller than this cap.
        let headerLimit = min(configuration.maxInitialFileBytes, 512 * 1_024)
        let header = try handle.read(upToCount: headerLimit) ?? Data()
        if let newline = header.firstIndex(of: 0x0A) {
            decodeLine(Data(header[..<newline]), into: &state)
        } else {
            state.discardedRecordCount += 1
        }

        let tailSize = min(
            UInt64(configuration.oversizedFileTailBytes),
            candidate.fileSize
        )
        let tailOffset = candidate.fileSize - tailSize
        try handle.seek(toOffset: tailOffset)
        let tail = try handle.readToEnd() ?? Data()
        state.offset = candidate.fileSize
        state.partialLine.removeAll(keepingCapacity: false)
        consume(
            tail,
            into: &state,
            discardLeadingPartialLine: tailOffset > 0
        )
    }

    private func consume(
        _ newData: Data,
        into state: inout SessionState,
        discardLeadingPartialLine: Bool
    ) {
        guard !newData.isEmpty else { return }

        var data = Data()
        if !discardLeadingPartialLine {
            data.append(state.partialLine)
        }
        data.append(newData)
        state.partialLine.removeAll(keepingCapacity: true)

        var lineStart = data.startIndex
        if discardLeadingPartialLine,
           let firstNewline = data.firstIndex(of: 0x0A) {
            lineStart = data.index(after: firstNewline)
        }

        while lineStart < data.endIndex,
              let newline = data[lineStart...].firstIndex(of: 0x0A) {
            if newline > lineStart {
                decodeLine(Data(data[lineStart..<newline]), into: &state)
            }
            lineStart = data.index(after: newline)
        }

        if lineStart < data.endIndex {
            state.partialLine = Data(data[lineStart...])
        }
    }

    private func decodeLine(_ data: Data, into state: inout SessionState) {
        guard !data.isEmpty else { return }
        do {
            let envelope = try JSONDecoder().decode(RolloutEnvelope.self, from: data)
            apply(envelope, to: &state)
        } catch {
            // Count only. Never log or retain the malformed line.
            state.discardedRecordCount += 1
        }
    }

    private func apply(_ envelope: RolloutEnvelope, to state: inout SessionState) {
        let timestamp = parseDate(envelope.timestamp) ?? state.modificationDate ?? Date()
        state.lastEventAt = max(state.lastEventAt ?? .distantPast, timestamp)

        switch envelope.type {
        case "session_meta":
            // Child rollouts contain inherited parent metadata after their own
            // metadata. The first session_meta is the identity of this file.
            if state.identity == nil, let rawID = envelope.payload.id {
                let isSubagent = envelope.payload.parentThreadID != nil
                    || envelope.payload.agentPath != nil
                state.identity = SessionIdentity(
                    rawID: rawID,
                    rawParentID: envelope.payload.parentThreadID,
                    displayName: sanitizedNickname(envelope.payload.agentNickname),
                    role: isSubagent ? .subagent : .primary
                )
                state.workspaceURL = sanitizedWorkspaceURL(envelope.payload.cwd)
            }

        case "turn_context":
            if let workspace = sanitizedWorkspaceURL(envelope.payload.cwd) {
                state.workspaceURL = workspace
            }

        case "event_msg":
            applyEventMessage(envelope.payload, timestamp: timestamp, to: &state)

        case "response_item":
            applyResponseItem(envelope.payload, timestamp: timestamp, to: &state)

        case "inter_agent_communication_metadata":
            inferActiveTurnIfNeeded(timestamp: timestamp, in: &state)
            state.signal = .communicating

        default:
            break
        }
    }

    private func applyEventMessage(
        _ payload: RolloutPayload,
        timestamp: Date,
        to state: inout SessionState
    ) {
        switch payload.type {
        case "task_started":
            state.lifecycle = .started
            state.startedAt = timestamp
            state.signal = .starting
        case "task_complete":
            state.lifecycle = .completed
            state.signal = .finished
        case "turn_aborted":
            state.lifecycle = .aborted
            state.signal = .interrupted
        case "sub_agent_activity":
            inferActiveTurnIfNeeded(timestamp: timestamp, in: &state)
            state.signal = .communicating
        case "web_search_end", "mcp_tool_call_end", "patch_apply_end":
            inferActiveTurnIfNeeded(timestamp: timestamp, in: &state)
            state.signal = .working
        case "token_count":
            inferActiveTurnIfNeeded(timestamp: timestamp, in: &state)
            if state.signal == .waiting { state.signal = .thinking }
        default:
            break
        }
    }

    private func applyResponseItem(
        _ payload: RolloutPayload,
        timestamp: Date,
        to state: inout SessionState
    ) {
        switch payload.type {
        case "reasoning":
            inferActiveTurnIfNeeded(timestamp: timestamp, in: &state)
            state.signal = .thinking
        case "function_call", "custom_tool_call", "tool_search_call", "web_search_call":
            inferActiveTurnIfNeeded(timestamp: timestamp, in: &state)
            if let location = toolLocation(from: payload) {
                state.locationURL = location
            }
            state.signal = .usingTool
        case "function_call_output", "custom_tool_call_output", "tool_search_output":
            inferActiveTurnIfNeeded(timestamp: timestamp, in: &state)
            state.signal = .working
        case "agent_message":
            inferActiveTurnIfNeeded(timestamp: timestamp, in: &state)
            state.signal = .communicating
        default:
            break
        }
    }

    /// Oversized rollouts are intentionally opened from a bounded tail on a
    /// cold launch. The turn's original `task_started` record can therefore sit
    /// outside that tail even while fresh allowlisted activity is arriving.
    /// A recognized non-terminal event is sufficient to recover the active
    /// lifecycle; a later terminal event in the same tail still wins.
    private func inferActiveTurnIfNeeded(
        timestamp: Date,
        in state: inout SessionState
    ) {
        guard state.lifecycle == nil else { return }
        state.lifecycle = .started
        state.startedAt = timestamp
    }

    /// Extract only a filesystem location from structured local-tool fields.
    /// The raw argument or patch string is never retained in SessionState.
    private func toolLocation(from payload: RolloutPayload) -> URL? {
        switch payload.name {
        case "exec_command":
            return jsonPathField("workdir", from: payload.arguments)
        case "view_image":
            return jsonPathField("path", from: payload.arguments)
        case "apply_patch":
            return patchTarget(from: payload.input)
        default:
            return nil
        }
    }

    private func jsonPathField(_ field: String, from arguments: String?) -> URL? {
        guard let arguments,
              arguments.utf8.count <= 64 * 1_024,
              let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let value = dictionary[field] as? String
        else { return nil }
        return sanitizedWorkspaceURL(value)
    }

    private func patchTarget(from input: String?) -> URL? {
        guard let input else { return nil }
        // Patch headers precede file content. Bound the inspected prefix so a
        // large patch cannot become retained telemetry.
        let prefix = String(input.prefix(16 * 1_024))
        let markers = [
            "*** Update File: ",
            "*** Add File: ",
            "*** Delete File: ",
            "*** Move to: "
        ]
        for line in prefix.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            for marker in markers where text.hasPrefix(marker) {
                return sanitizedWorkspaceURL(String(text.dropFirst(marker.count)))
            }
        }
        return nil
    }

    private func activity(from state: SessionState, now: Date) -> CodexAgentActivity? {
        guard let identity = state.identity,
              let lastEventAt = state.lastEventAt,
              let lifecycle = state.lifecycle else { return nil }

        let age = max(0, now.timeIntervalSince(lastEventAt))
        let publicLifecycle: CodexAgentLifecycle

        switch lifecycle {
        case .started:
            if age <= configuration.staleAfter {
                publicLifecycle = .active
            } else if age <= configuration.staleAfter + configuration.staleRetention {
                publicLifecycle = .stale
            } else {
                return nil
            }
        case .completed:
            guard age <= configuration.completedRetention else { return nil }
            publicLifecycle = .completed
        case .aborted:
            guard age <= configuration.completedRetention else { return nil }
            publicLifecycle = .aborted
        }

        let displayName: String
        if let nickname = identity.displayName {
            displayName = nickname
        } else if identity.role == .subagent {
            displayName = "Codex Agent"
        } else {
            displayName = "Codex"
        }

        return CodexAgentActivity(
            id: pseudonymousID(identity.rawID),
            parentID: identity.rawParentID.map(pseudonymousID),
            displayName: displayName,
            role: identity.role,
            lifecycle: publicLifecycle,
            signal: state.signal,
            workspaceURL: state.workspaceURL,
            locationURL: state.locationURL,
            startedAt: state.startedAt,
            lastEventAt: lastEventAt
        )
    }

    private func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return fractionalISO8601.date(from: value) ?? plainISO8601.date(from: value)
    }
}

// MARK: - Private rollout models

private struct DiscoveryResult {
    let files: [RolloutCandidate]
    let failedResourceReads: Int
}

private struct RolloutCandidate {
    let url: URL
    let modificationDate: Date
    let fileSize: UInt64
}

private struct SessionIdentity {
    let rawID: String
    let rawParentID: String?
    let displayName: String?
    let role: CodexAgentRole
}

private enum PrivateLifecycle {
    case started
    case completed
    case aborted
}

private struct SessionState {
    var offset: UInt64 = 0
    var partialLine = Data()
    var identity: SessionIdentity?
    var lifecycle: PrivateLifecycle?
    var signal: CodexAgentSignal = .waiting
    var workspaceURL: URL?
    var locationURL: URL?
    var startedAt: Date?
    var lastEventAt: Date?
    var modificationDate: Date?
    var discardedRecordCount = 0
}

private struct RolloutEnvelope: Decodable {
    let timestamp: String?
    let type: String
    let payload: RolloutPayload
}

/// Only allowlisted metadata plus transient local-tool fields are represented.
/// Raw argument/input strings are inspected only long enough to extract one
/// sanitized absolute location and are never copied into SessionState.
private struct RolloutPayload: Decodable {
    let type: String?
    let id: String?
    let name: String?
    let arguments: String?
    let input: String?
    let parentThreadID: String?
    let agentNickname: String?
    let agentPath: String?
    let cwd: String?

    enum CodingKeys: String, CodingKey {
        case type
        case id
        case name
        case arguments
        case input
        case parentThreadID = "parent_thread_id"
        case agentNickname = "agent_nickname"
        case agentPath = "agent_path"
        case cwd
    }
}

// MARK: - Privacy helpers

private func sanitizedNickname(_ value: String?) -> String? {
    guard let value else { return nil }
    let scalars = value.unicodeScalars.filter { scalar in
        !CharacterSet.controlCharacters.contains(scalar)
            && !CharacterSet.newlines.contains(scalar)
    }
    let cleaned = String(String.UnicodeScalarView(scalars))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return nil }
    return String(cleaned.prefix(48))
}

private func sanitizedWorkspaceURL(_ value: String?) -> URL? {
    guard let value,
          value.utf8.count <= 4_096,
          value.hasPrefix("/"),
          value.unicodeScalars.allSatisfy({
              !CharacterSet.controlCharacters.contains($0)
          }) else { return nil }
    return URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
}

private func pseudonymousID(_ raw: String) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in raw.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x100000001b3
    }
    return String(format: "codex-%016llx", hash)
}
