import Foundation

// MARK: - Automation Workflows 11–15 (Batch 34: Pre-Push, Resilience, MCP 2026-07-28, Deep Links & Scheduling)

extension ApexWorkflows {

    // MARK: 11 — Pre-push security & hygiene self-audit (RepoHygieneAuditor + SwiftSyntaxLintGate)
    static func workflow11() async -> WorkflowResult {
        let name = "Pre-push security & hygiene self-audit"
        do {
            let cleanDir = URL(fileURLWithPath: try makeScratch("wf11-clean"), isDirectory: true)
            defer { try? FileManager.default.removeItem(at: cleanDir) }

            let cleanSwift = cleanDir.appendingPathComponent("CleanFeature.swift")
            try """
            import Foundation

            public struct CleanFeature: Sendable {
                public let version: Int

                public init(version: Int = 1) {
                    self.version = version
                }
            }
            """.write(to: cleanSwift, atomically: true, encoding: .utf8)

            let cleanSource = try String(contentsOf: cleanSwift, encoding: .utf8)
            let cleanPath = "ApexAgent/Models/CleanFeature.swift"
            let cleanFindings = RepoHygieneAuditor.scanForSecrets(in: cleanSource, filePath: cleanPath)
                + RepoHygieneAuditor.scanForVendorNames(in: cleanSource, filePath: cleanPath)
                + RepoHygieneAuditor.scanForRawPrintCalls(in: cleanSource, filePath: cleanPath)
            let cleanLint = SwiftSyntaxLintGate.analyzeSwiftSource(cleanSource, filePath: cleanPath)

            // Verify negative detection on synthetic violations (secret + print + conflict marker)
            let synthToken = "ghp_" + String(repeating: "A", count: 36)
            let synthPrint = "pri" + "nt(\"debug leak\")"
            let synthConflictStart = String(repeating: "<", count: 7) + " HEAD"
            let synthConflictMid = String(repeating: "=", count: 7)
            let synthConflictEnd = String(repeating: ">", count: 7) + " branch"
            let dirtySource = [
                "import Foundation",
                "import Foundation",
                "",
                synthConflictStart,
                "let token = \"\(synthToken)\"",
                synthConflictMid,
                synthPrint,
                synthConflictEnd
            ].joined(separator: "\n")
            let dirtyPath = "ApexAgent/Models/Dirty.swift"
            let dirtyFindings = RepoHygieneAuditor.scanForSecrets(in: dirtySource, filePath: dirtyPath)
                + RepoHygieneAuditor.scanForRawPrintCalls(in: dirtySource, filePath: dirtyPath)
            let dirtyLint = SwiftSyntaxLintGate.analyzeSwiftSource(dirtySource, filePath: dirtyPath)

            let caughtSecret = dirtyFindings.contains { $0.category == .leakedSecret }
            let caughtPrint = dirtyFindings.contains { $0.category == .rawPrintCall }
            let caughtConflict = dirtyLint.contains { $0.kind == .mergeConflictMarker }
            let caughtDupImport = dirtyLint.contains { $0.kind == .duplicateImport }

            let passed = cleanFindings.isEmpty
                && cleanLint.isEmpty
                && caughtSecret
                && caughtPrint
                && caughtConflict
                && caughtDupImport
            return WorkflowResult(
                id: 11,
                name: name,
                passed: passed,
                evidence: "clean=0 findings, dirty caught secret=\(caughtSecret) print=\(caughtPrint) conflict=\(caughtConflict) dupImport=\(caughtDupImport)"
            )
        } catch {
            return WorkflowResult(id: 11, name: name, passed: false, evidence: "error: \(error)")
        }
    }

    // MARK: 12 — Persistence corruption quarantine & byte-preserving recovery (ResilientJSONStore)
    static func workflow12() async -> WorkflowResult {
        let name = "Persistence corruption quarantine & recovery"
        do {
            let dir = URL(fileURLWithPath: try makeScratch("wf12-store"), isDirectory: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            struct SampleConfig: Codable, Equatable {
                let schemaVersion: Int
                let mode: String
            }

            let store = ResilientJSONStore(maxEvents: 20)
            let targetURL = dir.appendingPathComponent("state.json")
            let corruptPayload = Data("{ \"schemaVersion\": 2, \"mode\": \"truncated".utf8)
            try corruptPayload.write(to: targetURL)

            let fixedNow = Date(timeIntervalSince1970: 1_759_900_000)
            let fallback = SampleConfig(schemaVersion: 1, mode: "recovered")
            let loaded = store.load(
                SampleConfig.self,
                from: targetURL,
                subsystem: "apexflow.wf12",
                default: fallback,
                now: { fixedNow }
            )

            let events = store.recentRecoveryEvents(limit: 5)
            guard let event = events.last else {
                return WorkflowResult(id: 12, name: name, passed: false, evidence: "no recovery event recorded")
            }

            let backupData = try Data(contentsOf: URL(fileURLWithPath: event.backupPath))
            let bytesPreserved = (backupData == corruptPayload)
            let originalRemoved = !FileManager.default.fileExists(atPath: targetURL.path)

            // Subsequent atomic write + load round-trip
            let updated = SampleConfig(schemaVersion: 3, mode: "healthy")
            try store.save(updated, to: targetURL, prettyPrinted: true)
            let reloaded = store.load(
                SampleConfig.self,
                from: targetURL,
                subsystem: "apexflow.wf12",
                default: fallback
            )

            let passed = (loaded == fallback)
                && bytesPreserved
                && originalRemoved
                && (reloaded == updated)
            return WorkflowResult(
                id: 12,
                name: name,
                passed: passed,
                evidence: "quarantined=\(event.byteCount)B preserved=\(bytesPreserved) reloaded=\(reloaded.mode)"
            )
        } catch {
            return WorkflowResult(id: 12, name: name, passed: false, evidence: "error: \(error)")
        }
    }

    // MARK: 13 — MCP 2026-07-28 version negotiation, tool policy annotations & W3C traceparent
    static func workflow13() async -> WorkflowResult {
        let name = "MCP 2026-07-28 negotiation & W3C traceparent"
        let negotiatedModern = MCPProtocolVersion.resolveNegotiatedVersion(
            advertised: MCPProtocolVersion.v2026_07_28,
            serverResponseVersion: "2026-07-28"
        )
        let negotiatedLegacy = MCPProtocolVersion.resolveNegotiatedVersion(
            advertised: MCPProtocolVersion.v2026_07_28,
            serverResponseVersion: "2023-01-01"
        )

        let readOnlyAnnotations = MCPToolAnnotations(
            title: "List Files",
            readOnlyHint: true,
            destructiveHint: false,
            idempotentHint: true,
            openWorldHint: false
        )
        let destructiveAnnotations = MCPToolAnnotations(
            title: "Drop Table",
            readOnlyHint: false,
            destructiveHint: true,
            idempotentHint: false,
            openWorldHint: false
        )

        let trace = W3CTraceContext.generate(sampled: true)
        let parsedTrace = W3CTraceContext.parse(trace.traceparent)
        let metaHasTraceparent = (trace.metaDictionary["traceparent"] == trace.traceparent)

        let passed = (negotiatedModern == "2026-07-28")
            && (negotiatedLegacy == MCPProtocolVersion.legacyFallback)
            && readOnlyAnnotations.isReadOnly
            && (readOnlyAnnotations.policyBadgeText == "Read-Only")
            && destructiveAnnotations.isDestructive
            && (destructiveAnnotations.policyBadgeText == "Destructive")
            && (parsedTrace == trace)
            && trace.isSampled
            && metaHasTraceparent

        return WorkflowResult(
            id: 13,
            name: name,
            passed: passed,
            evidence: "proto=\(negotiatedModern)/\(negotiatedLegacy) badges=\(readOnlyAnnotations.policyBadgeText),\(destructiveAnnotations.policyBadgeText) traceparent=\(trace.traceparent.prefix(18))..."
        )
    }

    // MARK: 14 — Deep-link routing (apexagent://) + Spotlight continuation handoff
    static func workflow14() async -> WorkflowResult {
        let name = "Deep-link routing + Spotlight handoff"
        let (routineResult, routineMatched, skillResult, skillMatched, commandResult, commandMatched, navRoutineId, navSkillName, navLastCommand) = await MainActor.run {
            let navState = DeepLinkNavigationState()

            let routineItem = SpotlightIndexer.makeRoutineItem(
                id: "nightly-audit",
                name: "Nightly Security Audit",
                descriptionText: "Run hygiene audit",
                trigger: "0 2 * * *"
            )
            let skillItem = SpotlightIndexer.makeSkillItem(
                name: "code-review",
                description: "Automated PR review",
                triggerTerms: ["review", "diff"]
            )
            let commandItem = SpotlightIndexer.makeSlashCommandItem(
                name: "/doctor",
                summary: "Run subsystem health checks",
                keywords: ["diagnostics"]
            )

            let rResult = SpotlightIndexer.handleSpotlightActivation(
                uniqueIdentifier: routineItem.uniqueIdentifier,
                navigationState: navState
            )
            let rMatched = (navState.selectedRoutineId == "nightly-audit")

            let sResult = SpotlightIndexer.handleSpotlightActivation(
                uniqueIdentifier: skillItem.uniqueIdentifier,
                navigationState: navState
            )
            let sMatched = (navState.selectedSkillName == "code-review")

            let cResult = SpotlightIndexer.handleSpotlightActivation(
                uniqueIdentifier: commandItem.uniqueIdentifier,
                navigationState: navState
            )
            let cMatched = (navState.lastExecutedCommand == "doctor")

            return (
                rResult != nil,
                rMatched,
                sResult != nil,
                sMatched,
                cResult != nil,
                cMatched,
                navState.selectedRoutineId,
                navState.selectedSkillName,
                navState.lastExecutedCommand
            )
        }

        let invalidURL = URL(string: "https://example.com/not-apex")!
        let invalidOutcome = DeepLinkRouter.parse(invalidURL)
        let rejectedInvalid: Bool
        if case .failure(.unsupportedScheme) = invalidOutcome {
            rejectedInvalid = true
        } else {
            rejectedInvalid = false
        }

        let passed = routineResult
            && routineMatched
            && skillResult
            && skillMatched
            && commandResult
            && commandMatched
            && rejectedInvalid

        return WorkflowResult(
            id: 14,
            name: name,
            passed: passed,
            evidence: "routine=\(navRoutineId ?? "-") skill=\(navSkillName ?? "-") cmd=\(navLastCommand ?? "-") invalidRejected=\(rejectedInvalid)"
        )
    }

    // MARK: 15 — TickerScheduler adaptive poll coalescing & AppLog / doctor diagnostics
    static func workflow15() async -> WorkflowResult {
        let name = "TickerScheduler coalescing & doctor health check"
        var simulatedNow: TimeInterval = 1_000.0
        let scheduler = TickerScheduler(now: { simulatedNow })

        var firedA = 0
        var firedB = 0
        let policy = PollPolicy(
            baseInterval: 10.0,
            minInterval: 10.0,
            maxInterval: 80.0,
            idleBackoffFactor: 2.0,
            coalesceToleranceFraction: 0.25
        )

        scheduler.register(id: "poller.a", policy: policy) {
            firedA += 1
            return false // idle -> backs off
        }
        simulatedNow = 1_001.5 // within 2.5s coalesce tolerance of poller.a's 1010.0 target
        scheduler.register(id: "poller.b", policy: policy) {
            firedB += 1
            return false
        }

        simulatedNow = 1_010.0
        let dueFirstSweep = scheduler.sweep()
        let nextIntervalAfterIdle = scheduler.tickerState(for: "poller.a")?.nextFireAt ?? 0

        let savings = policy.compareWakeupCounts(windowSeconds: 120.0, idlePollStreak: true)
        let doctorReport = ApexCLIRouter.runDoctor()

        let passed = (dueFirstSweep.count == 2)
            && (firedA == 1 && firedB == 1)
            && (scheduler.coalescedWakeupCount >= 1)
            && (nextIntervalAfterIdle >= 1_030.0 - 0.01)
            && (savings.adaptiveWakeups < savings.legacyWakeups)
            && doctorReport.overallPassed

        return WorkflowResult(
            id: 15,
            name: name,
            passed: passed,
            evidence: "coalesced=\(scheduler.coalescedWakeupCount) wakeups=\(savings.adaptiveWakeups)/\(savings.legacyWakeups) doctorHealthy=\(doctorReport.overallPassed)"
        )
    }
}
