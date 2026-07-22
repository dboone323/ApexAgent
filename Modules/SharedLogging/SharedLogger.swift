import Foundation
import OSLog

public enum SharedLogger {
    public static let ai   = Logger(subsystem: "com.apexsuite", category: "AI")
    public static let mcp  = Logger(subsystem: "com.apexsuite", category: "MCP")
    public static let data = Logger(subsystem: "com.apexsuite", category: "Data")
    public static let ui   = Logger(subsystem: "com.apexsuite", category: "UI")
    public static let git  = Logger(subsystem: "com.apexsuite", category: "Git")
}
