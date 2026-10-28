import Testing
import Foundation
import OSLog
import SharedLogging

@Suite("Batch 2: SharedLogging Tests")
struct SharedLoggingTests {

    @Test("Subsystem identity equals com.apexsuite")
    func testSubsystemIdentity() {
        #expect(SharedLogger.subsystem == "com.apexsuite")
    }

    @Test("All 5 logger categories initialize cleanly")
    func testLoggerCategoriesInitialization() {
        let loggers: [Logger] = [
            SharedLogger.ai,
            SharedLogger.mcp,
            SharedLogger.data,
            SharedLogger.ui,
            SharedLogger.git
        ]
        #expect(loggers.count == 5)
    }

    @Test("Emission of debug and info log messages executes without throwing or crashing")
    func testLogEmission() {
        SharedLogger.ai.debug("AI log debug verification")
        SharedLogger.ai.info("AI log info verification")
        SharedLogger.mcp.debug("MCP log debug verification")
        SharedLogger.mcp.info("MCP log info verification")
        SharedLogger.data.debug("Data log debug verification")
        SharedLogger.data.info("Data log info verification")
        SharedLogger.ui.debug("UI log debug verification")
        SharedLogger.ui.info("UI log info verification")
        SharedLogger.git.debug("Git log debug verification")
        SharedLogger.git.info("Git log info verification")
    }
}
