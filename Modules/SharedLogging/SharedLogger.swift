import Foundation
import OSLog

public enum SharedLogger {
    public static let subsystem = "com.apexsuite"

    public static let ai   = Logger(subsystem: subsystem, category: "AI")
    public static let mcp  = Logger(subsystem: subsystem, category: "MCP")
    public static let data = Logger(subsystem: subsystem, category: "Data")
    public static let ui   = Logger(subsystem: subsystem, category: "UI")
    public static let git  = Logger(subsystem: subsystem, category: "Git")
}
