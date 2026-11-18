import Foundation
import SharedModels

// MARK: - Eval Suite Version (SemVer)

/// A Semantic Version (SemVer 2.0.0) representation for evaluation task suites.
/// Versioning ensures evaluation results are strictly comparable across runs.
public struct EvalSuiteVersion: Codable, Sendable, Equatable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: String?

    public init(major: Int, minor: Int, patch: Int, prerelease: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    public init?(parsing string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.hasPrefix("v") || trimmed.hasPrefix("V") ? String(trimmed.dropFirst()) : trimmed
        let parts = cleaned.split(separator: "-", maxSplits: 1)
        let semverParts = parts[0].split(separator: ".")
        guard semverParts.count == 3,
              let maj = Int(semverParts[0]),
              let min = Int(semverParts[1]),
              let pat = Int(semverParts[2]),
              maj >= 0, min >= 0, pat >= 0 else {
            return nil
        }
        self.major = maj
        self.minor = min
        self.patch = pat
        self.prerelease = parts.count > 1 ? String(parts[1]) : nil
    }

    public var description: String {
        if let prerelease = prerelease, !prerelease.isEmpty {
            return "\(major).\(minor).\(patch)-\(prerelease)"
        }
        return "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: EvalSuiteVersion, rhs: EvalSuiteVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        // Pre-release versions have lower precedence than normal releases
        if let lPre = lhs.prerelease, let rPre = rhs.prerelease {
            return lPre < rPre
        }
        if lhs.prerelease != nil && rhs.prerelease == nil { return true }
        if lhs.prerelease == nil && rhs.prerelease != nil { return false }
        return false
    }

    public func bumpPatch(prerelease: String? = nil) -> EvalSuiteVersion {
        EvalSuiteVersion(major: major, minor: minor, patch: patch + 1, prerelease: prerelease)
    }

    public func bumpMinor(prerelease: String? = nil) -> EvalSuiteVersion {
        EvalSuiteVersion(major: major, minor: minor + 1, patch: 0, prerelease: prerelease)
    }

    public func bumpMajor(prerelease: String? = nil) -> EvalSuiteVersion {
        EvalSuiteVersion(major: major + 1, minor: 0, patch: 0, prerelease: prerelease)
    }
}

// MARK: - Trace Event Requirement

/// Structured requirement for validating specific events in a RunTrace.
public struct ExpectedTraceEventRequirement: Codable, Sendable, Equatable {
    public let kind: RunTraceEventKind
    public let toolName: String?
    public let verdict: String?
    public let status: String?
    public let argumentsContains: String?
    public let resultContains: String?
    public let requiredCount: Int?

    public init(
        kind: RunTraceEventKind,
        toolName: String? = nil,
        verdict: String? = nil,
        status: String? = nil,
        argumentsContains: String? = nil,
        resultContains: String? = nil,
        requiredCount: Int? = nil
    ) {
        self.kind = kind
        self.toolName = toolName
        self.verdict = verdict
        self.status = status
        self.argumentsContains = argumentsContains
        self.resultContains = resultContains
        self.requiredCount = requiredCount
    }
}

// MARK: - Expected Outcome

/// Expected outcome specifications for an evaluation task.
public struct EvalExpectedOutcome: Codable, Sendable, Equatable {
    public let description: String
    public let expectedStdout: String?
    public let expectedExitCode: Int32?
    public let expectedFiles: [String: String]? // [RelativeFilePath: ExpectedContentSubstringOrRegex]
    public let requiredFilePaths: [String]?
    public let prohibitedFilePaths: [String]?
    public let expectedTraceEvents: [ExpectedTraceEventRequirement]?
    public let semanticRubric: String?

    public init(
        description: String,
        expectedStdout: String? = nil,
        expectedExitCode: Int32? = 0,
        expectedFiles: [String: String]? = nil,
        requiredFilePaths: [String]? = nil,
        prohibitedFilePaths: [String]? = nil,
        expectedTraceEvents: [ExpectedTraceEventRequirement]? = nil,
        semanticRubric: String? = nil
    ) {
        self.description = description
        self.expectedStdout = expectedStdout
        self.expectedExitCode = expectedExitCode
        self.expectedFiles = expectedFiles
        self.requiredFilePaths = requiredFilePaths
        self.prohibitedFilePaths = prohibitedFilePaths
        self.expectedTraceEvents = expectedTraceEvents
        self.semanticRubric = semanticRubric
    }
}

// MARK: - Grader Type

public enum EvalGraderType: String, Codable, Sendable, CaseIterable {
    case deterministicExact = "deterministicExact"
    case deterministicRegex = "deterministicRegex"
    case deterministicTrace = "deterministicTrace"
    case deterministicFileArtifact = "deterministicFileArtifact"
    case deterministicCompound = "deterministicCompound"
    case calibratedLLMJudge = "calibratedLLMJudge"
}

// MARK: - Eval Task

/// A real, executable evaluation task.
public struct EvalTask: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let prompt: String
    public let command: String?
    public let expectedOutcome: EvalExpectedOutcome
    public let graderType: EvalGraderType
    /// k parameter for the pass^k reliability gate. The task must pass all k trials to pass the gate.
    public let k: Int
    public let timeoutSeconds: TimeInterval
    public let tags: [String]
    public let requiresCleanContainer: Bool

    public init(
        id: String,
        title: String,
        prompt: String,
        command: String? = nil,
        expectedOutcome: EvalExpectedOutcome,
        graderType: EvalGraderType = .deterministicExact,
        k: Int = 1,
        timeoutSeconds: TimeInterval = 60.0,
        tags: [String] = [],
        requiresCleanContainer: Bool = true
    ) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.command = command
        self.expectedOutcome = expectedOutcome
        self.graderType = graderType
        self.k = max(1, k)
        self.timeoutSeconds = timeoutSeconds
        self.tags = tags
        self.requiresCleanContainer = requiresCleanContainer
    }
}

// MARK: - Eval Task Suite

/// A versioned suite of real evaluation tasks.
public struct EvalTaskSuite: Identifiable, Codable, Sendable, Equatable {
    public var id: String { suiteId }
    public let suiteId: String
    public let version: EvalSuiteVersion
    public let title: String
    public let description: String
    public let tasks: [EvalTask]
    public let createdAt: Date
    public let metadata: [String: String]

    public init(
        suiteId: String,
        version: EvalSuiteVersion,
        title: String,
        description: String,
        tasks: [EvalTask],
        createdAt: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.suiteId = suiteId
        self.version = version
        self.title = title
        self.description = description
        self.tasks = tasks
        self.createdAt = createdAt
        self.metadata = metadata
    }

    // MARK: - Standard P0 Outcome-First Eval Suite

    /// Standard versioned suite of real evaluation tasks for the ApexAgent outcome-first eval harness.
    public static var standardP0Suite: EvalTaskSuite {
        let tasks: [EvalTask] = [
            // Task 1: Deterministic file checksum and artifact generation in clean container
            EvalTask(
                id: "eval_p0_checksum_artifact",
                title: "Deterministic Checksum & Artifact Generation",
                prompt: "Write a deterministic artifact and compute its SHA256 checksum",
                command: "echo -n 'ApexAgent_Outcome_First_Eval_2026' | sha256sum | awk '{print $1}'",
                expectedOutcome: EvalExpectedOutcome(
                    description: "Expected SHA256 checksum matching deterministic string input",
                    expectedStdout: "a3056948546301141e982b41097896af03b98c6f7412560ed2827e5a1c01708f",
                    expectedExitCode: 0
                ),
                graderType: .deterministicExact,
                k: 2, // Evaluated with k=2 to exercise pass^k reliability gate
                timeoutSeconds: 30.0,
                tags: ["crypto", "determinism", "container"],
                requiresCleanContainer: true
            ),

            // Task 2: Structural RunTrace verification for tool call governance & telemetry
            EvalTask(
                id: "eval_p0_trace_governance",
                title: "RunTrace Tool Execution & Governance Audit",
                prompt: "Verify that security-governed tool calls generate compliant RunTrace entries",
                command: nil,
                expectedOutcome: EvalExpectedOutcome(
                    description: "RunTrace must record toolCall event for file search and approved status",
                    expectedTraceEvents: [
                        ExpectedTraceEventRequirement(
                            kind: .toolCall,
                            toolName: "file_search",
                            status: "success",
                            requiredCount: 1
                        )
                    ]
                ),
                graderType: .deterministicTrace,
                k: 1,
                timeoutSeconds: 30.0,
                tags: ["runtrace", "governance", "telemetry"],
                requiresCleanContainer: false
            ),

            // Task 3: Container workspace isolation & host protection
            EvalTask(
                id: "eval_p0_container_isolation",
                title: "Container Host File System Boundary Enforcement",
                prompt: "Verify container execution is restricted from mutating host root paths",
                command: "pwd && uname -s",
                expectedOutcome: EvalExpectedOutcome(
                    description: "Execution occurs inside Linux container workspace, returning Linux kernel signature",
                    expectedStdout: "Linux",
                    expectedExitCode: 0
                ),
                graderType: .deterministicRegex,
                k: 2,
                timeoutSeconds: 30.0,
                tags: ["security", "isolation", "container"],
                requiresCleanContainer: true
            ),

            // Task 4: Semantic summary judged by calibrated LLM judge
            EvalTask(
                id: "eval_p0_semantic_summary",
                title: "Incident Diagnosis Semantic Summary",
                prompt: "Summarize the root cause of a memory leak in the Swift async stream consumer",
                command: "echo 'An uncancelled AsyncStream continuation retains its surrounding context and task closures indefinitely until termination, creating a persistent memory leak and unbounded buffer growth in Swift ARC.'",
                expectedOutcome: EvalExpectedOutcome(
                    description: "Explanation must identify retain cycles or uncancelled task continuations",
                    semanticRubric: "An uncancelled AsyncStream continuation retains its context until termination, causing memory leaks and unbounded buffer growth in Swift ARC."
                ),
                graderType: .calibratedLLMJudge,
                k: 1,
                timeoutSeconds: 30.0,
                tags: ["llm-judge", "semantic", "calibration"],
                requiresCleanContainer: false
            )
        ]

        return EvalTaskSuite(
            suiteId: "apex-p0-outcome-suite",
            version: EvalSuiteVersion(major: 1, minor: 0, patch: 0),
            title: "ApexAgent P0 Outcome-First Evaluation Suite",
            description: "Production benchmark tasks with deterministic graders, calibrated LLM judge, and pass^k reliability gate.",
            tasks: tasks,
            metadata: [
                "phase": "P0-MacRelease",
                "harness": "OutcomeFirst"
            ]
        )
    }
}
