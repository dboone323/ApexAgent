import Foundation

/// Live-test support (zero-mock policy): resolves the REAL filesystem MCP
/// server installed on this machine. Tests never fake an MCP server. When the
/// real server cannot be located, callers report "no MCP found" and the test
/// fails with that message instead of substituting a simulation.
enum LiveMCP {
    /// Locates an executable `npx` on this machine.
    static func findNpx() -> String? {
        let fm = FileManager.default
        for candidate in ["/opt/homebrew/bin/npx", "/usr/local/bin/npx"] where fm.isExecutableFile(atPath: candidate) {
            return candidate
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["npx"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// Returns the real filesystem MCP server launch configuration rooted at
    /// `root`, or nil when the toolchain is unavailable ("no MCP found").
    static func filesystemServer(root: String) -> (command: String, arguments: [String])? {
        guard let npx = findNpx() else { return nil }
        return (npx, ["-y", "@modelcontextprotocol/server-filesystem", root])
    }

    /// Creates a real temp directory for the server to serve.
    static func makeWorkspace() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("live_mcp_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
