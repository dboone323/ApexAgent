// sandboxctl — entitled management CLI for the Apple Container sandbox (H7).
//
// The xctest agent can never carry com.apple.security.virtualization, so the
// container boot path is unprovable from unit tests. This CLI links the real
// ApexAgentCore ContainerManager, and after being ad-hoc signed with
// ApexAgent.entitlements it boots the sandbox for real:
//
//   swift build --product sandboxctl
//   codesign --force --sign - --entitlements ApexAgent/ApexAgent.entitlements .build/debug/sandboxctl
//   .build/debug/sandboxctl                 # legacy probe (no args): boot + guest exec + stop
//   .build/debug/sandboxctl run -- uname -a
//   .build/debug/sandboxctl status
//   .build/debug/sandboxctl snapshot list
//   .build/debug/sandboxctl verify-security ~/Developer
//
// Subcommands cover PROJECT.md Feature 12 (run, status, snapshot,
// verify-security) plus the --isolation global. No-argument invocation keeps
// the legacy verification probe behavior for backward compatibility.
//
// Exit 0 on success; nonzero with a diagnostic on stderr otherwise.

import Foundation
import ApexAgentCore

@main
struct SandboxCtl {
    @MainActor
    static func main() async {
        // Global flags (accepted before the subcommand).
        var isolationLevel: ContainerIsolationLevel?
        var containerId = "default"
        var positional: [String] = []
        var args = Array(CommandLine.arguments.dropFirst())
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "--isolation", i + 1 < args.count {
                guard let level = ContainerIsolationLevel(rawValue: args[i + 1]) else {
                    fputsStderr("[sandboxctl] ERROR: unknown isolation level '\(args[i + 1])' (expected strict|standard|overlay)\n")
                    exit(64)
                }
                isolationLevel = level
                i += 2
            } else if arg == "--container", i + 1 < args.count {
                containerId = args[i + 1]
                i += 2
            } else {
                positional.append(arg)
                i += 1
            }
        }
        args = positional

        let manager = ContainerManager.shared
        if let isolationLevel {
            manager.isolationLevel = isolationLevel
        }

        // No subcommand: legacy verification probe (boot + guest exec + stop).
        guard let command = args.first else {
            await runVerificationProbe(manager: manager)
        }

        do {
            switch command {
            case "run":
                try await runGuestCommand(manager: manager, args: Array(args.dropFirst()))
            case "status":
                printStatus(manager: manager)
            case "snapshot":
                try await runSnapshot(manager: manager, args: Array(args.dropFirst()), containerId: containerId)
            case "verify-security":
                runVerifySecurity(manager: manager, args: Array(args.dropFirst()))
            case "help", "--help", "-h":
                printUsage()
            default:
                fputsStderr("[sandboxctl] ERROR: unknown subcommand '\(command)'\n")
                printUsage()
                exit(64)
            }
        } catch {
            fputsStderr("[sandboxctl] FAIL: \(error.localizedDescription)\n")
            let ns = error as NSError
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                fputsStderr("[sandboxctl] underlying: \(underlying)\n")
            }
            exit(1)
        }
    }

    // MARK: - Subcommands

    /// POSIX-quote an argv array for safe transport through `/bin/sh -c`
    /// (AUDIT_2026-09-28 §3.4.26): bare-passes safe tokens, single-quotes the
    /// rest with embedded-quote escaping so spaces/quotes/`$` survive intact.
    static func shellQuoted(_ args: [String]) -> String {
        args.map { arg in
            if arg.range(of: "^[a-zA-Z0-9_./-]+$", options: .regularExpression) != nil {
                return arg
            } else {
                return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
            }
        }.joined(separator: " ")
    }

    /// run -- <command...>: boot the sandbox, exec one guest command, stop.
    @MainActor
    private static func runGuestCommand(manager: ContainerManager, args: [String]) async throws {
        var cmdArgs = args
        if cmdArgs.first == "--" { cmdArgs.removeFirst() }
        guard !cmdArgs.isEmpty else {
            fputsStderr("[sandboxctl] ERROR: 'run' requires a command (sandboxctl run -- <command...>)\n")
            exit(64)
        }
        // argv passthrough via POSIX quoting (AUDIT_2026-09-28 §3.4.26): args with
        // spaces/quotes/$ survive the `/bin/sh -c` transport inside the guest.
        let command = shellQuoted(cmdArgs)
        print("[sandboxctl] starting container (image: \(manager.appleContainerImage), isolation: \(manager.isolationLevel.rawValue))…")
        try await manager.startContainer()
        do {
            let (output, code) = try await manager.exec(command)
            print(output, terminator: "")
            print("[sandboxctl] exec exit=\(code)")
            try await manager.stopContainer()
            print("[sandboxctl] stopped. state: \(manager.stateDescription)")
            exit(code == 0 ? 0 : 3)
        } catch {
            try? await manager.stopContainer()
            throw error
        }
    }

    /// status: sandbox state, isolation level, and resource configuration.
    @MainActor
    private static func printStatus(manager: ContainerManager) {
        print("state: \(manager.stateDescription)")
        print("isolation: \(manager.isolationLevel.rawValue)")
        print("image: \(manager.appleContainerImage)")
        print("cpus: \(manager.containerCPUs)")
        print("memory_mb: \(manager.containerMemoryMB)")
    }

    /// snapshot list | create <name> [--description <text>] | delete <id|name> | restore <id|name>
    @MainActor
    private static func runSnapshot(manager: ContainerManager, args: [String], containerId: String) async throws {
        guard let sub = args.first else {
            fputsStderr("[sandboxctl] ERROR: 'snapshot' requires a subcommand (list|create|delete|restore)\n")
            exit(64)
        }
        switch sub {
        case "list":
            let snapshots = await manager.listSnapshots(containerId: containerId)
            if snapshots.isEmpty {
                print("[sandboxctl] no snapshots for container '\(containerId)'")
            }
            for snap in snapshots {
                let isolation = snap.isolationLevel.map(\.rawValue) ?? "-"
                print("\(snap.id)\t\(snap.name)\t\(snap.createdAt)\t\(isolation)\t\(snap.description)")
            }
        case "create":
            guard args.count >= 2 else {
                fputsStderr("[sandboxctl] ERROR: 'snapshot create' requires a name\n")
                exit(64)
            }
            var description = ""
            var rest = Array(args.dropFirst(2))
            while let flagIndex = rest.firstIndex(of: "--description"), flagIndex + 1 < rest.count {
                description = rest[flagIndex + 1]
                rest.remove(at: flagIndex + 1)
                rest.remove(at: flagIndex)
            }
            let record = try await manager.createSnapshot(name: args[1], description: description, containerId: containerId)
            print("[sandboxctl] created snapshot \(record.id) ('\(record.name)')")
        case "delete":
            guard args.count >= 2 else {
                fputsStderr("[sandboxctl] ERROR: 'snapshot delete' requires a snapshot id or name\n")
                exit(64)
            }
            try await manager.deleteSnapshot(id: args[1], containerId: containerId)
            print("[sandboxctl] deleted snapshot '\(args[1])'")
        case "restore":
            guard args.count >= 2 else {
                fputsStderr("[sandboxctl] ERROR: 'snapshot restore' requires a snapshot id or name\n")
                exit(64)
            }
            try await manager.rollbackToSnapshot(nameOrId: args[1], containerId: containerId)
            print("[sandboxctl] restored snapshot '\(args[1])'")
        default:
            fputsStderr("[sandboxctl] ERROR: unknown snapshot subcommand '\(sub)'\n")
            exit(64)
        }
    }

    /// verify-security <path> [command...]: run the REAL workspace-mount,
    /// filesystem, and command guards and report pass/fail per check.
    /// This is a genuine validation run, not a canned success message.
    @MainActor
    private static func runVerifySecurity(manager: ContainerManager, args: [String]) {
        guard let path = args.first else {
            fputsStderr("[sandboxctl] ERROR: 'verify-security' requires a path\n")
            exit(64)
        }
        var failures: [String] = []

        do {
            try manager.verifyWorkspaceMountSafety(path)
            print("[sandboxctl] verify-security: workspace mount guard PASS for '\(path)'")
        } catch {
            failures.append("workspace mount guard: \(error)")
        }

        // Validate against the strictest host profile: anything passing here
        // passes everywhere.
        let profile = SecurityGovernanceProfile.hostStrict
        do {
            try profile.validateFilesystemAccess(path: path)
            print("[sandboxctl] verify-security: filesystem access guard (host-strict) PASS for '\(path)'")
        } catch {
            failures.append("filesystem access guard: \(error)")
        }

        if args.count >= 2 {
            // Validate the properly-quoted command string (AUDIT_2026-09-28
            // §3.4.26): arguments with spaces keep their intended grouping.
            let command = shellQuoted(Array(args[1...]))
            if profile.validateCommand(command: command, isContainerSandboxed: false) {
                print("[sandboxctl] verify-security: command guard (host-strict) PASS")
            } else {
                failures.append("command guard: host-strict profile rejects '\(command)'")
            }
        }

        if failures.isEmpty {
            print("[sandboxctl] verify-security: ALL CHECKS PASSED")
        } else {
            for failure in failures {
                fputsStderr("[sandboxctl] verify-security FAIL: \(failure)\n")
            }
            exit(3)
        }
    }

    /// Legacy no-argument verification probe: boot + guest exec + stop.
    @MainActor
    private static func runVerificationProbe(manager: ContainerManager) async -> Never {
        do {
            print("[sandboxctl] starting container (image: \(manager.appleContainerImage))…")
            try await manager.startContainer()
            print("[sandboxctl] state: \(manager.stateDescription)")

            // Probe 1: guest root as cwd ("/" always exists in the guest).
            let (output, code) = try await manager.exec("echo APEX_SANDBOX_OK")
            print("[sandboxctl] exec exit=\(code) output=\(output)")

            try await manager.stopContainer()
            print("[sandboxctl] stopped. state: \(manager.stateDescription)")

            if output.contains("APEX_SANDBOX_OK") && code == 0 {
                print("APEX_SANDBOX_OK")
                exit(0)
            } else {
                print("[sandboxctl] FAIL: unexpected exec result")
                exit(2)
            }
        } catch {
            print("[sandboxctl] FAIL: \(error.localizedDescription)")
            let ns = error as NSError
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                print("[sandboxctl] underlying: \(underlying)")
            }
            exit(1)
        }
    }

    private static func printUsage() {
        print("""
            sandboxctl — Apple Container sandbox management CLI

            Usage: sandboxctl [--isolation strict|standard|overlay] [--container <id>] <subcommand>

              (no args)                 legacy verification probe: boot + guest exec + stop
              run -- <command...>       boot, exec one guest command, stop
              status                    sandbox state + isolation level + resources
              snapshot list             list snapshots for the container
              snapshot create <name> [--description <text>]
                                        create a snapshot
              snapshot delete <id|name> delete a snapshot
              snapshot restore <id|name>
                                        roll back to a snapshot
              verify-security <path> [command...]
                                        run the real mount/filesystem/command guards
              help                      this text
            """)
    }

    private static func fputsStderr(_ string: String) {
        fputs(string, stderr)
    }
}
