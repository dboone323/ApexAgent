import Foundation

// MARK: - Docs rendering (workflow 4)

public enum DocsRenderer {
    public static func renderToolReference(schemas: [[String: Any]], toolNames: [String]) -> String {
        var descriptions: [String: String] = [:]
        for schema in schemas {
            if let n = schema["name"] as? String,
               let d = schema["description"] as? String {
                descriptions[n] = d
            }
        }
        var out = "# ApexAgent — Generated Docs\n\n"
        out += "_Generated from the live tool registry. Do not edit by hand._\n\n"
        out += "## Tool Reference\n\n"
        out += "| Tool | Description |\n|---|---|\n"
        for tool in toolNames {
            let desc = descriptions[tool]?
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "|", with: "\\|")
                ?? "(no schema description registered)"
            out += "| `\(tool)` | \(desc) |\n"
        }
        out += "\nTotal tools: \(toolNames.count)\n"
        return out
    }
}

// MARK: - CI triage (workflow 5)

public enum BuildTriage {
    public enum Verdict: String, Sendable { case green, flake, regression }

    public struct Report: Sendable {
        public let verdict: Verdict
        public let action: String
        public let signal: String
    }

    public static func classify(_ log: String) -> Report {
        let lower = log.lowercased()

        let flakeSignals = ["timed out", "timeout", "connection reset",
                            "resource temporarily unavailable", "flaky"]
        let regressionSignals = ["error:", "cannot find", "undefined symbol",
                                 "does not conform", "linker command failed",
                                 "assertion failed", "xctassert"]

        if let hit = regressionSignals.first(where: { lower.contains($0) }) {
            // A timeout inside an otherwise compiling run is a flake; a
            // compile/link/assert failure is a genuine regression.
            return Report(verdict: .regression,
                          action: "open a fix branch and escalate to a human reviewer",
                          signal: hit)
        }
        if let hit = flakeSignals.first(where: { lower.contains($0) }) {
            return Report(verdict: .flake,
                          action: "retry the job once, then report if it repeats",
                          signal: hit)
        }
        return Report(verdict: .green, action: "no action", signal: "clean")
    }
}

// MARK: - Schema drift monitor (workflow 7)

public struct SchemaSnapshot: Sendable {
    /// tool name → sorted "param:type" descriptors
    public let entries: [String: [String]]

    public init(entries: [String: [String]]) { self.entries = entries }

    public var json: String {
        let data = (try? JSONSerialization.data(
            withJSONObject: entries, options: [.sortedKeys, .prettyPrinted])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    public static func capture(_ schemas: [[String: Any]]) -> SchemaSnapshot {
        var entries: [String: [String]] = [:]
        for schema in schemas {
            guard let name = schema["name"] as? String else { continue }
            var descriptors: [String] = []
            if let params = schema["parameters"] as? [String: Any],
               let props = params["properties"] as? [String: Any] {
                for (key, value) in props {
                    let type = (value as? [String: Any])?["type"] as? String ?? "unknown"
                    descriptors.append("\(key):\(type)")
                }
            }
            entries[name] = descriptors.sorted()
        }
        return SchemaSnapshot(entries: entries)
    }

    public static func diff(baseline: SchemaSnapshot, current: SchemaSnapshot) -> [String] {
        var report: [String] = []
        for tool in baseline.entries.keys.sorted() where current.entries[tool] == nil {
            report.append("tool removed: \(tool)")
        }
        for tool in current.entries.keys.sorted() where baseline.entries[tool] == nil {
            report.append("tool added: \(tool)")
        }
        for tool in baseline.entries.keys.sorted() {
            guard let before = baseline.entries[tool],
                  let after = current.entries[tool], before != after else { continue }
            let beforeMap = Dictionary(uniqueKeysWithValues: before.compactMap { pair -> (String, String)? in
                let parts = pair.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                return (String(parts[0]), String(parts[1]))
            })
            let afterMap = Dictionary(uniqueKeysWithValues: after.compactMap { pair -> (String, String)? in
                let parts = pair.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                return (String(parts[0]), String(parts[1]))
            })
            for (param, type) in beforeMap.sorted(by: { $0.key < $1.key }) {
                if let now = afterMap[param] {
                    if now != type {
                        report.append("type changed: \(tool).\(param) \(type) → \(now)")
                    }
                } else {
                    report.append("param removed: \(tool).\(param)")
                }
            }
            for (param, type) in afterMap.sorted(by: { $0.key < $1.key }) where beforeMap[param] == nil {
                report.append("param added: \(tool).\(param):\(type)")
            }
        }
        return report
    }
}

// MARK: - Ticket triage (workflow 8)

public enum TicketTriage {
    public struct Route: Sendable {
        public let agent: String
        public let priority: String
        public let rationale: String
    }

    public static func route(_ ticket: String) -> Route {
        let t = ticket.lowercased()
        if t.contains("crash") || t.contains("nil unwrap") || t.contains("exception") {
            return Route(agent: "developer", priority: "high",
                         rationale: "User-visible crash — needs a code fix.")
        }
        if t.contains("build") || t.contains("ci") || t.contains("deploy")
            || t.contains("failing") {
            return Route(agent: "executor", priority: "high",
                         rationale: "Pipeline execution failure — run and diagnose the build.")
        }
        if t.contains("research") || t.contains("investigate") || t.contains("whether")
            || t.contains("compare") {
            return Route(agent: "researcher", priority: "low",
                         rationale: "Open question — needs investigation, not code.")
        }
        if t.contains("document") || t.contains("readme") || t.contains("docs")
            || t.contains("plan") {
            return Route(agent: "planner", priority: "medium",
                         rationale: "Documentation/planning work item.")
        }
        return Route(agent: "developer", priority: "medium",
                     rationale: "Unclassified — default to the developer agent.")
    }
}

// MARK: - Modernization sweep (workflow 9)

public enum ModernizationSweep {
    public struct Proposal: Sendable {
        public let find: String
        public let replace: String
        public let reason: String
    }

    public static func proposals(for source: String) -> [Proposal] {
        var out: [Proposal] = []
        if source.contains("DispatchQueue.main.async {") {
            out.append(.init(
                find: "DispatchQueue.main.async {",
                replace: "await MainActor.run {",
                reason: "GCD main-queue hop → structured concurrency."))
        }
        if source.contains("completion: @escaping") {
            out.append(.init(
                find: "completion: @escaping",
                replace: "completion: @Sendable @escaping",
                reason: "Escaping closure crossing isolation must be @Sendable under Swift 6."))
        }
        if source.contains("NSString(string:") {
            out.append(.init(
                find: "NSString(string:",
                replace: "String(",
                reason: "Drop NSString bridging in favor of native String APIs."))
        }
        if source.range(of: #"^\s*class [A-Z]"#, options: [.regularExpression]) != nil
            || source.contains("\nclass ") {
            out.append(.init(
                find: "class Legacy {",
                replace: "@MainActor\nfinal class Legacy {",
                reason: "Non-final, non-isolated class → final + @MainActor."))
        }
        return out
    }

    public static func apply(_ proposals: [Proposal], to source: String) -> String {
        var out = source
        for p in proposals {
            out = out.replacingOccurrences(of: p.find, with: p.replace)
        }
        return out
    }
}

// MARK: - Standup composer (workflow 10)

public enum StandupComposer {
    public static func compose(briefing: String, gitLog: String) -> String {
        let commits = gitLog
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("$") && !$0.contains("ERROR:") }
            .prefix(5)

        var out = "# Daily Digest\n\n## Briefing\n\n\(briefing)\n\n## Standup\n\n"
        if commits.isEmpty {
            out += "- No commits found in the current repository.\n"
        } else {
            out += "Yesterday:\n"
            for commit in commits { out += "- \(commit)\n" }
        }
        out += "\nBlockers: none reported.\n"
        return out
    }
}
