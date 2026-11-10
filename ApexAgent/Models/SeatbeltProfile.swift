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

    private static func canonicalPath(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        if let canonical = (try? url.resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath {
            return canonical
        }
        var buffer = [CChar](repeating: 0, count: 1024)
        if let resolved = realpath(path, &buffer) {
            return String(cString: resolved)
        }
        var current = (path as NSString)
        var suffix: [String] = []
        while !current.isEqual(to: "/") && !current.isEqual(to: "") {
            if let resolved = realpath(current as String, &buffer) {
                var res = String(cString: resolved)
                for part in suffix.reversed() {
                    res = (res as NSString).appendingPathComponent(part)
                }
                return res
            }
            suffix.append(current.lastPathComponent)
            current = (current.deletingLastPathComponent as NSString)
        }
        return url.standardized.resolvingSymlinksInPath().path
    }

    public func generate() -> String {
        let wsCanonical = Self.canonicalPath(for: workspacePath)
        let tmpCanonical = Self.canonicalPath(for: tempDirectory)
        let ddCanonical = Self.canonicalPath(for: derivedDataDirectory)
        let userTemp = (NSTemporaryDirectory() as NSString).standardizingPath
        let userTempCanonical = Self.canonicalPath(for: userTemp)

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
            "    (subpath \"\(userTempCanonical)\")",
            "    (subpath \"\(wsCanonical)\")",
            "    (subpath \"\(tmpCanonical)\")",
            "    (subpath \"\(ddCanonical)\")"
        ]
        if userTempCanonical != userTemp {
            lines.append("    (subpath \"\(userTemp)\")")
        }
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
