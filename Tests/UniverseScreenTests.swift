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

final class DemoManifestTests: XCTestCase {
    private var demoDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Demo", isDirectory: true)
    }

    func testCheckedInManifestIsPublicSafeAndDeterministic() throws {
        let manifestURL = demoDirectory.appendingPathComponent("sample-manifest.json")
        let manifest = try DemoManifest.decode(contentsOf: manifestURL)

        XCTAssertEqual(manifest.provenance.classification, "synthetic-public-safe")
        XCTAssertTrue(manifest.provenance.humanReviewRequiredBeforeCommercialExport)

        let first = try manifest.makeScene(screenSize: CGSize(width: 1_920, height: 1_080))
        let second = try manifest.makeScene(screenSize: CGSize(width: 1_920, height: 1_080))
        XCTAssertEqual(first.manifestID, second.manifestID)
        XCTAssertEqual(first.seed, second.seed)
        XCTAssertEqual(first.folders.map(\.url), second.folders.map(\.url))
        XCTAssertEqual(first.files.map(\.url), second.files.map(\.url))
        XCTAssertEqual(first.agents, second.agents)
        XCTAssertTrue(first.folders.allSatisfy {
            $0.url.path.hasPrefix("/UniverseScreenSyntheticDemo/")
        })
        XCTAssertTrue(first.agents.allSatisfy {
            $0.id.hasPrefix("synthetic-") && $0.workspaceURL?.path.hasPrefix("/UniverseScreenSyntheticDemo/") == true
        })
    }

    func testManifestRejectsPathLikeLabel() throws {
        let manifestURL = demoDirectory.appendingPathComponent("sample-manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let original = try XCTUnwrap(String(data: data, encoding: .utf8))
        let unsafe = original.replacingOccurrences(
            of: "\"Navigator\"",
            with: "\"/Users/example/private\"")
        let decoded = try JSONDecoder().decode(
            DemoManifest.self,
            from: try XCTUnwrap(unsafe.data(using: .utf8)))

        XCTAssertThrowsError(try decoded.validated())
    }

    func testCommercialExportPresetIsExactlyFifteenSecond1080p() throws {
        let presetURL = demoDirectory.appendingPathComponent("export-1080p-15s.json")
        let preset = try DemoExportPreset.decode(contentsOf: presetURL)

        XCTAssertEqual(preset.durationSeconds, 15)
        XCTAssertEqual(preset.width, 1_920)
        XCTAssertEqual(preset.height, 1_080)
        XCTAssertEqual(preset.framesPerSecond, 30)
        XCTAssertEqual(preset.expectedFrameCount, 450)
        XCTAssertEqual(preset.container, "mp4")
        XCTAssertEqual(preset.codec, "h264")
        XCTAssertEqual(preset.audio, "none")
    }

    func testDemoFilesAreBundledWithTheApplication() throws {
        XCTAssertNotNil(DemoManifest.bundledSampleURL())
        XCTAssertNotNil(DemoExportPreset.bundledURL())
    }
}
