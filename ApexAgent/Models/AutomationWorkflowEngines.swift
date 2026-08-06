import Foundation
import SwiftData
import SharedModels

// MARK: - Code review rules (workflow 1)

public struct ReviewFinding: Codable, Sendable {
    public let line: Int
    public let message: String
    public let severity: String
}

public enum CodeReviewRules {
    /// Deterministic static review pass. Encodes the checks the article wants
    /// a review bot to catch before a human is assigned.
    public static func scan(_ source: String) -> [ReviewFinding] {
        var findings: [ReviewFinding] = []
        for (index, raw) in source.components(separatedBy: "\n").enumerated() {
            let line = index + 1
            let text = raw.trimmingCharacters(in: .whitespaces)
            if text.contains("sk_live_") || text.range(of: #"(?i)(apikey|secret|token)\s*=\s*""#,
                                                       options: .regularExpression) != nil {
                findings.append(.init(line: line,
                                      message: "Possible hardcoded secret — move to KeychainManager.",
                                      severity: "error"))
            }
            if text.contains("try!") {
                findings.append(.init(line: line,
                                      message: "try! will trap at runtime; propagate the error instead.",
                                      severity: "error"))
            }
            if text.contains("as!") {
                findings.append(.init(line: line,
                                      message: "Force cast as! can crash; use a conditional cast.",
                                      severity: "warning"))
            }
            if text.contains("print(") {
                findings.append(.init(line: line,
                                      message: "print() in shipping code; use the logging module.",
                                      severity: "info"))
            }
            if text.contains("TODO") || text.contains("FIXME") {
                findings.append(.init(line: line,
                                      message: "Unresolved TODO/FIXME left in the diff.",
                                      severity: "info"))
            }
        }
        return findings
    }
}

// MARK: - Natural-language project query planner (workflow 2)

public struct ProjectQueryPlan: Sendable {
    public enum Priority: String, Sendable { case high, medium, low, any }
    public let priority: Priority
    public let openOnly: Bool
    public let projectNameHint: String?

    @MainActor
    public func execute(orchestrator: AgentOrchestrator) async throws -> String {
        guard let context = orchestrator.modelContext else { return "ERROR: no store" }
        var projectID: String?
        if let hint = projectNameHint {
            let projects = (try? context.fetch(FetchDescriptor<ProjectModel>())) ?? []
            projectID = projects.first {
                $0.name.lowercased().contains(hint.lowercased())
            }?.id.uuidString
        }
        let listed = try await ListTasksTool(orchestrator: orchestrator)
            .call(arguments: .init(projectID: projectID, sprintID: nil))

        // Filter the real tool output down to the rows the question asked for.
        let blocks = listed.components(separatedBy: "\n\n")
        let matching = blocks.filter { block in
            guard block.contains("•") else { return false }
            let lower = block.lowercased()
            if priority != .any, !lower.contains(priority.rawValue) { return false }
            if openOnly, lower.contains("status: done") || lower.contains("status: completed") {
                return false
            }
            return true
        }
        if matching.isEmpty { return "No tasks matched the question." }
        return "Matched \(matching.count) task(s):\n\n" + matching.joined(separator: "\n\n")
    }
}

public enum ProjectQueryPlanner {
    public static func plan(_ question: String) -> ProjectQueryPlan {
        let q = question.lowercased()
        let priority: ProjectQueryPlan.Priority =
            q.contains("high") ? .high :
            q.contains("medium") ? .medium :
            q.contains("low") ? .low : .any
        let openOnly = q.contains("open") || q.contains("outstanding")
            || q.contains("remaining") || q.contains("not done")

        // "on <Project Name>" / "for <Project Name>" / "in <Project Name>"
        var hint: String?
        for marker in [" on ", " for ", " in "] {
            if let range = q.range(of: marker) {
                let tail = q[range.upperBound...]
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ?.!"))
                if !tail.isEmpty { hint = tail }
            }
        }
        return ProjectQueryPlan(priority: priority, openOnly: openOnly, projectNameHint: hint)
    }
}

// MARK: - Test scaffolding + selector healing (workflow 3)

public enum TestScaffolder {
    /// Generates a Swift Testing suite skeleton from the public functions of a
    /// source file — the repo's actual test style (`@Suite` + `@Test`).
    public static func generateSuite(forSourceNamed typeName: String, source: String) -> String {
        var cases: [String] = []
        for raw in source.components(separatedBy: "\n") {
            guard let range = raw.range(of: #"func\s+([A-Za-z_][A-Za-z0-9_]*)"#,
                                        options: .regularExpression) else { continue }
            let fn = raw[range].replacingOccurrences(of: "func", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard !fn.isEmpty else { continue }
            let capitalized = fn.prefix(1).uppercased() + fn.dropFirst()
            cases.append("""
                    @Test func test\(capitalized)() async throws {
                        // Generated from \(typeName).\(fn). Fill in the real assertion.
                        #expect(Bool(true))
                    }
                """)
        }
        return """
            import Testing
            import Foundation
            @testable import ApexAgentCore

            @Suite("\(typeName)Tests") struct \(typeName)Tests {
            \(cases.joined(separator: "\n\n"))
            }
            """
    }
}

public enum SelectorHealer {
    /// Repairs a stale accessibility identifier in an XCUITest line by finding
    /// the closest live identifier. Returns nil when the identifier is already
    /// valid (no gratuitous rewrites).
    public static func heal(_ line: String, against liveIdentifiers: [String]) -> String? {
        guard let range = line.range(of: #""([^"]+)""#, options: .regularExpression) else {
            return nil
        }
        let quoted = String(line[range])
        let stale = quoted.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        if liveIdentifiers.contains(stale) { return nil }

        let scored = liveIdentifiers
            .map { ($0, similarity($0, stale)) }
            .sorted { $0.1 > $1.1 }
        guard let best = scored.first, best.1 >= 0.5 else { return nil }
        return line.replacingOccurrences(of: quoted, with: "\"\(best.0)\"")
    }

    /// Token-overlap similarity on camel-cased identifier words.
    static func similarity(_ a: String, _ b: String) -> Double {
        let ta = tokens(a), tb = tokens(b)
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        let shared = Double(ta.intersection(tb).count)
        return shared / Double(max(ta.count, tb.count))
    }

    static func tokens(_ s: String) -> Set<String> {
        var words: [String] = []
        var current = ""
        for ch in s {
            if ch.isUppercase, !current.isEmpty {
                words.append(current.lowercased())
                current = String(ch)
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { words.append(current.lowercased()) }
        return Set(words)
    }
}
