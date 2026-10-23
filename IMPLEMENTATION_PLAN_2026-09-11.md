# ApexAgent — Complete Audit & Next Steps to 100%

> **Audit Date:** September 11, 2026
> **Toolchain:** Swift 6.4 / Xcode 27.0 (27A5252f) / macOS 27.0 / iOS 27 RC
> **Swift stable release:** 6.3.3 (swift.org install page); Swift 6.4 embedded improvements announced Aug 20 2026
> **Apple SDK pipeline:** Xcode 27 RC (27A266a) shipped Sep 9, iOS/iPadOS/macOS/watchOS/tvOS/visionOS 27.0 RC all shipped Sep 9 2026

---

## Current State Summary

| Metric | Value |
|---|---|
| Source files (`.swift`) | ~165 |
| Test files (`.swift`) | 94 (82 unit, 9 intelligence, 2 UI, 1 container) |
| Total tests passing | 454 (zero mocks — policy compliant) |
| Registered tools | 47 |
| Milestones R1–R4 | ✅ Complete |
| Remaining workstreams | WS3 (LaunchAgent daemon), WS4 (Keychain vault sessions), WS5 (proactive cross-bot handoffs) |
| Overall completion | ~95% |
| SwiftLint installed | ❌ **Not installed** (`command not found`) |
| SwiftFormat installed | ❌ **Not installed** (`command not found`) |
| `.swiftlint.yml` | ❌ **Missing** |
| `.swiftformat` | ❌ **Missing** |
| Documentation accuracy | ⚠️ Multiple inconsistencies across 6 docs |

---

## User Review Required

> [!IMPORTANT]
> **Xcode 27 / macOS 27 / iOS 27 RC just dropped (Sep 9).** The project currently targets macOS 27+ and uses `FoundationModels`. You should decide whether to adopt the Xcode 27 SDK as part of this plan or wait for the GA release. The plan below assumes staying on the current SDK and making targeted Swift 6.4 compliance updates.

> [!WARNING]
> **SwiftLint and SwiftFormat are not installed on this machine.** The plan includes installing them via Homebrew and committing config files. Confirm you want both tools and any preferred rule overrides before execution.

> [!CAUTION]
> **`AgentOrchestrator.swift` is 1,932 lines** and has been flagged in three prior audits as a monolith needing decomposition. This is the highest-risk refactor item. The plan proposes a phased breakup — confirm you want this done now vs. deferred.

---

## Open Questions

> [!IMPORTANT]
> 1. **App group entitlement** is set to `group.com.dboone323.fleet` not `group.com.dboone323.apexagent`. Should this be migrated, or is `fleet` intentional for shared data with another app?

> [!IMPORTANT]
> 2. **Info.plist contains `SUFeedURL` and `SUPublicEDKey`** (Sparkle auto-update keys) but Sparkle is not a dependency. Remove these stale keys?

> [!IMPORTANT]
> 3. **`CollaborativeServer` binds to localhost with no auth/TLS.** Prior audits recommend a strict LAN-only toggle. Should this be enforced now, or is it acceptable for local-only operation?

> [!IMPORTANT]
> 4. **`IMPLEMENTATION_PLAN.md` references the wrong repo** (`dboone323/fleet.workspace`). Confirm this file should be updated to reference `dboone323/ApexAgent`.

> [!IMPORTANT]
> 5. **README claims 32 tools but actual count is 47.** Want the README updated to reflect reality?

---

## Proposed Changes

The plan is organized into 8 work phases. Each phase is independent and can be executed sequentially or in parallel where noted.

---

### Phase 1: Tooling Infrastructure — SwiftLint & SwiftFormat

**Goal:** Install linters, create config files, run first pass, fix auto-fixable violations.

#### [NEW] [.swiftlint.yml](file:///Users/danielstevens/Developer/ApexAgent/.swiftlint.yml)
- Create project-level SwiftLint config with:
  - `strict` mode enabled
  - `excluded: [.build, .dd, .dd-release, Modules/*/Tests]`
  - Custom rules for `nonisolated(unsafe)` usage documentation requirements
  - Opt-in rules: `force_unwrapping`, `implicitly_unwrapped_optional`, `missing_docs`, `closure_body_length`

#### [NEW] [.swiftformat](file:///Users/danielstevens/Developer/ApexAgent/.swiftformat)
- Create SwiftFormat config targeting Swift 6.4:
  - `--swiftversion 6.4`
  - `--indent 4`
  - `--self insert`
  - `--importgrouping alpha`
  - `--stripunusedargs closure-only`
  - `--exclude .build,.dd,.dd-release`

#### [MODIFY] [Makefile](file:///Users/danielstevens/Developer/ApexAgent/Makefile)
- Add `lint`, `format`, `lint-fix` targets that invoke SwiftLint and SwiftFormat

---

### Phase 2: Swift 6.4 Strict Concurrency Compliance

**Goal:** Eliminate all `nonisolated(unsafe)` and `@unchecked Sendable` bypasses, replacing them with proper concurrency primitives.

#### [MODIFY] [AgentOrchestrator.swift](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/AgentOrchestrator.swift)
- Lines 323–325: Replace `nonisolated(unsafe)` Task storage with a proper actor-isolated `TaskGroup` or Swift 6's `Mutex<Task<Void, Never>?>`
- Audit `@MainActor` class-level annotation vs method-level redundancies

#### [MODIFY] [CollaborativeServer.swift](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Models/CollaborativeServer.swift)
- Line 20: Replace `nonisolated(unsafe) var rateLimiters` with `Mutex`-protected or actor-isolated storage

#### [MODIFY] [LaunchAgent.swift](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Models/LaunchAgent.swift)
- Line 79: Replace `nonisolated(unsafe) _agentsDirectory` with a computed property or `let` constant

#### [MODIFY] [LocalRetrievalIndex.swift](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Models/LocalRetrievalIndex.swift)
- Line 73: Replace `nonisolated(unsafe) metadataQuery` — should be actor-isolated or use `@preconcurrency`

#### [MODIFY] [DifferentialScreenPerception.swift](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Tools/DifferentialScreenPerception.swift)
- Line 18: Replace `nonisolated(unsafe) previousFrame` with `Mutex` or actor-isolated storage

#### [MODIFY] [AgentRegistry.swift](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Models/AgentRegistry.swift)
- Line 20: Replace `nonisolated(unsafe) registeredAgents` with proper isolation

#### `@unchecked Sendable` Replacements (all files):
| File | Line(s) | Current | Replacement |
|---|---|---|---|
| `PTYSession.swift` | 30, 34 | `@unchecked Sendable` | Actor wrapping or `Mutex` |
| `ContainerManager.swift` | 760, 778, 801 | `@unchecked Sendable` on helpers | `Mutex` + proper isolation |
| `TraceBus.swift` | 5 | `@unchecked Sendable` | Actor |
| `ToolPolicy.swift` | 18 | `@unchecked Sendable` | `Mutex`-protected storage |
| `DispatchSwarmTool.swift` | 9 | `@unchecked Sendable` | Actor or `Sendable` struct |
| `AskBotTool.swift` | 21 | `@unchecked Sendable` | Actor |
| `WebhookServer.swift` | 13, 21 | `@unchecked Sendable` | Actor |
| `RepeatDetector.swift` | 37 | `@unchecked Sendable` with `NSLock` | Swift 6 `Mutex` |
| `Milestone1ChallengerConcurrencyStressTests.swift` | 143 | `@unchecked Sendable SafeStallCollector` | `Mutex` |

#### [MODIFY] [Package.swift](file:///Users/danielstevens/Developer/ApexAgent/Package.swift)
- Remove `.enableExperimentalFeature("StrictConcurrency")` from all targets (lines 93, 112, 138, 160) — this is the default in Swift 6 and is redundant

---

### Phase 3: AgentOrchestrator Decomposition

**Goal:** Break the 1,932-line monolith into focused components.

#### [MODIFY] [AgentOrchestrator.swift](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/AgentOrchestrator.swift)
- Extract agent session lifecycle into new `AgentSessionCoordinator.swift`
- Extract tool dispatch logic into new `ToolDispatchEngine.swift`
- Extract audit/governance methods (`verifyPathAllowed`, `isFolderAccessRestricted`) into `SecurityAuditor.swift`
- Keep `AgentOrchestrator` as a thin facade (~200 lines) that delegates to these components

#### [NEW] `ApexAgent/Coordinators/AgentSessionCoordinator.swift`
#### [NEW] `ApexAgent/Coordinators/ToolDispatchEngine.swift`
#### [NEW] `ApexAgent/Coordinators/SecurityAuditor.swift`

---

### Phase 4: Documentation Corrections & Alignment

**Goal:** Eliminate all inconsistencies flagged across 6 audit reports.

#### [MODIFY] [README.md](file:///Users/danielstevens/Developer/ApexAgent/README.md)
- Update tool count from 32 → 47
- Update Swift version references to 6.4
- Add SwiftLint/SwiftFormat badge once configs exist

#### [MODIFY] [IMPLEMENTATION_PLAN.md](file:///Users/danielstevens/Developer/ApexAgent/IMPLEMENTATION_PLAN.md)
- Fix repo reference: `dboone323/fleet.workspace` → `dboone323/ApexAgent`
- Remove paid-tier CI suggestions that conflict with free-tier policy in `NEXT_STEPS.md`

#### [MODIFY] [PROJECT.md](file:///Users/danielstevens/Developer/ApexAgent/PROJECT.md)
- Align stated architecture with actual 47-tool, multi-agent, group-chat reality
- Document WS3/WS4/WS5 status as remaining items

#### [MODIFY] [TASK_MANIFEST.md](file:///Users/danielstevens/Developer/ApexAgent/TASK_MANIFEST.md)
- Mark R1–R4 milestones as complete
- Add WS3/WS4/WS5 items with clear acceptance criteria

#### [DELETE] [Package.swift.bak](file:///Users/danielstevens/Developer/ApexAgent/Package.swift.bak) & [Package.swift.bak2](file:///Users/danielstevens/Developer/ApexAgent/Package.swift.bak2)
- Remove stale backup files from repo root

#### Cleanup repo root:
- Remove old build logs (`build.log` through `build12.log`, `current_sources.txt`, `all_swift.txt`, `default.profraw`)
- Add these patterns to `.gitignore`

---

### Phase 5: Resolve TODO/FIXME/HACK Comments

**Goal:** Close all open inline tasks.

| File | Line | Comment | Action |
|---|---|---|---|
| `AutomationWorkflowTests.swift` | 77 | `// TODO: clean up` | Clean up the test fixture teardown |
| `WorkspaceProactiveAuditorTests.swift` | 29 | `// TODO: Optimize calculations` | Evaluate if optimization is needed or remove |
| `WorkspaceProactiveAuditorTests.swift` | 30 | `// FIXME: Handle integer overflow on index` | Add bounds check |
| `ApexAgentTests.swift` | 839 | `// TODO: Implement security audit` | Implement or remove if covered elsewhere |
| `ApexAgentTests.swift` | 864 | `// TODO: Reduce duplication in parsing` | Deduplicate or document as accepted |
| `ApexAgentTests.swift` | 865 | `// FIXME: Guard against empty input` | Add guard clause |

---

### Phase 6: Security & Configuration Fixes

**Goal:** Close security items from prior audits.

#### [MODIFY] [MCPClient](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Models/MCPClient.swift) (process lifecycle)
- Ensure `stop()` kills the full child process tree (not just the parent), preventing orphaned `node`/`zsh` processes

#### [MODIFY] [project.yml](file:///Users/danielstevens/Developer/ApexAgent/project.yml)
- Add missing `ApexAgentIntents` dependency for the `ApexAgent` target

#### [MODIFY] [Info.plist](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Info.plist) (pending user confirmation)
- Remove stale `SUFeedURL` and `SUPublicEDKey` keys

#### [MODIFY] Entitlements (pending user confirmation)
- Evaluate `group.com.dboone323.fleet` → `group.com.dboone323.apexagent`

#### [MODIFY] [PlaybookRunner.swift](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/PlaybookRunner.swift)
- Sanitize user input before string interpolation in prompt templates to prevent prompt injection

#### [MODIFY] [WorkspaceProactiveAuditor.swift](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/WorkspaceProactiveAuditor.swift)
- Replace fallback `NSHomeDirectory() + "/Developer"` with explicit workspace configuration or guarded scan depth limit

---

### Phase 7: Test Suite Hardening

**Goal:** Expand coverage for undertested areas.

#### [MODIFY] [ApexAgentUITests/](file:///Users/danielstevens/Developer/ApexAgent/ApexAgentUITests/)
- Expand from 2 files to cover at least: settings flow, creation sheets, MCP dashboard navigation, playbook execution flow
- Fix `static var activeApp: XCUIApplication?` global mutable state (Swift 6 violation at line 25)

#### [MODIFY] [ApexAgentContainerTests/](file:///Users/danielstevens/Developer/ApexAgent/ApexAgentContainerTests/)
- Expand from 1 file to cover: container lifecycle (create/start/stop/destroy), snapshot management, PTY session I/O

#### New test files needed:
- `SecurityGovernanceTests.swift` — path traversal, symlink resolution, sandbox escape attempts
- `CollaborativeServerTests.swift` — rate limiting, concurrent connections, graceful shutdown
- `LaunchAgentTests.swift` — daemon install/uninstall, watchdog recovery
- `PlaybookRunnerInjectionTests.swift` — prompt injection resistance

---

### Phase 8: Remaining Workstreams (WS3/WS4/WS5)

**Goal:** Complete the final 5% to reach 100%.

#### WS3: LaunchAgent 24/7 Daemon
- Implement Settings UI toggle for `launchctl` load/unload
- Add watchdog heartbeat monitoring
- Add `launchd` plist generation and installation

#### WS4: Persistent Logged-In Tool Sessions (Keychain Vault)
- Implement Keychain Services wrapper for secure credential storage
- Add session persistence across app restarts
- Settings UI for managing stored credentials

#### WS5: Proactive Cross-Bot Handoffs
- Implement agent handoff protocol
- Add UI for viewing handoff history and approving transfers
- Settings UI for configuring handoff policies

---

## Verification Plan

### Automated Tests
```bash
# Full build with strict concurrency
swift build -c debug 2>&1 | grep -c "warning\|error"

# Run complete test suite
swift test -c debug --skip testBrowserAutomation --skip testRealToolsGrepAndGitMCP

# SwiftLint (after installation)
brew install swiftlint && swiftlint lint --strict --reporter json

# SwiftFormat dry-run (after installation)
brew install swiftformat && swiftformat . --dryrun --verbose
```

### Manual Verification
- After Phase 2: Confirm zero `nonisolated(unsafe)` and `@unchecked Sendable` instances via `grep -r`
- After Phase 3: Confirm `AgentOrchestrator.swift` is ≤300 lines
- After Phase 4: Confirm all doc tool counts, repo references, and milestone statuses are accurate
- After Phase 6: Confirm `MCPClient.stop()` leaves no orphaned processes via `ps aux | grep node`
- After Phase 7: Confirm test count ≥500 with all passing
- After Phase 8: Full E2E flow test of daemon install, credential persist, and bot handoff
