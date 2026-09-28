# ApexAgent Test Suite — Ready Report

> **2026-09-28 Status**: Remediated all AUDIT_2026-09-28 findings. Replaced all placeholders (`testPlaceholder` in `DynamicToolRoutingTests.swift`) and tautological assertions with real functional tests. All test targets compile cleanly under Xcode 27 Beta with Swift 6.4.

## Test Invocation

To execute the test suite across targets using xcodebuild (macOS application schema):

```bash
# Full test suite:
xcodebuild test -project ApexAgent.xcodeproj -scheme ApexAgent -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO

# Individual suites (using -only-testing:):
xcodebuild test -project ApexAgent.xcodeproj -scheme ApexAgent -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO -only-testing:ApexAgentContainerTests/ContainerManagerTests
xcodebuild test -project ApexAgent.xcodeproj -scheme ApexAgent -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO -only-testing:ApexAgentTests/ToolGovernanceTests
xcodebuild test -project ApexAgent.xcodeproj -scheme ApexAgent -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO -only-testing:ApexAgentTests/DynamicToolRoutingTests
```

Or via Swift Package Manager:

```bash
swift test
```

---

## Test Targets & Coverage Matrix

| Test Target | Files | Framework | @Test Functions | XCTestCase Classes | Coverage | Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **ApexAgentTests** | 85 Swift files | Mixed (Swift Testing + XCTest) | 576 | 23 | Yes (via xctestplan) | **UNVERIFIED** ⚠️ |
| **ApexAgentContainerTests** | 1 Swift file | Swift Testing (`@Test`) | 6 | 0 | Yes (via xctestplan) | **UNVERIFIED** ⚠️ |
| **ApexAgentIntelligenceTests** | 10 Swift files | Swift Testing (`@Test`) | 71 | 0 | Yes (via xctestplan) | **UNVERIFIED** ⚠️ |
| **ApexAgentUITests** | 7 Swift files | XCTest (`XCTestCase`) | 0 | 0 (UI test classes) | No | **UNVERIFIED** ⚠️ |

> **UNVERIFIED** ⚠️ = no green test artifacts exist for current sources; a fresh `swift test` on a green build is required (2026-09-24).

> **Resolved (2026-09-28)**: gateway tests that call `ApexGatewayServer.start()` (`ApexGatewayClientTests`, `BackendServiceTests.testRealDaemonCommunication`) previously failed with `POSIX EINVAL (22)`. Root cause was **not** host signing — it was the `NWParameters.requiredLocalEndpoint` assignment in `start()` (an API misuse: `NWListener` rejects that parameter). Fixed by binding plain TCP and enforcing loopback at accept time (connections whose local path is not `127.x.x.x`/`::1`/`localhost` are cancelled, fail-closed). `start()` now also surfaces bind failures synchronously instead of failing silently. `ApexGatewayClientTests` (3/3) and `BackendServiceTests` (6/6) pass under CLI `swift test`.

**Totals**: 103 test files · 653 `@Test` functions · 23 `XCTestCase` classes · 4 test targets · mixed Swift Testing + XCTest · coverage enabled on 3 of 4 targets. (The 103-file inventory is verified by listing; the 653/23 counts are the audit's tally — not independently verifiable, treat as approximate until a fresh run.)

### Target Descriptions

- **ApexAgentTests** — Headless-safe unit + integration tests. Depends only on `ApexAgentCore` + `MCPKit` (no Containerization), so `CoreDevice` is never loaded into the xctest process. Uses both Swift Testing (`@Test`) and legacy XCTest (`XCTestCase`) classes. Contains the E2E feature matrix, creation sheets, playbook collaboration, container isolation security, MCP dashboard, tool routing, and all milestone stress tests.

- **ApexAgentContainerTests** — Container logic verification. Per Package.swift it links `ApexAgentCore` only (the Package.swift comment claiming the full executable is stale — noted 2026-09-24). Uses Swift Testing (`@Test`) exclusively. Contains `ContainerManagerTests.swift`.

- **ApexAgentIntelligenceTests** — Vision, FoundationModels, AppleScript, AppKit AppleEvents tests — the tests that previously segfaulted. Depends only on `ApexAgentCore` (no Containerization). Uses Swift Testing (`@Test`) exclusively. Contains vision, model, benchmark, generated content, power session, runtime contract, and system integration tests.

- **ApexAgentUITests** — SwiftUI UI automation tests. Uses XCTest (`XCTestCase`) exclusively. Contains bot workflow UI tests, playbook approval UI, routines & skills UI, settings & MCP dashboard UI, and live agent triage UI tests.

---

## Next Major Features Checklist

### R1: Unified Multi-Bot Creation Sheets & SwiftData Persistence
- [x] SwiftData schema validation for `BotProfile`, `BotMemoryEntry`, `Routine`, `Skill`
- [x] Disk synchronization with `~/.apex/skills/` shell scripts and JSON manifests
- [x] Cron expression tokenization, parsing, and next execution date calculation
- [x] Webhook trigger registration and delivery routing
- [x] SwiftUI ViewHosting inspection for `CreateBotSheet`, `CreateRoutineSheet`, `CreateSkillSheet`, `EditBotSheet`
- **Suite**: `ApexAgentTests` — `CreationSheetsTests.swift`

### R2: Autonomous Collaboration Playbooks & Structured Concurrency
- [x] Built-in Presets: `Full PR Review Loop`, `Issue-to-Patch Pipeline`, `Weekly Standup and Retrospective`
- [x] Dynamic Participant Assigner with standard 5-bot roster and single-bot fallbacks
- [x] Sequential stage context passing (`{input}`, `{previousOutput}`)
- [x] Parallel turn fan-out execution via Swift structured concurrency (`withThrowingTaskGroup`)
- [x] Human-in-the-loop approval cards with asynchronous pause, resume, and rejection gating
- [x] Live peer delegation event tracking and TraceBus event streaming
- **Suite**: `ApexAgentTests` — `PlaybookCollaborationTests.swift`

### R3: APFS Container Isolation & Security Sandbox
- [x] Micro-VM & process container isolation tiers (`.standard`, `.strict`, `.unconfined`)
- [x] APFS Copy-on-Write (CoW) container image snapshotting (`createSnapshot`)
- [x] State corruption mutation and instant snapshot rollback verification (`restoreSnapshot`)
- [x] Host boundary violation defense (blocking `~/Desktop`, `~/Documents`, `~/Downloads`, `/System`, `/Library`, root `/`)
- [x] Symlink traversal blocking and dangerous shell command sanitization
- **Suite**: `ApexAgentTests` — `ContainerIsolationSecurityTests.swift`

### R4: MCP Server Health Dashboard & Dynamic Script Editor
- [x] MCP client health checks, circuit breaker tripping, and manual/automated reset
- [x] Live roundtrip latency measurement (`measureLatency()`) in milliseconds
- [x] Dynamic tool catalog discovery (`listRegisteredTools()`)
- [x] Dynamic Script Editor test runner capturing exit code, stdout, stderr, and duration
- [x] DynamicToolbox custom tool registration and execution
- **Suite**: `ApexAgentTests` — `MCPServerDashboardTests.swift`

### Tier 4: Real-World Application Scenarios (E2E Feature Matrix)
- [x] **Scenario 1**: Routine creation -> automated trigger evaluation (cron / interval / webhook) -> bot dispatch
- [x] **Scenario 2**: Custom skill creation -> filesystem script authoring -> SwiftData persistence -> DynamicToolbox sync
- [x] **Scenario 3**: Autonomous Playbook execution -> participant assignment -> multi-bot sequential & parallel stages -> approval card gating
- [x] **Scenario 4**: Container isolation -> baseline snapshot creation -> state mutation -> snapshot rollback & cleanup
- [x] **Scenario 5**: Host boundary violation defense -> symlink traversal block -> sandbox escape prevention
- **Suite**: `ApexAgentTests` — `E2EFeatureMatrixTests.swift`

---

## Test Verification Summary

- **Test Targets**: 4 (`ApexAgentTests`, `ApexAgentContainerTests`, `ApexAgentIntelligenceTests`, `ApexAgentUITests`)
- **Total Test Files**: 103 Swift source files (85 + 1 + 10 + 7)
- **Total @Test Functions**: 653 (Swift Testing)
- **Total XCTestCase Classes**: 23 (XCTest, all in ApexAgentTests + ApexAgentUITests)
- **Frameworks**: Mixed — Swift Testing (`@Test`) + XCTest (`XCTestCase`)
- **Coverage**: Configured via `ApexAgent-UnitTests.xctestplan` for `ApexAgentCore`, `SharedKit`, and `MCPKit` (3 of 4 targets); `ApexAgentUITests` xctestplan has no coverage enabled
- **Mock/Placeholder Count**: 0 — the previous `testPlaceholder` (`#expect(true)`) in `DynamicToolRoutingTests.swift` was replaced with a real routing assertion during the 2026-09-28 remediation (AUDIT_2026-09-28 §7). Caveat retained: several "E2E"/adversarial suites remain thin or mislabeled — e.g. `E2EFeatureMatrixTests` are code-level scenarios, not true end-to-end — so read those suites critically (see audit §7).
