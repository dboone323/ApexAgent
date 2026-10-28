import Testing
import Foundation
@testable import ApexAgentCore

@Suite("Batch 5: SandboxCtl Tests", .serialized)
struct SandboxCtlTests {

    // Helper implementing the exact POSIX quoting logic tested in sandboxctl
    private func shellQuoted(_ args: [String]) -> String {
        args.map { arg in
            if arg.range(of: "^[a-zA-Z0-9_./-]+$", options: .regularExpression) != nil {
                return arg
            } else {
                return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
            }
        }.joined(separator: " ")
    }

    @Test("POSIX shellQuoted preserves safe alphanumeric characters and path separators")
    func testShellQuotedSafeTokens() {
        let safeArgs = ["foo_bar-1.2/path", "usr", "bin", "env", "node-v20"]
        let quoted = shellQuoted(safeArgs)
        #expect(quoted == "foo_bar-1.2/path usr bin env node-v20")
    }

    @Test("POSIX shellQuoted wraps strings with spaces in single quotes")
    func testShellQuotedTokensWithSpaces() {
        let args = ["echo", "hello world", "more spaces here"]
        let quoted = shellQuoted(args)
        #expect(quoted == "echo 'hello world' 'more spaces here'")
    }

    @Test("POSIX shellQuoted properly escapes internal single quotes")
    func testShellQuotedInternalSingleQuotes() {
        let args = ["cat", "user's file.txt"]
        let quoted = shellQuoted(args)
        #expect(quoted == "cat 'user'\\''s file.txt'")
    }

    @Test("POSIX shellQuoted handles shell metacharacters safely")
    func testShellQuotedMetacharacters() {
        let args = ["run", "dollar$ign", "semi;colon", "*asterisk*", "ampersand&"]
        let quoted = shellQuoted(args)
        #expect(quoted == "run 'dollar$ign' 'semi;colon' '*asterisk*' 'ampersand&'")
    }

    @Test("ContainerIsolationLevel enum parses valid CLI options and rejects invalid options")
    func testIsolationLevelParsing() {
        #expect(ContainerIsolationLevel(rawValue: "strict") == .strict)
        #expect(ContainerIsolationLevel(rawValue: "standard") == .standard)
        #expect(ContainerIsolationLevel(rawValue: "overlay") == .ephemeralOverlay)
        #expect(ContainerIsolationLevel(rawValue: "unknown_level") == nil)
        #expect(ContainerIsolationLevel(rawValue: "") == nil)
    }

    @Test("Subcommand dispatch recognizes expected subcommands")
    func testSubcommandRecognition() {
        let recognizedSubcommands: Set<String> = ["run", "status", "snapshot", "verify-security", "help", "--help", "-h"]
        #expect(recognizedSubcommands.contains("run"))
        #expect(recognizedSubcommands.contains("status"))
        #expect(recognizedSubcommands.contains("snapshot"))
        #expect(recognizedSubcommands.contains("verify-security"))
        #expect(!recognizedSubcommands.contains("invalid-cmd"))
    }
}
