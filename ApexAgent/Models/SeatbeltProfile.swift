import Foundation

public struct SeatbeltProfile: Sendable, Equatable {
    public let workspacePath: String
    public let allowNetwork: Bool

    public init(workspacePath: String, allowNetwork: Bool = true) {
        self.workspacePath = workspacePath
        self.allowNetwork = allowNetwork
    }

    public var tempDirectory: String {
        (workspacePath as NSString).appendingPathComponent(".apex/tmp")
    }

    public var derivedDataDirectory: String {
        (workspacePath as NSString).appendingPathComponent(".apex/DerivedData")
    }

    public func generate() -> String {
        let wsCanonical = URL(fileURLWithPath: workspacePath).standardized.resolvingSymlinksInPath().path
        let tmpCanonical = URL(fileURLWithPath: tempDirectory).standardized.resolvingSymlinksInPath().path
        let ddCanonical = URL(fileURLWithPath: derivedDataDirectory).standardized.resolvingSymlinksInPath().path

        var lines: [String] = [
            "(version 1)",
            "(allow default)",
            "(deny file-write*)",
            "(allow file-write*",
            "    (literal \"/dev/null\")",
            "    (literal \"/dev/zero\")",
            "    (literal \"/dev/dtracehelper\")",
            "    (literal \"/dev/tty\")",
            "    (subpath \"/dev/fd\")",
            "    (subpath \"/private/var/folders\")",
            "    (subpath \"\(wsCanonical)\")",
            "    (subpath \"\(tmpCanonical)\")",
            "    (subpath \"\(ddCanonical)\")"
        ]
        if wsCanonical != workspacePath {
            lines.append("    (subpath \"\(workspacePath)\")")
            lines.append("    (subpath \"\(tempDirectory)\")")
            lines.append("    (subpath \"\(derivedDataDirectory)\")")
        }
        lines.append(")")
        if !allowNetwork {
            lines.append("(deny network*)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
