import Foundation

/// Git diff validator enforcing test suite integrity rules.
///
/// Ensures that changes to test targets are strictly additions-only (status `A`).
/// Any modifications, renames, or deletions in test suites are flagged as violations.
public enum GitIntegrityValidator {

    public static func integrityViolations(diffOutput: String) -> [String] {
        var violations: [String] = []
        for line in diffOutput.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count >= 2 else { continue }
            let status = String(parts[0])
            let path = String(parts[1])
            let isTest: Bool = {
                if path.hasPrefix("ApexAgentTests/") { return true }
                if path.contains("/Tests/") { return true }
                for comp in path.split(separator: "/") {
                    if String(comp).hasSuffix("Tests") { return true }
                }
                return false
            }()
            if !isTest { continue }
            if status != "A" { violations.append("\(status) \(path)") }
        }
        return violations
    }
}
