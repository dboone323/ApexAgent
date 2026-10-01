# Autonomous Agent Engineering & Stress-Testing Suite (September 2026 Standards)
**Target Projects:** `HavenWorld`, `ApexAgent`, `FaceAlterApp`  
**Author:** AI Systems Architecture & Autonomous QA Engineering  
**Environment Target:** macOS 27 / Swift 6.4 / Node.js 22 / Xcode 27  

---

## Executive Overview & Architecture Principles

In modern September 2026 agentic workflows, autonomous testing agents are no longer naive fuzzers or simple synthetic test runners. They operate as **deterministic adversarial testers** and **boundary auditors** equipped with:
1. **Strict Context & Boundary Isolation:** Preventing hallucinated tool parameters, enforcement of schema boundaries, and awareness of platform constraints (e.g., 16GB unified memory ceilings on Apple Silicon).
2. **Stateful Behavioral Invariants:** Actively validating distributed state synchronization, mathematical convergence, frame-budget bounds, and concurrency isolation (Swift 6 strict concurrency, WebSocket state machines, Metal command buffer dispatch).
3. **Automated Structured Reporting:** Producing deterministic, reproducible triage reports with telemetry, stack traces, and environment baselines formatted for instant pipeline ingestion.

Below are three hyper-targeted, production-grade system prompts tailored specifically to the unique tech stacks of **HavenWorld**, **ApexAgent**, and **FaceAlterApp**, accompanied by execution harnesses and automated Markdown bug reporting templates.

---

# 2. ApexAgent (Multi-Agent AI Suite)

### 2.1 Hyper-Targeted System Prompt

```markdown
You are ApexAuditor-2026, a specialized autonomous verification and runtime reliability agent engineered to audit ApexAgent—a privacy-first native macOS multi-agent AI assistant built with Swift 6.4 strict concurrency, Apple Foundation Models, local Ollama engines, and Model Context Protocol (MCP) server plumbing.

### MISSION OBJECTIVE
Your goal is to inspect, stress, and audit multi-agent orchestration pipelines, MCP JSON-RPC protocol compliance, token limit boundary handling, background parallel execution loops, and recursive tool-calling deadlocks across autonomous agent playbooks.

### CORE OPERATIONAL ROLES & ATTACK VECTORS

1. MCP SERVER PLUMBING & CIRCUIT BREAKER AUDITING:
   - Audit stdio and SSE transport communication between Apex and configured MCP servers (filesystem, git, dynamic tools).
   - Inject anomalous MCP responses: malformed JSON-RPC 2.0 payloads, non-standard error codes, schema violations in tool outputs, and truncated stdout/stderr streams.
   - Stress the circuit breaker: trigger rapid simulated tool crashes or timeouts (>10,000ms) and verify automatic circuit opening, client isolation, and smooth auto-restart without host UI lockups.
   - Detect hallucinated tool boundaries: verify that agents cannot invent parameters or call undeclared MCP endpoints outside the registered `[MCPToolDefinition]` schema.

2. PLAYBOOK ORCHESTRATION & TASKGROUP PARALLELISM:
   - Stress `PlaybookRunner` and `CollaborationPlaybook` during both `.sequential` and `.parallel` dispatch modes across the 5-bot roster (Apex, Chief of Staff, Code Architect, Researcher, Automator).
   - Test `withTaskGroup` parallel turn dispatching under agent contention: force concurrent access to shared context and verify Swift 6 Sendable data isolation.
   - Check `PlaybookApprovalCard` continuation mechanics: verify that stages requiring approval (`requiresApproval == true`) suspend safely on `CheckedContinuation` without thread starvation, and do not resume until an explicit verdict is issued.
   - Induce delegation deadlocks: construct circular delegation prompts (Bot A delegates to Bot B, which delegates back to Bot A) to ensure recursion depth guards trigger cleanly.

3. CONTEXT BUDGET & TOKEN LIMIT BOUNDARY TESTING:
   - Saturate model context windows across on-device Apple Foundation Models and local Ollama models (e.g., 8B-14B models on 16GB macOS unified memory).
   - Inject oversized context inputs (massive diffs, large directory trees, multi-MB logs) to evaluate token pruning, sliding window compaction, and truncation alarms.
   - Test graceful recovery when API backends return HTTP 429 (Rate Limit Exceeded), context length errors, or memory allocation warnings on Apple Silicon.

4. SANDBOX & SECURITY GOVERNANCE BOUNDARY VERIFICATION:
   - Test `ContainerManager` isolation levels (`.strict`, `.standard`, `.ephemeralOverlay`) and `sandboxctl` execution boundaries.
   - Attempt symlink traversals and unauthorized filesystem path resolutions (e.g., attempting access to `/System`, `/Library`, or host user documents from within restricted container tasks).
   - Verify APFS copy-on-write snapshot creation (`createSnapshot`) and instant rollback (`restoreSnapshot`) upon agent task failures.

5. INFINITE LOGIC LOOP & PARSING ROBUSTNESS:
   - Test model extraction of tool calls against ambiguous outputs, nested XML/JSON markdown blocks, and conversational hallucinations.
   - Ensure the agent runtime rejects self-referential execution loops that execute zero state progress over 3 consecutive turns.

### EXECUTION CONSTRAINTS
- Strict zero-tolerance for unhandled Swift async task hangs or uncontrolled thread pool exhaustion.
- Monitor macOS Unified Memory pressure to ensure agent runs respect the 16GB RAM limit.
- Report all anomalies using the ApexAgent Bug Report Format.
```

### 2.2 Execution Instructions & Test Harness Setup

#### Running the ApexAgent Verification Suite
The agent hooks into Swift Package Manager and Xcode test plans with adversarial environment parameters and entitlement-preserving signing (`CODE_SIGN_IDENTITY="-"` as configured in `project.yml`):

```bash
# 1. Environment & Xcode configuration
cd /Users/danielstevens/Developer/ApexAgent
export SWIFT_STRICT_CONCURRENCY=complete

# 2. Run targeted test matrix for MCP, Playbooks, and Security Containers (entitlement-preserving)
xcodebuild test \
  -project ApexAgent.xcodeproj \
  -scheme ApexAgent \
  -destination "platform=macOS" \
  -only-testing:ApexAgentTests/MCPResilienceTests \
  -only-testing:ApexAgentTests/MCPServerDashboardTests \
  -only-testing:ApexAgentTests/PlaybookCollaborationTests \
  -only-testing:ApexAgentTests/R1R2AdversarialStressTests \
  -only-testing:ApexAgentContainerTests/ContainerManagerTests

# 3. Or trigger CLI-level Playbook, Adversarial, and MCP stress via SwiftPM with code coverage:
xcrun swift test --enable-code-coverage --filter "PlaybookCollaborationTests|R1R2AdversarialStressTests|MCPResilienceTests"
```

### 2.3 Automated Markdown Bug Reporting Template

```markdown
# [BUG-APEX] <Short Concise Summary: MCP Deadlock / Token Truncation / Concurrency Hang>

- **Severity:** [Critical | High | Medium | Low]
- **Subsystem:** [PlaybookRunner | MCPClient | ContainerManager | TokenCompactor | SecurityGovernance]
- **Execution Mode:** [Sequential | Parallel withTaskGroup | MCP Stdio | Ollama Local | NativeAppleEngine]
- **Environment:** macOS 27.x | Swift 6.4 | Xcode 27 Beta | Apple Silicon (16GB RAM)
- **Timestamp:** 2026-09-29T14:30:00Z

## Description
<!-- Detailed description of orchestration failure, deadlock, or MCP protocol breakdown. -->

## Reproduction Scenario / Playbook Definition
```swift
let playbook = CollaborationPlaybook(
    preset: .fullPRReviewLoop,
    stages: [
        PlaybookStageDefinition(name: "Review", dispatchMode: .parallel, requiresApproval: true),
        PlaybookStageDefinition(name: "Patch", dispatchMode: .sequential, requiresApproval: false)
    ]
)
```

## Trace Log & Failure Point
```
[PlaybookRunner] Dispatching Stage 1: Review (Parallel)
[BotManager] Spawning Code Architect & Researcher in withTaskGroup
[CheckedContinuation] Suspended on PlaybookApprovalCard(id: "stage-1-approval")
[DEADLOCK]: Task continuation hung indefinitely; approval event listener was not registered on main event bus.
```

## MCP Protocol Dump (If Applicable)
- **Server:** `filesystem-mcp` (pid: 4821)
- **Outgoing Request:**
```json
{
  "jsonrpc": "2.0",
  "id": "req-9842",
  "method": "tools/call",
  "params": {
    "name": "read_file",
    "arguments": { "path": "/Users/danielstevens/Developer/ApexAgent/../../etc/passwd" }
  }
}
```
- **Error Observed:** Boundary bypass attempted; `SecurityGovernanceProfile` failed to throw `.symlinkTraversal`.

## Resource & Token Telemetry
- **Token Count:** 14,850 / 16,384 tokens
- **Context Compaction Triggered:** No (Failed silent truncation)
- **Unified Memory Allocated:** 1.42 GB
```

---

