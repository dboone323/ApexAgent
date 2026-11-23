import Foundation
import Darwin

// MARK: - Goal Mode CLI (Issue #79)

/// CLI handler for `ApexAgent goal` commands and live verification.
public enum GoalCLI {
    private static func printOut(_ message: String) {
        fputs("\(message)\n", Darwin.stdout)
    }

    private static func printErr(_ message: String) {
        fputs("\(message)\n", Darwin.stderr)
    }

    public static func run(arguments: [String]) async -> Int32 {
        guard let action = arguments.first else {
            printUsage()
            return 0
        }

        let subArgs = Array(arguments.dropFirst())

        switch action {
        case "create":
            return await handleCreate(arguments: subArgs)
        case "status":
            return await handleStatus(arguments: subArgs)
        case "ledger":
            return await handleLedger(arguments: subArgs)
        case "replan":
            return await handleReplan(arguments: subArgs)
        case "step":
            return await handleStep(arguments: subArgs)
        case "setback":
            return await handleSetback(arguments: subArgs)
        case "complete":
            return await handleComplete(arguments: subArgs)
        case "verify", "--verify":
            return await handleVerify(arguments: subArgs)
        case "--help", "-h", "help":
            printUsage()
            return 0
        default:
            printErr("Unknown goal action '\(action)'. Run 'ApexAgent goal --help' for usage.")
            return 64
        }
    }

    private static func printUsage() {
        printOut("""
        Usage: ApexAgent goal <action> [options]

        Actions:
          create <title> <objective> [criterion1 criterion2 ...]
                      Create a new persistent goal
          status      Show active goal status and checkable progress report
          ledger      Print the visible append-only progress ledger
          replan      Re-plan next steps against the goal and recorded setbacks
          step <text> Record a step completion in the progress ledger
          setback <text>
                      Record a setback in the progress ledger
          complete    Mark the active goal completed if all criteria are met
          verify      Run live verification suite (GoalModeLiveVerifier)
        """)
    }

    private static func handleCreate(arguments: [String]) async -> Int32 {
        guard arguments.count >= 2 else {
            printErr("Error: 'goal create' requires <title> and <objective>.")
            return 1
        }
        let title = arguments[0]
        let objective = arguments[1]
        let criteria = Array(arguments.dropFirst(2))

        let service = GoalModeService()
        do {
            let goal = try await service.createGoal(
                title: title,
                objective: objective,
                criteria: criteria.isEmpty ? ["Complete primary objective"] : criteria
            )
            printOut("Created goal '\(goal.title)' [\(goal.id.uuidString)]")
            printOut("Objective: \(goal.objective)")
            printOut("Criteria count: \(goal.successCriteria.count)")
            return 0
        } catch {
            printErr("Error creating goal: \(error.localizedDescription)")
            return 1
        }
    }

    private static func handleStatus(arguments: [String]) async -> Int32 {
        let jsonOutput = arguments.contains("--json")
        let service = GoalModeService()
        do {
            guard let goal = try await service.loadActiveGoal() else {
                printErr("No active goal found.")
                return 1
            }
            let report = await service.reportProgress()

            if jsonOutput {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(report)
                if let str = String(data: data, encoding: .utf8) {
                    printOut(str)
                }
            } else {
                printOut("=== Goal: \(goal.title) ===")
                printOut("Status: \(goal.status.rawValue.uppercased())")
                printOut("Overall Progress: \(report.overallStatus.rawValue)")
                printOut("Criteria: \(report.completedCriteria)/\(report.totalCriteria) completed, \(report.blockedCriteria) blocked")
                printOut("Summary: \(report.summary)")
                for c in goal.successCriteria {
                    printOut("  - \(c.status.badge) [\(c.id)] \(c.description)")
                }
            }
            return 0
        } catch {
            printErr("Error loading goal status: \(error.localizedDescription)")
            return 1
        }
    }

    private static func handleLedger(arguments: [String]) async -> Int32 {
        let jsonOutput = arguments.contains("--json")
        let service = GoalModeService()
        do {
            guard try await service.loadActiveGoal() != nil else {
                printErr("No active goal found.")
                return 1
            }
            let entries = await service.getLedger()

            if jsonOutput {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(entries)
                if let str = String(data: data, encoding: .utf8) {
                    printOut(str)
                }
            } else {
                printOut("=== Goal Progress Ledger (\(entries.count) entries) ===")
                for entry in entries {
                    printOut(entry.formatMarkdownLine())
                }
            }
            return 0
        } catch {
            printErr("Error loading ledger: \(error.localizedDescription)")
            return 1
        }
    }

    private static func handleReplan(arguments: [String]) async -> Int32 {
        let service = GoalModeService()
        do {
            guard try await service.loadActiveGoal() != nil else {
                printErr("No active goal found.")
                return 1
            }
            let plan = try await service.replan()
            printOut("=== Re-Plan Result ===")
            printOut("Summary: \(plan.summary)")
            printOut("Planned Steps: \(plan.steps.count)")
            for s in plan.steps {
                printOut("  - [\(s.id)] \(s.title) (rationale: \(s.rationale))")
                if !s.avoidSetbacks.isEmpty {
                    printOut("    * Avoiding setbacks: \(s.avoidSetbacks.joined(separator: ", "))")
                }
            }
            if !plan.activeBlockers.isEmpty {
                printOut("Active Blockers:")
                for b in plan.activeBlockers {
                    printOut("  - \(b)")
                }
            }
            return 0
        } catch {
            printErr("Error executing replan: \(error.localizedDescription)")
            return 1
        }
    }

    private static func handleStep(arguments: [String]) async -> Int32 {
        guard !arguments.isEmpty else {
            printErr("Error: 'goal step' requires text.")
            return 1
        }
        let text = arguments.joined(separator: " ")
        let service = GoalModeService()
        do {
            guard try await service.loadActiveGoal() != nil else {
                printErr("No active goal found.")
                return 1
            }
            let entry = try await service.appendLedgerEntry(kind: .step, text: text)
            printOut("Recorded step #\(entry.sequenceNumber): \(entry.text)")
            return 0
        } catch {
            printErr("Error recording step: \(error.localizedDescription)")
            return 1
        }
    }

    private static func handleSetback(arguments: [String]) async -> Int32 {
        guard !arguments.isEmpty else {
            printErr("Error: 'goal setback' requires text.")
            return 1
        }
        let text = arguments.joined(separator: " ")
        let service = GoalModeService()
        do {
            guard try await service.loadActiveGoal() != nil else {
                printErr("No active goal found.")
                return 1
            }
            let entry = try await service.appendLedgerEntry(kind: .setback, text: text)
            printOut("Recorded setback #\(entry.sequenceNumber): \(entry.text)")
            return 0
        } catch {
            printErr("Error recording setback: \(error.localizedDescription)")
            return 1
        }
    }

    private static func handleComplete(arguments: [String]) async -> Int32 {
        let service = GoalModeService()
        do {
            guard try await service.loadActiveGoal() != nil else {
                printErr("No active goal found.")
                return 1
            }
            let completed = try await service.completeGoalIfEligible()
            if completed {
                printOut("✅ Goal successfully marked complete.")
                return 0
            } else {
                let report = await service.reportProgress()
                printErr("❌ Goal cannot be marked complete: criteria not met (\(report.summary)).")
                return 1
            }
        } catch {
            printErr("Error completing goal: \(error.localizedDescription)")
            return 1
        }
    }

    private static func handleVerify(arguments: [String]) async -> Int32 {
        let logPath = arguments.first ?? "runs/issue79/live-verify.log"
        let result = await GoalModeLiveVerifier.runVerification(writeLogTo: logPath)
        printOut(result.output)
        return result.passed ? 0 : 1
    }
}
