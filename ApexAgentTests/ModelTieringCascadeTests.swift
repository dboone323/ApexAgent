// ModelTieringCascadeTests.swift
// Batch 125: Functional tests for ModelTieringCascade and TurnLoopWatchdog.

import XCTest
@testable import ApexAgentCore

final class ModelTieringCascadeTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        await ModelTieringCascade.shared.resetAll()
        await TurnLoopWatchdog.shared.resetAll()
    }

    override func tearDown() async throws {
        await ModelTieringCascade.shared.resetAll()
        await TurnLoopWatchdog.shared.resetAll()
        try await super.tearDown()
    }

    // MARK: - 1. Model Tiering Cascade Tests

    func testInitialHealthIsHealthy() async {
        let health = await ModelTieringCascade.shared.getHealth(for: .gitHubCopilot)
        XCTAssertEqual(health.provider, .gitHubCopilot)
        XCTAssertEqual(health.status, .healthy)
        XCTAssertEqual(health.consecutiveFailures, 0)
        XCTAssertTrue(health.isAvailable)
        XCTAssertNil(health.rateLimitUntil)
    }

    func testRecordFailureTransitionsToDegradedThenOffline() async {
        // 1st failure -> degraded
        await ModelTieringCascade.shared.recordFailure(for: .cloudGemini)
        let h1 = await ModelTieringCascade.shared.getHealth(for: .cloudGemini)
        XCTAssertEqual(h1.status, .degraded)
        XCTAssertEqual(h1.consecutiveFailures, 1)
        XCTAssertTrue(h1.isAvailable)

        // 2nd failure -> degraded
        await ModelTieringCascade.shared.recordFailure(for: .cloudGemini)
        let h2 = await ModelTieringCascade.shared.getHealth(for: .cloudGemini)
        XCTAssertEqual(h2.status, .degraded)
        XCTAssertEqual(h2.consecutiveFailures, 2)
        XCTAssertTrue(h2.isAvailable)

        // 3rd failure -> offline
        await ModelTieringCascade.shared.recordFailure(for: .cloudGemini)
        let h3 = await ModelTieringCascade.shared.getHealth(for: .cloudGemini)
        XCTAssertEqual(h3.status, .offline)
        XCTAssertEqual(h3.consecutiveFailures, 3)
        XCTAssertFalse(h3.isAvailable)
    }

    func testRecordRateLimitSetsRateLimitedStatus() async {
        await ModelTieringCascade.shared.recordFailure(
            for: .gitHubCopilot,
            isRateLimit: true,
            rateLimitDuration: 120
        )
        let health = await ModelTieringCascade.shared.getHealth(for: .gitHubCopilot)
        XCTAssertEqual(health.status, .rateLimited)
        XCTAssertFalse(health.isAvailable)
        XCTAssertNotNil(health.rateLimitUntil)
        if let until = health.rateLimitUntil {
            XCTAssertGreaterThan(until, Date())
        }
    }

    func testRecordSuccessRestoresHealthy() async {
        // Move to offline first
        await ModelTieringCascade.shared.recordFailure(for: .localOllama)
        await ModelTieringCascade.shared.recordFailure(for: .localOllama)
        await ModelTieringCascade.shared.recordFailure(for: .localOllama)
        let offlineHealth = await ModelTieringCascade.shared.getHealth(for: .localOllama)
        XCTAssertEqual(offlineHealth.status, .offline)
        XCTAssertFalse(offlineHealth.isAvailable)

        // Record success -> back to healthy
        await ModelTieringCascade.shared.recordSuccess(for: .localOllama)
        let restored = await ModelTieringCascade.shared.getHealth(for: .localOllama)
        XCTAssertEqual(restored.status, .healthy)
        XCTAssertEqual(restored.consecutiveFailures, 0)
        XCTAssertTrue(restored.isAvailable)
        XCTAssertNil(restored.rateLimitUntil)
    }

    func testCascadeResolvesRequestedWhenHealthy() async {
        let result = await ModelTieringCascade.shared.resolveActiveProvider(requested: .cloudGemini)
        XCTAssertEqual(result.provider, .cloudGemini)
        XCTAssertEqual(result.reason, "Requested provider is healthy")
    }

    func testCascadeFallsBackWhenCopilotRateLimited() async {
        await ModelTieringCascade.shared.recordFailure(for: .gitHubCopilot, isRateLimit: true)
        let result = await ModelTieringCascade.shared.resolveActiveProvider(requested: .gitHubCopilot)
        XCTAssertEqual(result.provider, .cloudGemini)
        XCTAssertTrue(result.reason.contains("Failover"))

        let defaultLadderResult = await ModelTieringCascade.shared.resolveActiveProvider()
        XCTAssertEqual(defaultLadderResult.provider, .cloudGemini)
    }

    func testCascadeFallsBackToOllamaWhenGeminiMissingKey() async {
        await ModelTieringCascade.shared.recordFailure(for: .gitHubCopilot, isRateLimit: true)
        let result = await ModelTieringCascade.shared.resolveActiveProvider(hasGeminiKey: false)
        XCTAssertEqual(result.provider, .localOllama)
    }

    func testCascadeFallsBackToAppleOnDeviceWhenAllOffline() async {
        // Set higher tier engines offline
        for _ in 1...3 {
            await ModelTieringCascade.shared.recordFailure(for: .gitHubCopilot)
            await ModelTieringCascade.shared.recordFailure(for: .cloudGemini)
            await ModelTieringCascade.shared.recordFailure(for: .localOllama)
        }

        let result = await ModelTieringCascade.shared.resolveActiveProvider()
        XCTAssertEqual(result.provider, .appleOnDevice)
        XCTAssertEqual(result.reason, "All higher tier engines unavailable; defaulted to on-device AFM")
    }

    // MARK: - 2. Turn Loop Watchdog Tests

    func testWatchdogAllowsLinearChainUnderMaxDepth() async throws {
        let watchdog = TurnLoopWatchdog(maxDepth: 6)
        let spaceId = UUID()

        for _ in 1...6 {
            try await watchdog.recordTurn(spaceId: spaceId, fromBotId: nil, toBotId: UUID())
        }

        let count = await watchdog.turnCount(spaceId: spaceId)
        XCTAssertEqual(count, 6)
    }

    func testWatchdogThrowsWhenExceedingMaxDepth() async throws {
        let watchdog = TurnLoopWatchdog(maxDepth: 3)
        let spaceId = UUID()

        for _ in 1...3 {
            try await watchdog.recordTurn(spaceId: spaceId, fromBotId: nil, toBotId: UUID())
        }

        do {
            try await watchdog.recordTurn(spaceId: spaceId, fromBotId: nil, toBotId: UUID())
            XCTFail("Expected maxDepthExceeded error")
        } catch let error as TurnLoopViolation {
            XCTAssertEqual(error, .maxDepthExceeded(depth: 4, maxAllowed: 3))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testWatchdogThrowsOnRunawayPingPong() async throws {
        let watchdog = TurnLoopWatchdog(pingPongThreshold: 3)
        let spaceId = UUID()
        let botA = UUID()
        let botB = UUID()

        try await watchdog.recordTurn(spaceId: spaceId, fromBotId: nil, toBotId: botA)
        try await watchdog.recordTurn(spaceId: spaceId, fromBotId: botA, toBotId: botB)
        try await watchdog.recordTurn(spaceId: spaceId, fromBotId: botB, toBotId: botA)
        try await watchdog.recordTurn(spaceId: spaceId, fromBotId: botA, toBotId: botB)

        do {
            try await watchdog.recordTurn(spaceId: spaceId, fromBotId: botB, toBotId: botA)
            XCTFail("Expected runawayPingPong error")
        } catch let error as TurnLoopViolation {
            XCTAssertEqual(error, .runawayPingPong(botA: botA, botB: botB, repetitions: 3))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testWatchdogThrowsOnCyclicLoop() async throws {
        let watchdog = TurnLoopWatchdog(maxDepth: 10)
        let spaceId = UUID()
        let botA = UUID()
        let botB = UUID()
        let botC = UUID()

        try await watchdog.recordTurn(spaceId: spaceId, fromBotId: nil, toBotId: botA)
        try await watchdog.recordTurn(spaceId: spaceId, fromBotId: botA, toBotId: botB)
        try await watchdog.recordTurn(spaceId: spaceId, fromBotId: botB, toBotId: botC)
        try await watchdog.recordTurn(spaceId: spaceId, fromBotId: botC, toBotId: botA)
        try await watchdog.recordTurn(spaceId: spaceId, fromBotId: botA, toBotId: botB)

        do {
            try await watchdog.recordTurn(spaceId: spaceId, fromBotId: botB, toBotId: botC)
            XCTFail("Expected cyclicLoopDetected error")
        } catch let error as TurnLoopViolation {
            XCTAssertEqual(error, .cyclicLoopDetected(cycle: [botA, botB, botC]))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testWatchdogResetClearsTurnCount() async throws {
        let watchdog = TurnLoopWatchdog()
        let spaceId = UUID()

        try await watchdog.recordTurn(spaceId: spaceId, fromBotId: nil, toBotId: UUID())
        let before = await watchdog.turnCount(spaceId: spaceId)
        XCTAssertEqual(before, 1)

        await watchdog.reset(spaceId: spaceId)
        let after = await watchdog.turnCount(spaceId: spaceId)
        XCTAssertEqual(after, 0)
    }

    // MARK: - 3. BotProfile Extension Tests

    func testBotProfileCustomModelIdentifierCanBeAssigned() {
        let bot = BotProfile(name: "CoderBot", title: "Senior Engineer")
        XCTAssertNil(bot.customModelIdentifier)

        bot.customModelIdentifier = "claude-3.5-sonnet"
        XCTAssertEqual(bot.customModelIdentifier, "claude-3.5-sonnet")

        bot.customModelIdentifier = "gemini-3.1-pro"
        XCTAssertEqual(bot.customModelIdentifier, "gemini-3.1-pro")

        bot.customModelIdentifier = "gpt-4o"
        XCTAssertEqual(bot.customModelIdentifier, "gpt-4o")

        bot.customModelIdentifier = nil
        XCTAssertNil(bot.customModelIdentifier)
    }
}
