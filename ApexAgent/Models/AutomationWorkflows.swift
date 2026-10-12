import Foundation
import SwiftData
import SharedKit

// MARK: - Automation Workflows
//
// Ten local automation workflows wired to ApexAgent's REAL code paths
// (tools, StateGraph, AgentRegistry, ProjectAuditor, SwiftData persistence).
// No third-party services, no network. Each workflow returns a WorkflowResult
// with a hard pass/fail verdict plus the evidence it verified.
//
// Run them with:  swift run apexflow            (all)
//                 swift run apexflow 3 7        (selected)

public struct WorkflowResult: Codable, Sendable, Equatable {
    public let id: Int
    public let name: String
    public let passed: Bool
    public let evidence: String

    public init(id: Int, name: String, passed: Bool, evidence: String) {
        self.id = id
        self.name = name
        self.passed = passed
        self.evidence = evidence
    }

    public var line: String {
        "\(passed ? "PASS" : "FAIL") [\(id)] \(name) — \(evidence)"
    }
}

public struct WorkflowDescriptor: Codable, Sendable, Equatable {
    public let id: Int
    public let name: String
    public let subsystems: String

    public init(id: Int, name: String, subsystems: String) {
        self.id = id
        self.name = name
        self.subsystems = subsystems
    }
}

@MainActor
public enum ApexWorkflows {

    // MARK: Harness

    /// Builds an orchestrator wired to an in-memory SwiftData store with all
    /// folder permissions granted and confirmation auto-approved, so tool
    /// calls execute for real without UI prompts.
    static func makeOrchestrator(workspace: String) throws -> AgentOrchestrator {
        let orchestrator = AgentOrchestrator()
        let schema = Schema([
            Conversation.self, Message.self, AgentMemory.self, AppPermissions.self,
            ProjectModel.self, TaskModel.self, SprintModel.self, CodeIssueModel.self,
            ReviewSession.self, WeeklyReflection.self,
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        orchestrator.modelContext = ModelContext(container)

        let perms = AppPermissions()
        perms.musicFolderAllowed = true
        perms.desktopFolderAllowed = true
        perms.documentsFolderAllowed = true
        perms.downloadsFolderAllowed = true
        orchestrator.modelContext?.insert(perms)
        orchestrator.permissions = perms

        orchestrator.currentWorkspacePath = workspace
        orchestrator.confirmationGateway = { _, _, _ in true }

        let conversation = Conversation(title: "apexflow")
        orchestrator.modelContext?.insert(conversation)
        orchestrator.currentConversation = conversation
        return orchestrator
    }

    /// Scratch directory inside NSTemporaryDirectory (an allowed sandbox root).
    static func makeScratch(_ label: String) throws -> String {
        let dir = NSTemporaryDirectory() + "apexflow-\(label)-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func allDescriptors() -> [WorkflowDescriptor] {
        [
            WorkflowDescriptor(id: 1, name: "AI Code Review findings", subsystems: "CodeReviewPersistenceTools, ProjectAuditor"),
            WorkflowDescriptor(id: 2, name: "NL query over project store", subsystems: "SwiftData ModelContext, ProjectModel"),
            WorkflowDescriptor(id: 3, name: "Test generation & repair", subsystems: "RunSomeTests, DiffHelper"),
            WorkflowDescriptor(id: 4, name: "Documentation pipeline", subsystems: "FileSystemTools, Markdown Generator"),
            WorkflowDescriptor(id: 5, name: "CI/CD failure triage", subsystems: "Terminal/PTY, OSLog Diagnostics"),
            WorkflowDescriptor(id: 6, name: "Multi-agent orchestration", subsystems: "StateGraph, BotSession swarm"),
            WorkflowDescriptor(id: 7, name: "Pipeline & schema-drift monitor", subsystems: "ContainerManager, DiagnosticManager"),
            WorkflowDescriptor(id: 8, name: "Ticket triage & routing", subsystems: "AgentRegistry, DynamicToolbox"),
            WorkflowDescriptor(id: 9, name: "Legacy refactor sweep", subsystems: "DiffStats, WorkspaceProactiveAuditor"),
            WorkflowDescriptor(id: 10, name: "Personal productivity agent", subsystems: "DailyBriefing, RoutineManager"),
            WorkflowDescriptor(id: 11, name: "Pre-push security & hygiene self-audit", subsystems: "RepoHygieneAuditor, SwiftSyntaxLintGate"),
            WorkflowDescriptor(id: 12, name: "Persistence corruption quarantine & recovery", subsystems: "ResilientJSONStore, TraceBus"),
            WorkflowDescriptor(id: 13, name: "MCP 2026-07-28 negotiation & W3C traceparent", subsystems: "MCPProtocolVersion, MCPToolAnnotations, W3CTraceContext"),
            WorkflowDescriptor(id: 14, name: "Deep-link routing + Spotlight handoff", subsystems: "DeepLinkRouter, SpotlightIndexer"),
            WorkflowDescriptor(id: 15, name: "TickerScheduler coalescing & doctor health check", subsystems: "TickerScheduler, PollPolicy, ApexCLIRouter"),
            WorkflowDescriptor(id: 16, name: "Supply-chain dependency lock & SBOM audit", subsystems: "DependencyLockAuditor, CycloneDX SBOM"),
            WorkflowDescriptor(id: 17, name: "Git pre-commit & Conventional Commit gate", subsystems: "GitHookGate, RepoHygieneAuditor"),
            WorkflowDescriptor(id: 18, name: "CLI shell completions & man(1) generator", subsystems: "CLICompletionGenerator, ApexCLIRouter"),
            WorkflowDescriptor(id: 19, name: "Bundle entitlements & build-graph parity", subsystems: "BundleIntegrityVerifier, DeepLinkRouter"),
            WorkflowDescriptor(id: 20, name: "CI pipeline sync & xcresult trend gate", subsystems: "CIPipelineValidator, XCResultTrendAnalyzer"),
            WorkflowDescriptor(id: 21, name: "Code coverage threshold & changed-file diff gate", subsystems: "CodeCoverageGate, llvm-cov, xccov"),
            WorkflowDescriptor(id: 22, name: "Privacy manifest & Required-Reason API drift audit", subsystems: "PrivacyManifestDriftAuditor, PrivacyInfo.xcprivacy"),
            WorkflowDescriptor(id: 23, name: "Conventional Changelog & SemVer bump calculator", subsystems: "ReleaseChangelogEngine, SemanticVersion"),
            WorkflowDescriptor(id: 24, name: "Release version parity & readiness gate", subsystems: "ReleaseChangelogEngine, Info.plist, project.yml"),
            WorkflowDescriptor(id: 25, name: "SLSA v1.0 build provenance & notarization verification", subsystems: "ReleaseProvenanceGenerator, CryptoKit SHA-256"),
            WorkflowDescriptor(id: 26, name: "SARIF v2.1.0 security & static analysis report export", subsystems: "SARIFReportExporter, RepoHygieneAuditor"),
            WorkflowDescriptor(id: 27, name: "Xcode .xctestplan timeout & coverage target audit", subsystems: "TestPlanIntegrityAuditor, xctestplan"),
            WorkflowDescriptor(id: 28, name: "Workspace source complexity & asset footprint gate", subsystems: "ArtifactSizeBudgetGate, Resources"),
            WorkflowDescriptor(id: 29, name: "CLI subcommand contract & JSON smoke-test matrix", subsystems: "CLISmokeTestHarness, ApexCLIRouter"),
            WorkflowDescriptor(id: 30, name: "Full 11-check ApexAgent Doctor subsystem verification", subsystems: "ApexCLIRouter.runDoctor, DoctorReport"),
            WorkflowDescriptor(id: 31, name: "OpenTelemetry & W3C trace context exporter validation", subsystems: "TraceSpanExporter, W3CTraceContext"),
            WorkflowDescriptor(id: 32, name: "MCP tool permissions & host sandboxing security gate", subsystems: "MCPPolicyAuditor, MCPServerConfig"),
            WorkflowDescriptor(id: 33, name: "Apple Virtualization & OCI container isolation policy auditor", subsystems: "ContainerPolicyAuditor, ContainerSecurityConfig"),
            WorkflowDescriptor(id: 34, name: "Collaborative mesh authentication & P2P grant rate-limiting gate", subsystems: "MeshSecurityAuditor, MeshAuthConfig"),
            WorkflowDescriptor(id: 35, name: "Cognitive memory compaction & semantic vector integrity gate", subsystems: "MemoryCompactionAuditor, CognitiveMemoryEngine"),
            WorkflowDescriptor(id: 36, name: "Spotlight search contract & index attribute integrity auditor", subsystems: "SpotlightContractAuditor, SpotlightIndexer"),
            WorkflowDescriptor(id: 37, name: "MetricKit telemetry anonymization & signed crash report packaging", subsystems: "CrashReportPackager, MetricDiagnosticPayload"),
            WorkflowDescriptor(id: 38, name: "Deep-link action dispatcher & URL scheme route gate", subsystems: "DeepLinkRouteGate, DeepLinkRouter"),
            WorkflowDescriptor(id: 39, name: "Eleven-check unified subsystem doctor diagnostic verification", subsystems: "ApexCLIRouter.runDoctor, DoctorReport"),
            WorkflowDescriptor(id: 40, name: "Full-system multi-subsystem resilience audit", subsystems: "RepoHygiene, DependencyLock, Bundles, CLISmoke"),
            WorkflowDescriptor(id: 41, name: "Tool execution safety sandbox & workspace containment gate", subsystems: "ToolExecutionSandboxGate, SandboxSecurityConfig"),
            WorkflowDescriptor(id: 42, name: "Model provider fault-tolerant circuit breaker & failover gate", subsystems: "ModelCircuitBreaker, ProviderFallbackExecutor"),
            WorkflowDescriptor(id: 43, name: "App Intents schema & Siri Shortcuts parameter sanitization audit", subsystems: "AppIntentsContractAuditor, AppIntentDescriptor"),
            WorkflowDescriptor(id: 44, name: "Companion camera & sensor privacy consent & coordinate coarsening gate", subsystems: "CompanionSensorConsentGate, CompanionSensorPrivacyConfig"),
            WorkflowDescriptor(id: 45, name: "Multi-agent session coordination & deadlock cycle detection gate", subsystems: "SessionCoordinationAuditor, AgentSessionNode"),
            WorkflowDescriptor(id: 46, name: "Accessibility Omni-Targeter & Screen perception coordinate normalization audit", subsystems: "ScreenPerceptionContractAuditor, TargetUIElementSpec"),
            WorkflowDescriptor(id: 47, name: "SwiftData SQLite store header magic bytes, permission & checksum audit", subsystems: "SwiftDataStoreIntegrityGate, SwiftDataStoreMetadata"),
            WorkflowDescriptor(id: 48, name: "Network diagnostics host reachability & SSRF metadata protection gate", subsystems: "NetworkResilienceAuditor, NetworkProbeSpec"),
            WorkflowDescriptor(id: 49, name: "Eleven-check unified subsystem doctor diagnostic verification", subsystems: "ApexCLIRouter.runDoctor, DoctorReport"),
            WorkflowDescriptor(id: 50, name: "Multi-subsystem security policy audit & sandbox compliance verification", subsystems: "ApexCLIRouter.renderImmediateSubcommand, ApexPolicyAuditReport"),
            WorkflowDescriptor(id: 51, name: "MCPKit wire protocol framing & message integrity gate", subsystems: "MCPWireProtocolAuditor, FrameBuffer"),
            WorkflowDescriptor(id: 52, name: "SharedContainer cross-process task queue state machine gate", subsystems: "SharedContainerIntegrityAuditor, SharedTaskQueue"),
            WorkflowDescriptor(id: 53, name: "On-device MLX & local LLM memory pressure & sampling gate", subsystems: "MLXRuntimeMemoryAuditor, KVCacheBudget"),
            WorkflowDescriptor(id: 54, name: "Local retrieval index vector parity, norms & chunking gate", subsystems: "RetrievalIndexIntegrityAuditor, VectorClustering"),
            WorkflowDescriptor(id: 55, name: "Multi-agent playbook execution graph, cycles & rollback gate", subsystems: "PlaybookExecutionAuditor, PlaybookDAG"),
            WorkflowDescriptor(id: 56, name: "Ghost cursor & screen highlight overlay geometry clamp gate", subsystems: "OverlayGeometryAuditor, MultiDisplayBounds"),
            WorkflowDescriptor(id: 57, name: "File patch tool fuzzy chunk & CRLF newline gate", subsystems: "FilePatchResilienceAuditor, DiffHunkMatcher"),
            WorkflowDescriptor(id: 58, name: "Application control tool PID liveness & AppleScript gate", subsystems: "ApplicationControlSecurityAuditor, BundleAllowlist"),
            WorkflowDescriptor(id: 59, name: "System diagnostics OSLog query predicate & masking gate", subsystems: "DiagnosticQuerySecurityAuditor, SecretRedactor"),
            WorkflowDescriptor(id: 60, name: "Autonomous workflow milestone 60 & complete hardening loop 11 audit", subsystems: "Loop11MilestoneMatrix, 10SubsystemAudit"),
            WorkflowDescriptor(id: 61, name: "Headless browser automation URL scheme, domain allowlist & SSRF defense gate", subsystems: "BrowserSecurityAuditor, URLSchemeGate"),
            WorkflowDescriptor(id: 62, name: "Visual perception dHash difference calculation & dirty rect bounds gate", subsystems: "VisualPerceptionAuditor, PerceptualDiffHash"),
            WorkflowDescriptor(id: 63, name: "Xcode simulator simctl lifecycle transition & injection defense gate", subsystems: "SimctlSecurityAuditor, SimctlAction"),
            WorkflowDescriptor(id: 64, name: "AppleScript OSA AST compilation & admin privilege execution gate", subsystems: "AppleScriptSecurityAuditor, NSAppleScript"),
            WorkflowDescriptor(id: 65, name: "Personal productivity email CRLF injection & calendar bounds gate", subsystems: "ProductivityAutomationAuditor, EventKitSanitizer"),
            WorkflowDescriptor(id: 66, name: "Companion device mutual TLS & ephemeral PIN pairing gate", subsystems: "CompanionPairingSecurityAuditor, EphemeralPIN"),
            WorkflowDescriptor(id: 67, name: "Multi-agent swarm worker priority scheduling & concurrency throttling gate", subsystems: "SwarmConcurrencyAuditor, PriorityQueue"),
            WorkflowDescriptor(id: 68, name: "Agent turn watchdog step-level deadline & runaway loop gate", subsystems: "TurnWatchdogAuditor, StepDeadlineGate"),
            WorkflowDescriptor(id: 69, name: "Unified 12-check ApexAgent Doctor subsystem health matrix gate", subsystems: "DoctorExpansionAuditor, ApexCLIRouter"),
            WorkflowDescriptor(id: 70, name: "Centurion Milestone: 100-Batch autonomous hardening loop verification & 70-workflow catalog audit", subsystems: "CenturionMilestoneAuditor, 70WorkflowCatalog"),
            WorkflowDescriptor(id: 71, name: "Universal OpenAI-compatible Wire Protocol & SSE Streaming Audit", subsystems: "OpenAICompatibleLanguageModel, OpenAIWireProtocolAuditor"),
            WorkflowDescriptor(id: 72, name: "Anthropic Claude Messages API Integration & Security Audit", subsystems: "AnthropicLanguageModel, AnthropicWireProtocolAuditor"),
            WorkflowDescriptor(id: 73, name: "Slack Block Kit Interactive Approval & HMAC-SHA256 Signature Audit", subsystems: "SlackIntegrationAuditor, SlackMessageBuilder"),
            WorkflowDescriptor(id: 74, name: "Linear GraphQL Project Management & Issue Sync Audit", subsystems: "LinearIntegrationAuditor, LinearGraphQLBuilder"),
            WorkflowDescriptor(id: 75, name: "Web Content Sanitization, Markdown Extraction & SSRF Perimeter Gate", subsystems: "WebReaderTool, WebContentSanitizer, SSRFGuard"),
            WorkflowDescriptor(id: 76, name: "Multi-Vendor Inbound Webhook Verification Gate", subsystems: "WebhookSignatureAuditor"),
            WorkflowDescriptor(id: 77, name: "Claude Desktop & Cursor MCP Config Importer & Remote SSE Security Gate", subsystems: "MCPConfigImportAuditor"),
            WorkflowDescriptor(id: 78, name: "Multi-Cloud Object Storage Artifact Export & S3 SigV4 Expiration Gate", subsystems: "CloudStorageAuditor, SignedURLVerifier"),
            WorkflowDescriptor(id: 79, name: "OpenTelemetry (OTLP) HTTP Trace Telemetry & Span DLP Scrubbing Gate", subsystems: "OTLPExporterAuditor, OTLPTracePayloadBuilder"),
            WorkflowDescriptor(id: 80, name: "External Secret Vault & 1Password Reference Security Gate", subsystems: "ExternalSecretVaultAuditor")
        ]
    }

    public static func run(ids: Set<Int>) async -> [WorkflowResult] {
        let all: [(Int, String, () async -> WorkflowResult)] = [
            (1, "AI-assisted code review + persisted findings", workflow1),
            (2, "Natural-language query over the project store", workflow2),
            (3, "Test generation + self-healing selector repair", workflow3),
            (4, "Documentation generation pipeline", workflow4),
            (5, "CI/CD failure triage agent", workflow5),
            (6, "Multi-agent task orchestration (StateGraph)", workflow6),
            (7, "Pipeline / schema-drift monitoring", workflow7),
            (8, "Ticket triage + routing", workflow8),
            (9, "Legacy refactor modernization sweep", workflow9),
            (10, "Personal productivity agent (briefing + standup)", workflow10),
            (11, "Pre-push security & hygiene self-audit", workflow11),
            (12, "Persistence corruption quarantine & recovery", workflow12),
            (13, "MCP 2026-07-28 negotiation & W3C traceparent", workflow13),
            (14, "Deep-link routing + Spotlight handoff", workflow14),
            (15, "TickerScheduler coalescing & doctor health check", workflow15),
            (16, "Supply-chain dependency lock & SBOM audit", workflow16),
            (17, "Git pre-commit & Conventional Commit gate", workflow17),
            (18, "CLI shell completions & man(1) generator", workflow18),
            (19, "Bundle entitlements & build-graph parity", workflow19),
            (20, "CI pipeline sync & xcresult trend gate", workflow20),
            (21, "Code coverage threshold & changed-file diff gate", workflow21),
            (22, "Privacy manifest & Required-Reason API drift audit", workflow22),
            (23, "Conventional Changelog & SemVer bump calculator", workflow23),
            (24, "Release version parity & readiness gate", workflow24),
            (25, "SLSA v1.0 build provenance & notarization verification", workflow25),
            (26, "SARIF v2.1.0 security & static analysis report export", workflow26),
            (27, "Xcode .xctestplan timeout & coverage target audit", workflow27),
            (28, "Workspace source complexity & asset footprint gate", workflow28),
            (29, "CLI subcommand contract & JSON smoke-test matrix", workflow29),
            (30, "Full 11-check ApexAgent Doctor subsystem verification", workflow30),
            (31, "OpenTelemetry & W3C trace context exporter validation", workflow31),
            (32, "MCP tool permissions & host sandboxing security gate", workflow32),
            (33, "Apple Virtualization & OCI container isolation policy auditor", workflow33),
            (34, "Collaborative mesh authentication & P2P grant rate-limiting gate", workflow34),
            (35, "Cognitive memory compaction & semantic vector integrity gate", workflow35),
            (36, "Spotlight search contract & index attribute integrity auditor", workflow36),
            (37, "MetricKit telemetry anonymization & signed crash report packaging", workflow37),
            (38, "Deep-link action dispatcher & URL scheme route gate", workflow38),
            (39, "Eleven-check unified subsystem doctor diagnostic verification", workflow39),
            (40, "Full-system multi-subsystem resilience audit", workflow40),
            (41, "Tool execution safety sandbox & workspace containment gate", workflow41),
            (42, "Model provider fault-tolerant circuit breaker & failover gate", workflow42),
            (43, "App Intents schema & Siri Shortcuts parameter sanitization audit", workflow43),
            (44, "Companion camera & sensor privacy consent & coordinate coarsening gate", workflow44),
            (45, "Multi-agent session coordination & deadlock cycle detection gate", workflow45),
            (46, "Accessibility Omni-Targeter & Screen perception coordinate normalization audit", workflow46),
            (47, "SwiftData SQLite store header magic bytes, permission & checksum audit", workflow47),
            (48, "Network diagnostics host reachability & SSRF metadata protection gate", workflow48),
            (49, "Eleven-check unified subsystem doctor diagnostic verification", workflow49),
            (50, "Multi-subsystem security policy audit & sandbox compliance verification", workflow50),
            (51, "MCPKit wire protocol framing & message integrity gate", workflow51),
            (52, "SharedContainer cross-process task queue state machine gate", workflow52),
            (53, "On-device MLX & local LLM memory pressure & sampling gate", workflow53),
            (54, "Local retrieval index vector parity, norms & chunking gate", workflow54),
            (55, "Multi-agent playbook execution graph, cycles & rollback gate", workflow55),
            (56, "Ghost cursor & screen highlight overlay geometry clamp gate", workflow56),
            (57, "File patch tool fuzzy chunk & CRLF newline gate", workflow57),
            (58, "Application control tool PID liveness & AppleScript gate", workflow58),
            (59, "System diagnostics OSLog query predicate & masking gate", workflow59),
            (60, "Autonomous workflow milestone 60 & complete hardening loop 11 audit", workflow60),
            (61, "Headless browser automation URL scheme, domain allowlist & SSRF defense gate", workflow61),
            (62, "Visual perception dHash difference calculation & dirty rect bounds gate", workflow62),
            (63, "Xcode simulator simctl lifecycle transition & injection defense gate", workflow63),
            (64, "AppleScript OSA AST compilation & admin privilege execution gate", workflow64),
            (65, "Personal productivity email CRLF injection & calendar bounds gate", workflow65),
            (66, "Companion device mutual TLS & ephemeral PIN pairing gate", workflow66),
            (67, "Multi-agent swarm worker priority scheduling & concurrency throttling gate", workflow67),
            (68, "Agent turn watchdog step-level deadline & runaway loop gate", workflow68),
            (69, "Unified 12-check ApexAgent Doctor subsystem health matrix gate", workflow69),
            (70, "Centurion Milestone: 100-Batch autonomous hardening loop verification & 70-workflow catalog audit", workflow70),
            (71, "Universal OpenAI-compatible Wire Protocol & SSE Streaming Audit", workflow71),
            (72, "Anthropic Claude Messages API Integration & Security Audit", workflow72),
            (73, "Slack Block Kit Interactive Approval & HMAC-SHA256 Signature Audit", workflow73),
            (74, "Linear GraphQL Project Management & Issue Sync Audit", workflow74),
            (75, "Web Content Sanitization, Markdown Extraction & SSRF Perimeter Gate", workflow75),
            (76, "Multi-Vendor Inbound Webhook Verification Gate", workflow76),
            (77, "Claude Desktop & Cursor MCP Config Importer & Remote SSE Security Gate", workflow77),
            (78, "Multi-Cloud Object Storage Artifact Export & S3 SigV4 Expiration Gate", workflow78),
            (79, "OpenTelemetry (OTLP) HTTP Trace Telemetry & Span DLP Scrubbing Gate", workflow79),
            (80, "External Secret Vault & 1Password Reference Security Gate", workflow80),
        ]
        var results: [WorkflowResult] = []
        for (id, _, body) in all where ids.isEmpty || ids.contains(id) {
            results.append(await body())
        }
        return results
    }

    public static func formatJSON(_ results: [WorkflowResult]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(results),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }

    // MARK: - Markdown Catalog Export

    public static func exportWorkflowsCatalogMarkdown() -> String {
        let workflows = allDescriptors()

        var md = "### ⚙️ Autonomous Local Workflows Catalog (\(workflows.count) workflows)\n\n"
        md += "| ID | Workflow Name | Target Subsystems | Engine |\n"
        md += "|---|---|---|---|\n"

        for wf in workflows {
            let safeName = wf.name.replacingOccurrences(of: "|", with: "\\|")
            let safeSub = wf.subsystems.replacingOccurrences(of: "|", with: "\\|")
            md += "| `\(wf.id)` | **\(safeName)** | \(safeSub) | Native Swift 6.4 |\n"
        }
        return md
    }

}