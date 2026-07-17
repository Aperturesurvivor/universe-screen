import XCTest
import simd
@testable import Universe_Screen

final class StableHashTests: XCTestCase {
    func testStableHashIsDeterministic() {
        XCTAssertEqual(stableHash("Universe-Screen"), stableHash("Universe-Screen"))
        XCTAssertNotEqual(stableHash("Universe-Screen"), stableHash("Signal-Lab"))
    }

    func testToolActivityMovesADockedShip() {
        var ship = AgentBody(
            stableId: "test-agent",
            name: "Test",
            startPosition: .zero,
            targetPosition: SIMD3(100, 0, 100),
            progress: 1,
            phase: 0,
            activityMode: .usingTool)
        let before = ship.position

        ship.advanceJourney(deltaTime: 0.5)

        XCTAssertGreaterThan(simd_distance(before, ship.position), 1)
    }

    func testActivityTransitionRestartsTheMotionCue() {
        var ship = AgentBody(
            stableId: "test-agent",
            name: "Test",
            startPosition: .zero,
            targetPosition: SIMD3(100, 0, 100),
            progress: 1,
            activityMode: .working,
            activityTime: 3,
            activityPulse: 0)

        ship.setActivityMode(.communicating)

        XCTAssertEqual(ship.activityMode, .communicating)
        XCTAssertEqual(ship.activityTime, 0)
        XCTAssertEqual(ship.activityPulse, 1)
    }

    @MainActor
    func testAgentRetargetsWhenItsFileLocationChanges() {
        let projectURL = URL(fileURLWithPath: "/tmp/Universe-Demo/Project")
        let universe = Universe(seed: Seed(value: 42))
        universe.update(
            folders: [
                FolderInfo(
                    url: projectURL,
                    sizeBytes: 1_000_000,
                    biome: .rocky,
                    iconPosition: nil)
            ],
            files: [],
            screenSize: CGSize(width: 1_200, height: 800))

        let now = Date()
        let first = CodexAgentActivity(
            id: "agent",
            parentID: nil,
            displayName: "Codex",
            role: .primary,
            lifecycle: .active,
            signal: .usingTool,
            workspaceURL: projectURL,
            locationURL: projectURL.appendingPathComponent("Sources/First.swift"),
            startedAt: now,
            lastEventAt: now)
        universe.updateAgents(from: [first])
        let firstTarget = universe.agents[0].targetPosition

        let second = CodexAgentActivity(
            id: "agent",
            parentID: nil,
            displayName: "Codex",
            role: .primary,
            lifecycle: .active,
            signal: .usingTool,
            workspaceURL: projectURL,
            locationURL: projectURL.appendingPathComponent("Tests/Second.swift"),
            startedAt: now,
            lastEventAt: now)
        universe.updateAgents(from: [second])

        XCTAssertGreaterThan(
            simd_distance(firstTarget, universe.agents[0].targetPosition),
            20)
        XCTAssertEqual(universe.agents[0].progress, 0)
    }
}

@MainActor
final class CodexActivityMonitorTests: XCTestCase {
    func testOversizedActiveRolloutRecoversWithoutTaskStartedInTail() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        let now = ISO8601DateFormatter().string(from: Date())
        let header = """
        {"timestamp":"\(now)","type":"session_meta","payload":{"id":"active-session","cwd":"/Users/Shared/Universe-Demo/Universe-Screen"}}

        """
        let oldStart = """
        {"timestamp":"\(now)","type":"event_msg","payload":{"type":"task_started"}}

        """
        let filler = String(repeating: """
        {"timestamp":"\(now)","type":"ignored","payload":{}}

        """, count: 2_000)
        let recentActivity = """
        {"timestamp":"\(now)","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\\\"workdir\\\":\\\"/Users/Shared/Universe-Demo/Universe-Screen/Sources\\\",\\\"cmd\\\":\\\"private command text\\\"}"}}

        """
        let file = root.appendingPathComponent("rollout.jsonl")
        try (header + oldStart + filler + recentActivity).write(
            to: file,
            atomically: true,
            encoding: .utf8)

        let configuration = CodexActivityMonitorConfiguration(
            pollInterval: 1,
            discoveryLookback: 3_600,
            staleAfter: 900,
            completedRetention: 12,
            staleRetention: 60,
            maxTrackedFiles: 4,
            maxInitialFileBytes: 64 * 1_024,
            oversizedFileTailBytes: 64 * 1_024)
        let monitor = CodexActivityMonitor(
            sessionsDirectory: root,
            configuration: configuration)

        await monitor.refreshNow()

        XCTAssertEqual(monitor.snapshot.activeCount, 1)
        XCTAssertEqual(monitor.snapshot.activeAgents.first?.signal, .usingTool)
        XCTAssertEqual(
            monitor.snapshot.activeAgents.first?.locationURL?.path,
            "/Users/Shared/Universe-Demo/Universe-Screen/Sources")
    }
}

@MainActor
final class DashboardModelTests: XCTestCase {
    func testPrivacyModeRedactsTheSourcePath() {
        let model = DashboardModel(
            rootURL: URL(fileURLWithPath: "/Users/Shared/Universe-Demo"),
            privacyMode: true)

        XCTAssertEqual(model.sourceName, "Universe-Demo")
        XCTAssertEqual(model.sourceDisplayPath, "Full path hidden")
    }

    func testVisibleWorldLimitIsClamped() {
        let low = DashboardModel(worldLimit: 1)
        let high = DashboardModel(worldLimit: 200)

        XCTAssertEqual(low.worldLimit, 4)
        XCTAssertEqual(high.worldLimit, 48)
    }
}
