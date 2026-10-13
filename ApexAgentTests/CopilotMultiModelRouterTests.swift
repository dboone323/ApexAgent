import XCTest
@testable import ApexAgentCore

final class CopilotMultiModelRouterTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        await CopilotMultiModelRouter.shared.recordSuccess()
        await CopilotTokenWatchdog.shared.stopWatchdog()
    }

    override func tearDown() async throws {
        await CopilotMultiModelRouter.shared.recordSuccess()
        await CopilotTokenWatchdog.shared.stopWatchdog()
        try await super.tearDown()
    }

    func testAllCopilotModelsHaveValidDisplayNames() {
        for model in CopilotModel.allCases {
            XCTAssertFalse(model.displayName.isEmpty, "DisplayName should not be empty for \(model)")
            XCTAssertFalse(model.rawValue.isEmpty, "RawValue should not be empty for \(model)")
        }
    }

    func testStreamingCapabilityMapping() {
        XCTAssertTrue(CopilotModel.gpt4o.supportsStreaming)
        XCTAssertFalse(CopilotModel.o1Preview.supportsStreaming)
        XCTAssertFalse(CopilotModel.o1Mini.supportsStreaming)
        XCTAssertTrue(CopilotModel.claude35Sonnet.supportsStreaming)
    }

    func testToolCallingCapabilityMapping() {
        XCTAssertTrue(CopilotModel.gpt4o.supportsToolCalling)
        XCTAssertTrue(CopilotModel.claude35Sonnet.supportsToolCalling)
        XCTAssertFalse(CopilotModel.o1Preview.supportsToolCalling)
        XCTAssertFalse(CopilotModel.o1Mini.supportsToolCalling)
    }

    func testModelSelectionCascadeForToolCalling() async {
        let selected = await CopilotMultiModelRouter.shared.selectModel(
            preferred: .o1Preview,
            requiresToolCalling: true,
            requiresStreaming: false
        )
        XCTAssertEqual(selected, .gpt4o)
    }

    func testModelSelectionCascadeForStreaming() async {
        let selected = await CopilotMultiModelRouter.shared.selectModel(
            preferred: .o1Mini,
            requiresToolCalling: false,
            requiresStreaming: true
        )
        XCTAssertEqual(selected, .gpt4o)
    }

    func testPreferredModelRetainedWhenCapable() async {
        let selected = await CopilotMultiModelRouter.shared.selectModel(
            preferred: .claude35Sonnet,
            requiresToolCalling: true,
            requiresStreaming: true
        )
        XCTAssertEqual(selected, .claude35Sonnet)
    }

    func testExponentialBackoffProgression() async {
        for _ in 1...5 {
            await CopilotMultiModelRouter.shared.recordFailure(httpStatus: 429)
        }
        let delayAfterFailures = await CopilotMultiModelRouter.shared.exponentialBackoffDelay()
        XCTAssertEqual(delayAfterFailures, 32.0, "2^5 exponential backoff should equal 32.0 seconds")

        await CopilotMultiModelRouter.shared.recordSuccess()
        let resetDelay = await CopilotMultiModelRouter.shared.exponentialBackoffDelay()
        XCTAssertLessThan(resetDelay, 2.0, "Reset delay after success should be less than 2.0 seconds")
    }

    func testIsRateLimitedAfterFailure() async {
        await CopilotMultiModelRouter.shared.recordFailure(httpStatus: 429)
        let isLimited = await CopilotMultiModelRouter.shared.isRateLimited()
        XCTAssertTrue(isLimited)
    }

    func testRequestHeadersContainRequiredFields() async {
        let headers = await CopilotMultiModelRouter.shared.buildRequestHeaders(
            sessionToken: "test-token-123",
            model: .gpt4o
        )
        XCTAssertNotNil(headers["Authorization"])
        XCTAssertEqual(headers["Authorization"], "Bearer test-token-123")
        XCTAssertNotNil(headers["Editor-Version"])
        XCTAssertEqual(headers["Editor-Version"], "vscode/1.90.0")
        XCTAssertNotNil(headers["Content-Type"])
        XCTAssertEqual(headers["Content-Type"], "application/json")
        XCTAssertNotNil(headers["X-GitHub-Api-Version"])
        XCTAssertEqual(headers["X-GitHub-Api-Version"], "2022-11-28")
        XCTAssertEqual(headers["Accept"], "text/event-stream")
    }

    func testRouterAuditReport() {
        let report = CopilotRouterAuditReport.audit()
        XCTAssertTrue(report.passed)
        XCTAssertEqual(report.availableModels.count, CopilotModel.allCases.count)
        XCTAssertEqual(report.score, 100.0)
    }

    func testTokenWatchdogStartStop() async {
        await CopilotTokenWatchdog.shared.startWatchdog()
        let isRunningAfterStart = await CopilotTokenWatchdog.shared.isRunning
        XCTAssertTrue(isRunningAfterStart)

        await CopilotTokenWatchdog.shared.stopWatchdog()
        let isRunningAfterStop = await CopilotTokenWatchdog.shared.isRunning
        XCTAssertFalse(isRunningAfterStop)
    }
}
