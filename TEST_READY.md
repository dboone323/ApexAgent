# ApexAgent Test Suite — Ready Report

> **2026-10-01 Status**: Remediated all `AUDIT_2026-09-28` findings and completed Phase C Full-Potential Fixes. All placeholders removed; zero skipped tests in `Makefile`; code coverage enabled across all 6 module targets (`ApexAgentCore`, `SharedKit`, `MCPKit`, `SharedModels`, `SharedLogging`, `ApexAgentIntents`). All test targets compile cleanly with zero warnings under Xcode 27 with Swift 6.4 `StrictConcurrency`.

## Test Invocation

To execute the test suite across targets using entitlement-preserving `xcodebuild` (ad-hoc signed with `-` as configured in `project.yml` so `ApexAgent.entitlements` and `Virtualization.framework` entitlements remain embedded):

```bash
# Full unit & integration test plan (with code coverage):
xcodebuild test -project ApexAgent.xcodeproj -scheme ApexAgent -testPlan ApexAgent-UnitTests -destination "platform=macOS"

# Individual suites (using -only-testing: with real suite names):
xcodebuild test -project ApexAgent.xcodeproj -scheme ApexAgent -destination "platform=macOS" -only-testing:ApexAgentContainerTests/ContainerManagerTests
xcodebuild test -project ApexAgent.xcodeproj -scheme ApexAgent -destination "platform=macOS" -only-testing:ApexAgentTests/PlaybookCollaborationTests
xcodebuild test -project ApexAgent.xcodeproj -scheme ApexAgent -destination "platform=macOS" -only-testing:ApexAgentTests/R1R2AdversarialStressTests
xcodebuild test -project ApexAgent.xcodeproj -scheme ApexAgent -destination "platform=macOS" -only-testing:ApexAgentTests/DynamicToolRoutingTests
```

Or via Swift Package Manager (with code coverage and zero skipped tests):

```bash
xcrun swift test --parallel --enable-code-coverage
# Or via Makefile:
make test
```

---

## Test Targets & Coverage Matrix

| Test Target | Files | Framework | `@Test` Functions | `XCTestCase` Classes | Coverage | Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **ApexAgentTests** | 85 Swift files | Mixed (Swift Testing + XCTest) | 591 | 17 | Yes (via `xctestplan` & `--enable-code-coverage`) | **VERIFIED** ✅ |
| **ApexAgentContainerTests** | 1 Swift file | Swift Testing (`@Test`) | 7 | 0 | Yes (via `xctestplan` & `--enable-code-coverage`) | **VERIFIED** ✅ |
| **ApexAgentIntelligenceTests** | 10 Swift files | Swift Testing (`@Test`) | 71 | 0 | Yes (via `xctestplan` & `--enable-code-coverage`) | **VERIFIED** ✅ |
| **ApexAgentUITests** | 7 Swift files | XCTest (`XCTestCase`) | 0 | 6 (UI test classes) | UI test plan (`ApexAgent-UITests`) | **ACTIVE** ✅ |

> **Resolved (2026-09-28 / 2026-10-01)**:
> - Gateway tests that call `ApexGatewayServer.start()` (`ApexGatewayClientTests`, `BackendServiceTests.testRealDaemonCommunication`) pass under CLI `swift test`.
> - `testBrowserAutomation` and `testRealToolsGrepAndGitMCP` pass standalone and in parallel; `--skip` flags have been removed from `Makefile`.

**Totals**: 103 test files · 669 `@Test` functions · 23 `XCTestCase` classes (17 unit/integration + 6 UI) · 4 test targets · mixed Swift Testing + XCTest · code coverage enabled across all 6 library/framework modules (`ApexAgentCore`, `SharedKit`, `MCPKit`, `SharedModels`, `SharedLogging`, `ApexAgentIntents`).

### Target Descriptions

- **ApexAgentTests** — Headless-safe unit + integration tests. Depends only on `ApexAgentCore` + `MCPKit` (no Containerization), so `CoreDevice` is never loaded into the xctest process. Uses both Swift Testing (`@Test`) and XCTest (`XCTestCase`) classes. Contains the E2E feature matrix, creation sheets (`CreationSheetsTests`), playbook collaboration (`PlaybookCollaborationTests`), R1/R2 adversarial stress (`R1R2AdversarialStressTests`), container isolation security (`ContainerIsolationSecurityTests`), MCP dashboard (`MCPServerDashboardTests`), cognitive memory & semantic embeddings (`CognitiveMemoryTests`), tool routing (`DynamicToolRoutingTests`), and milestone stress tests.

- **ApexAgentContainerTests** — Container logic verification. Links `ApexAgentCore` only. Uses Swift Testing (`@Test`) exclusively. Contains `ContainerManagerTests.swift` (7 `@Test` functions).

- **ApexAgentIntelligenceTests** — Vision, FoundationModels, AppleScript, AppKit AppleEvents tests. Depends only on `ApexAgentCore` (no Containerization). Uses Swift Testing (`@Test`) exclusively (10 files, 71 `@Test` functions).

- **ApexAgentUITests** — SwiftUI UI automation tests. Uses XCTest (`XCTestCase`) exclusively (7 files, 6 `XCTestCase` classes). Contains bot workflow UI tests, playbook approval UI, routines & skills UI, settings & MCP dashboard UI, and live agent triage UI tests.

---

## Next Major Features Checklist (M1–M4 + Phase C)

### R1 (M1): Unified Multi-Bot Creation Sheets & SwiftData Persistence
- [x] SwiftData schema validation for `BotProfile`, `BotMemoryEntry`, `Routine`, `Skill`
- [x] Disk synchronization with `~/.apex/skills/` shell scripts and JSON manifests
- [x] Cron expression tokenization, parsing, and next execution date calculation
- [x] Webhook trigger registration and delivery routing
- [x] SwiftUI ViewHosting inspection for `CreateBotSheet`, `CreateRoutineSheet`, `CreateSkillSheet`, `EditBotSheet`, and `SkillsSection` wired in `SettingsView`
- **Suites**: `ApexAgentTests/CreationSheetsTests`, `ApexAgentTests/R1R2AdversarialStressTests`

### R2 (M2): Autonomous Collaboration Playbooks & Structured Concurrency
- [x] Built-in Presets: `Full PR Review Loop`, `Issue-to-Patch Pipeline`, `Weekly Standup and Retrospective`
- [x] Dynamic Participant Assigner with standard 5-bot roster and single-bot fallbacks
- [x] Sequential stage context passing (`{input}`, `{previousOutput}`)
- [x] Parallel turn fan-out execution via Swift structured concurrency (`withThrowingTaskGroup`)
- [x] Human-in-the-loop approval cards with asynchronous pause, resume, rejection gating, 300s fail-safe timeout, and desktop `PlaybookApprovalBannerView` in `BotChatView`
- [x] Live peer delegation event tracking and TraceBus event streaming
- **Suites**: `ApexAgentTests/PlaybookCollaborationTests`, `ApexAgentTests/R1R2AdversarialStressTests`

### R3 (M3): APFS Container Isolation & Security Sandbox
- [x] Micro-VM & process container isolation tiers (`.standard`, `.strict`, `.ephemeralOverlay`)
- [x] APFS Copy-on-Write (CoW) container image snapshotting (`createSnapshot`)
- [x] State corruption mutation and instant snapshot rollback verification (`restoreSnapshot`)
- [x] Host boundary violation defense (blocking `~/Desktop`, `~/Documents`, `~/Downloads`, `/System`, `/Library`, root `/`)
- [x] Symlink traversal blocking (`SecuritySandboxError.symlinkTraversal`) and dangerous shell command sanitization
- [x] Full `sandboxctl` CLI subcommands (`run`, `status`, `snapshot`, `verify-security`)
- **Suites**: `ApexAgentTests/ContainerIsolationSecurityTests`, `ApexAgentContainerTests/ContainerManagerTests`

### R4 (M4): MCP Server Health Dashboard & Dynamic Script Editor
- [x] MCP client health checks, circuit breaker tripping, and manual/automated reset
- [x] Live roundtrip latency measurement (`measureLatency()`) in milliseconds
- [x] Dynamic tool catalog discovery (`listRegisteredTools()`) and Xcode 27 MCP auto-seeding (`xcodebuildmcp`, `xcode-native`)
- [x] Dynamic Script Editor test runner capturing exit code, separate stdout/stderr pipes, and duration
- [x] DynamicToolbox custom tool registration and execution
- **Suites**: `ApexAgentTests/MCPServerDashboardTests`, `ApexAgentTests/MCPResilienceTests`

### Tier 4: Real-World Application Scenarios (E2E Feature Matrix)
- [x] **Scenario 1**: Routine creation -> automated trigger evaluation (cron / interval / webhook) -> bot dispatch
- [x] **Scenario 2**: Custom skill creation -> filesystem script authoring -> SwiftData persistence -> DynamicToolbox sync
- [x] **Scenario 3**: Autonomous Playbook execution -> participant assignment -> multi-bot sequential & parallel stages -> approval card gating
- [x] **Scenario 4**: Container isolation -> baseline snapshot creation -> state mutation -> snapshot rollback & cleanup
- [x] **Scenario 5**: Host boundary violation defense -> symlink traversal block -> sandbox escape prevention
- **Suite**: `ApexAgentTests/E2EFeatureMatrixTests`

---

## Test Verification Summary

- **Test Targets**: 4 (`ApexAgentTests`, `ApexAgentContainerTests`, `ApexAgentIntelligenceTests`, `ApexAgentUITests`)
- **Total Test Files**: 103 Swift source files (85 + 1 + 10 + 7)
- **Total `@Test` Functions**: 669 (Swift Testing: 591 + 7 + 71 + 0)
- **Total `XCTestCase` Classes**: 23 (XCTest: 17 in `ApexAgentTests` + 6 in `ApexAgentUITests`)
- **Frameworks**: Mixed — Swift Testing (`@Test`) + XCTest (`XCTestCase`)
- **Coverage**: Configured via `ApexAgent-UnitTests.xctestplan` for `ApexAgentCore`, `SharedKit`, `MCPKit`, `SharedModels`, `SharedLogging`, and `ApexAgentIntents` (all 6 module targets), plus `--enable-code-coverage` in `Makefile`
- **Mock/Placeholder Count**: 0 — all tests execute real functional validations.
