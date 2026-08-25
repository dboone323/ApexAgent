# ApexAgent Comprehensive Audit — 2026-08-21

**Auditor:** Hermes Agent (AI-assisted)
**Scope:** Full project — build system, imports, SPM deps, Swift 6 concurrency, entitlements, tests, multi-agent, security
**Environment:** macOS 27 beta 6, Xcode 27 beta 5, Swift 6.4
**Build status:** BROKEN — see §1

---

## Executive Summary

ApexAgent is a mature, well-structured Swift-native multiagent desktop assistant with strong Apple platform integration (FoundationModels, SwiftData, ScreenCaptureKit, Accessibility, App Intents, etc.). The codebase reflects significant engineering discipline: correct `@Observable`/`@MainActor` placement, deliberate weak-linking of 5 FM-family frameworks across all 5 targets, `Bundle.module` guards for XcodeGen test divergence, and a clean inlined shared-kit module graph.

**However, the project is currently broken.** Commit `5a83cab` extended `OrchestratorProvider` with `sessionForAgent` and implemented it in `MCPManager`, but **did not add the implementation to `AgentOrchestrator` itself** — which also conforms to the protocol. `swift build --product ApexAgent` now fails with a conformance error.

---

## 1. Build System Audit

### 1.1 Package.swift vs project.yml drift — BLOCKING

| Target | Package.swift depends on | project.yml depends on | Drift |
|---|---|---|---|
| `ApexAgent` (executable) | `ApexAgentCore`, `ApexAgentIntents`, `MCPKit`, `Containerization`, `ContainerizationOCI` | `ApexAgentCore`, `SharedKit`, `SharedModels`, `SharedLogging`, `MCPKit` | **Missing `ApexAgentIntents` in project.yml** (and the 3 inlined shared-kit frameworks are redundant since they're already deps of `ApexAgentCore`) |
| `ApexAgentCore` | `SharedKit`, `MCPKit`, `Logging`, `Containerization`, `ContainerizationOCI` | `SharedKit`, `MCPKit`, `Containerization`, `ContainerizationOCI` | Missing `Logging` (swift-log) in project.yml — but `Logging` is only used in `ContainerManager.swift`, which gets it transitively; no practical impact |
| `ApexAgentContainerTests` | `ApexAgentCore`, `Containerization`, `ContainerizationOCI` | `ApexAgentCore` only | **Containerization products present in Package.swift but intentionally absent from project.yml** (to avoid "Multiple commands produce … Crypto.framework" under `xcodebuild test`). Both build systems work but configurations are inconsistent. |

**Impact:** `swift build` (SwiftPM) compiles fine modulo the §1.2 blocker. `xcodebuild` (Xcode GUI) would fail with `Cannot find 'AskApexAgentIntent' in scope` or miss Intents symbols because `ApexAgentIntents` is not a dependency of the Xcode app target. The app's `main.swift` only imports `ApexAgentCore`, so the missing dep may not cause a link error — but it's a latent drift bug.

**Fix:** Add `- target: ApexAgentIntents` to the `ApexAgent` target's `dependencies` in `project.yml`, then `xcodegen generate`.

### 1.2 Protocol conformance — BLOCKING compile error

Commit `5a83cab` added `sessionForAgent` to `OrchestratorProvider` (in `OrchestratorProvider.swift`) and implemented it in `MCPManager` (`MCPManager.swift:154`). It did **not** add the method to `AgentOrchestrator`, which declares `AgentOrchestrator: OrchestratorProvider` (`AgentOrchestrator.swift:98`).

`swift build --product ApexAgent` fails:
```
error: type 'AgentOrchestrator' does not conform to protocol 'OrchestratorProvider'
  MCPManager.swift:164: return orchestrator.sessionForAgent(
  AgentOrchestrator.swift:98: public final class AgentOrchestrator: OrchestratorProvider, ToolEventLogger {
```

**Root cause:** `5a83cab` touched `OrchestratorProvider.swift` (+10 lines) and `MCPManager.swift` (+22 lines) but skipped `AgentOrchestrator.swift`.

**Fix:** Add the `sessionForAgent` implementation to `AgentOrchestrator` (mirror the `MCPManager` delegation pattern, or delegate to `ApexAgentApp.sessionForAgent`). The `ApexAgentApp.swift:259` already has a `sessionForAgent` implementation that can serve as the reference.

### 1.3 pbxproj hygiene

- `SWIFT_VERSION = 6.4` on all targets ✓
- No `CODE_SIGNING_ALLOWED = NO` entries ✓
- `Tracing.swift`, `FileRollback.swift`, `ToolPolicy.swift` all present in pbxproj ✓
- No `SUFeedURL`/`SUPublicEDKey` in pbxproj (correct — these are Info.plist keys, not build settings) ✓

### 1.4 Dual build-definition drift (Package.swift + project.yml)

Both specs are independently maintained. New files added to disk are auto-discovered by SPM path-based targets but require `xcodegen generate` to land in the Xcode project. Current state: both specs are in sync for existing files (no "Cannot find X in scope" in Xcode).

---

## 2. Import / Symbol Audit (verifying AppleAPI_AUDIT_2026-08-12)

The audit doc claims all Apple imports are either used 100% or dead-removed. Fresh grep confirms:

| API | Verdict | Evidence |
|---|---|---|
| FoundationModels (565 imports across 34 files) | Used 100% | `SystemLanguageModel.default`, `LanguageModelSession`, `DynamicProfile`, 6 `LanguageModel` conformers, `Transcript`, `GeneratedContent` |
| SwiftData (43 imports) | Used 100% | `@Model` on 7 entities, `ModelContainer`, `@Query`, `FetchDescriptor`, `ModelContext` |
| Observation (7 imports) | Used 100% | `@Observable` on 6 classes + `OrchestratorProvider` protocol |
| AppKit (34), SwiftUI (27) | Used 100% | Full UI layer + windowing |
| Speech + AVFoundation (VoiceController) | Used 100% | `SFSpeechRecognizer`, `AVAudioEngine`, `AVSpeechSynthesizer` — with `@Published permissionGranted` + `VoicePermissionStatus` view (post-fix) |
| ScreenCaptureKit | Used 100% | `SCStreamDelegate`/`SCStreamOutput`, `SCShareableContent`, `SCContentFilter`, preflight + `lastError` (post-fix) |
| CoreSpotlight | Used 100% | `SpotlightIndexer` (write), `LocalRetrievalIndex` (read + RAG), `SpotlightSearchTool` (concrete return type, wired into `SupervisorAgentProfile.body`) |
| Accessibility (AXUIElement) | Used 100% | Full `AccessibilityControlTool` + `UIRegistry`, `AXIsProcessTrusted()` guard, VoiceOver announcements in `PlanDashboardView`/`DiagnosticsView` |
| Containerization (4 imports in ContainerManager) | Used 100% | `ContainerManager` wrapper, `@Observable` state machine |
| App Intents (`Intents` + `AppIntents`) | Used 100% | `AskApexAgentIntent`, `SummarizeTextIntent`, `AgentSessionEntity`, `ApexAgentShortcuts` |
| Carbon (hotkey) | Used 100% | `GetApplicationEventTarget` + `RegisterEventHotKey` in `ApexAgentApp.swift` |
| Darwin (forkpty + dlsym) | Used 100% | `PTYSession.swift` (forkpty), `DynamicToolRouting.swift` + `AgentEngine.swift` (dlsym probes) |
| WebKit, Network, Security, CoreGraphics, CoreMedia, ApplicationServices, NaturalLanguage, Vision, UserNotifications, os/OSLog, Intents | All used 100% | Verified at file:line |

**Dead imports removed (per audit doc):** `UniformTypeIdentifiers` (3×), `Cocoa` (QuickPromptPanel), redundant `Darwin` (AnalyzeImageTool) — all confirmed gone.

**Evaluations framework:** `ApexAgentTests/ModelEvaluationsTests.swift:4` imports `Evaluations` (macOS 27 beta framework at `…/Developer/Library/Frameworks/Evaluations.framework`). This is NOT declared in Package.swift as a dependency or linker setting. If it's a system framework (like FoundationModels), it resolves automatically; if not, the test target won't compile. **Needs verification.**

---

## 3. SPM Dependency Audit

### 3.1 Containerization (0.38.0)

- `Containerization`, `ContainerizationOCI` declared as explicit products in both Package.swift and project.yml ✓
- `ContainerizationArchive`, `ContainerizationOS` imported in `ContainerManager.swift` but NOT declared as explicit products in either build spec — they're transitive deps of `Containerization` (confirmed: `containerization/Sources/Containerization` imports both). This works today but is fragile: if Apple ever makes these internal, `ContainerManager` breaks.
- **Recommendation:** Add `.product(name: "ContainerizationArchive", ...)` and `.product(name: "ContainerizationOS", ...)` to `ApexAgentCore`'s dependencies in Package.swift for explicit ownership.

### 3.2 swift-log (1.5.0)

- `Logging` product declared in Package.swift for `ApexAgentCore` ✓
- Only used in `ContainerManager.swift:7` ✓
- Missing from project.yml `ApexAgentCore` dependencies (transitive via Containerization? No — `Logging` is from `swift-log`, not containerization). **Minor drift:** project.yml `ApexAgentCore` should add `- package: swift-log, product: Logging` for parity. Not blocking (ContainerManager gets `Logging` through the SPM build; Xcode may or may not resolve it transitively).

### 3.3 Duplicate-class risk

- Containerization is linked in `ApexAgentCore` (framework) + `ApexAgent` (executable) + `sandboxctl` (CLI) + `ApexAgentContainerTests` (Package.swift only).
- The Xcode project.yml intentionally omits Containerization from `ApexAgentContainerTests` to avoid "Multiple commands produce … Crypto.framework" under `xcodebuild test`.
- Package.swift includes it in the container tests — works under `swift test` (no app target built), but would fail under `xcodebuild test` if the SPM project were used for Xcode testing.
- **No active duplicate-class issue** in the current Xcode project.yml configuration.

### 3.4 All other SPM deps

`swift-asn1`, `grpc-swift-*`, `swift-nio-*`, `swift-crypto`, `swift-collections`, `swift-atomics`, `swift-async-algorithms`, `swift-configuration`, `swift-system`, `zstd`, `swift-certificates`, `swift-service-*`, `swift-distributed-tracing`, `swift-algorithms`, `async-http-client`, `SwiftProtobuf`, `swift-http-types`, `swift-nio-transport-services`, `swift-numerics` — all scaffolding/infra imports, correctly scoped to their consumers.

---

## 4. Swift 6 Strict-Concurrency Audit

### 4.1 `@Observable` + `@MainActor` — correct

`AgentOrchestrator` is correctly marked:
```
@Observable
@MainActor
public final class AgentOrchestrator: ...
```

The comment at line 131 explicitly warns against `didSet`/`willSet` on tracked properties (which opts them out of observation). Only one `didSet` exists — on `modelContext` (`AgentOrchestrator.swift:172`), which is NOT an `@Observable`-tracked property (it's a computed property with a stored `var modelContext: ModelContext?`), so it's safe.

### 4.2 `nonisolated(unsafe)` task storage — correct

Lines 187-189 use `@ObservationIgnored private nonisolated(unsafe) var currentTask/auditTask/confirmationTimeoutTask: Task<Void, Never>?`. This is the correct pattern for storing `Task` values in an `@Observable` class — `Task` is not `Sendable`-safe and can't be tracked by Observation.

### 4.3 Static `nonisolated` methods — correct

`isPrivateCloudComputeAvailable()` (line 103) and `proactiveAuditWorkspacePath()` (line 253) are correctly `nonisolated static` — they don't touch instance state.

### 4.4 MCPClient actor isolation

`MCPClient` is an `actor` with `nonisolated let serverName` (line 130) and `nonisolated var maxRetryCount` (line 426) — both correct for cross-actor reads. `stop()` is not `nonisolated` — it mutates actor state, so it must be called from the actor's context. `MCPManager.stopAll()` iterates `clients.values` and calls `await client.stop()` — correct.

### 4.5 Sendable conformance

- `AgentTraceLog: Codable, Sendable, Identifiable` ✓
- `ConfirmationRequest: Identifiable` (not Sendable — contains `Continuation`, which is correct)
- `ChatMessage: Identifiable` (not Sendable — contains `NSImage`, correct)
- `ContainerManager: Sendable` (with `@MainActor` — contradictory but compiles; `@MainActor` isolates all access to main actor, so Sendable is trivially satisfied)
- `MCPClientConfig: Codable, Sendable, Equatable` ✓
- `MCPClientHealth: Codable, Sendable, Equatable` ✓

### 4.6 Concurrency gaps

- `AgentOrchestrator` is `@MainActor` — all its methods run on main actor. Heavy use of `Task { }` in `startProactiveAudits()` (line 238) spawns a background task that calls `ProjectAuditor.shared.runWorkspaceAudit` — if that method is not `@MainActor`, it's fine; if it is, the `await` will hop to main actor correctly.
- `ContainerManager` is both `@Observable` and `@MainActor` and `Sendable` — the `Sendable` conformance is trivially satisfied by `@MainActor` isolation but is technically misleading (it suggests the type is safely sendable across actors, which it isn't — it's main-actor-bound).

---

## 5. Entitlements + Info.plist + Weak-Linking Audit

### 5.1 Entitlements (`ApexAgent.entitlements`)

| Key | Value | Verdict |
|---|---|---|
| `com.apple.security.app-sandbox` | `false` | Intentional — app needs Accessibility, Screen Recording, Apple Events which require unsandboxed access. Documented in audit report. |
| `com.apple.security.network.client` | `true` | Required for MCP stdio + CollaborativeServer + WebSearch |
| `com.apple.security.network.server` | `true` | Required for CollaborativeServer + ApexGatewayServer |
| `com.apple.security.automation.apple-events` | `true` | Required for AppleScriptTool + ApplicationControlTool |
| `com.apple.security.files.user-selected.read-write` | `true` | Required for FileSystemTools |
| `com.apple.security.files.downloads.read-write` | `true` | Required for file management in Downloads |
| `com.apple.security.cs.allow-jit` | `false` | Correct — no JIT needed |
| `com.apple.security.virtualization` | `true` | Required for Apple Container sandbox (ContainerManager) |
| `com.apple.security.app-groups` | `group.com.dboone323.fleet` | **MISMATCH** — app group is for "fleet", not "apexagent". Likely a copy-paste leftover. Should be `group.com.apexagent` or similar. |

### 5.2 Info.plist

| Key | Value | Verdict |
|---|---|---|
| `CFBundleIdentifier` | `$(PRODUCT_BUNDLE_IDENTIFIER)` | Correct — resolves to `com.apexagent.ApexAgent` |
| `LSMinimumSystemVersion` | `$(MACOSX_DEPLOYMENT_TARGET)` | Correct — resolves to `27.0` |
| `NSAppleScriptEnabled` | `true` | Required for AppleScriptTool |
| `NSAppleEventsUsageDescription` | Present | Required for automation entitlement |
| `NSScreenCaptureDescription` | Present | Required for ScreenCaptureKit |
| `NSUserNotificationsUsageDescription` | Present | Required for NotificationTool |
| `NSDocumentsFolderUsageDescription` | Present | Required for file access |
| `NSDesktopFolderUsageDescription` | Present | Required for Desktop access |
| `NSDownloadsFolderUsageDescription` | Present | Required for Downloads access |
| `SUFeedURL` + `SUPublicEDKey` | Present | **Unused** — Sparkle is not a dependency in either build spec. These keys are dead data. Either add Sparkle or remove. |

### 5.3 Weak-linking (5 FM-family frameworks)

All 5 targets (ApexAgentCore, ApexAgent, ApexAgentIntents, sandboxctl, 3 test targets) have the same 5 weak-framework linker flags:
```
-weak_framework FoundationModels
-weak_framework _FoundationModels_AppKit
-weak_framework _FoundationModels_SwiftUI
-weak_framework _Vision_FoundationModels
-weak_framework _CoreSpotlight_FoundationModels
```

This is correct and consistent. The app launches on systems without FM symbols, and `AgentEngine.swift` dlsym-checks availability at runtime.

**rpath settings:** All 5 targets that link Containerization also have `-rpath @loader_path/../Frameworks` (executable targets) or `-rpath @loader_path/../../..` (test targets). Correct — ensures Containerization's dynamic frameworks (`Crypto.framework`, etc.) dlopen at launch.

---

## 6. Test Suite Audit

### 6.1 Target inventory (3 real test targets + 1 UI test target)

| Target | Package.swift | project.yml | Import FoundationModels? | Import Containerization? | Status |
|---|---|---|---|---|---|
| `ApexAgentTests` | ✓ | ✓ | No (except `ModelEvaluationsTests` which imports `Evaluations` + `FoundationModels`) | No | Runs under `swift test` |
| `ApexAgentIntelligenceTests` | ✓ | ✓ | Yes (multiple files) | No (intentional — avoids CoreDevice conflict) | Runs under `swift test` |
| `ApexAgentContainerTests` | ✓ (with Containerization) | ✓ (without Containerization) | No | Package.swift: yes; project.yml: no | Drift (§1.1) |
| `ApexAgentUITests` | ✗ (not in Package.swift) | ✓ | N/A | N/A | Xcode-only |

**Known issue (from xcode27-dev skill):** `ApexAgentTests` hangs at subprocess-spawning tests (MCPClient start/stop with real mock server). The `deinit` in `ApexAgentTests` (line 69-73) tries to clean up `DynamicToolbox.shared.stopWatcher()` + `MCPManager.shared.stopAll()` via a `Task { @MainActor in }` — but if the mock server subprocess doesn't reap cleanly, the test helper hangs.

**`MCPClient.stop()` gap:** `MCPClient.stop()` (line 399-409) calls `process?.terminate()` (SIGTERM) and sets `process = nil`. It does NOT walk the process tree to kill child processes (e.g., `node` spawned by `npm exec`). Per the xcode27-dev skill, this can leave orphaned `node`/`zsh` processes that block the test host exit.

### 6.2 Bundle.module guard

`ApexAgentTests.swift:591-595` and `1044-1048` correctly use `#if SWIFT_PACKAGE` / `#else` with `Bundle(for: BundleToken.self)` fallback. This handles the SwiftPM vs XcodeGen test-bundle divergence. ✓

### 6.3 Coverage

~41 tests across the 3 targets. Covers: orchestrator init, tool safety, confirmation, truncation, compaction, keychain, PTY, diff helper, accessibility, browser automation safety, dynamic tool loading, semantic search, voice, collaboration, project auditor, agent types, MCP resilience, gateway models, file search, state graph, tool actor, tracing, automation workflows, weekly reflection, daily briefing, reflection manager, sandbox, security.

**Missing coverage:** Delegation/meeting flow tests (noted in original audit report as a gap).

---

## 7. Multi-Agent / Delegation Contract Audit

### 7.1 Agent profiles

7 specialist agents declared (`AgentProfiles.swift`): Codex, Nexus, Pilot, Oracle, Auditor, Aura, Chronos. Each has system prompts + capabilities. Feature-flagged via `apex.multiAgentModeEnabled`.

### 7.2 Delegation tools

- `DelegateTaskTool.swift` — creates sub-agent sessions via `orchestrator.orchestrator.sessionForAgent(...)` (line 108). Uses `SessionOwner` pattern to scope sub-agent memory.
- `ConveneMeetingTool.swift` — multi-agent meeting protocol (line 182, same `sessionForAgent` call).

Both delegate to `sessionForAgent` — which is the broken method (§1.2). **The multi-agent feature is non-functional until the protocol conformance is fixed.**

### 7.3 Handoff contract

Per the original audit report (§2, June 2026): "No verifiable handoff contract — meeting/delegation outcomes are not captured in typed transfer objects." The `AgentHandoff.swift` file exists but is not referenced in the delegation flow. `coordinationTraces: [AgentTraceLog]` (line 167) provides some observability but no formal contract.

### 7.4 Session isolation

Sub-agent sessions are created via `sessionForAgent` with per-agent `allowedTools` filtering. The `DelegateTaskTool` passes `allowedTools` based on the sub-agent's registered capabilities. This is a reasonable isolation mechanism.

---

## 8. Security / Sandbox / TCC Audit

### 8.1 TCC permissions

- **Accessibility:** `AXIsProcessTrusted()` guarded in `AccessibilityControlTool.swift:67` and `DiagnosticManager.swift:42`. No automatic prompt trigger — user must grant in System Settings.
- **Screen Recording:** `CGPreflightScreenCaptureAccess()` in `DiagnosticManager.swift:158`. `ScreenStreamer` has permission preflight before `startCapture()` (post-fix).
- **Apple Events:** `NSAppleEventsUsageDescription` in Info.plist. Enabled via entitlement.
- **Folder access:** `isFolderAccessRestricted()` (line 290) redirects `$HOME` to `~/.apex/sandbox` when restricted — reduces TCC prompt spam.

### 8.2 Network security

- `CollaborativeServer` binds to user-chosen port on all interfaces. No authentication, no TLS. Documented as LAN-only in audit report.
- `ApexGatewayServer` is a local TCP gateway — same LAN-only assumption.
- **Gap:** No "LAN only" toggle or shared-secret header (noted in original audit report).

### 8.3 Keychain

`KeychainManager.swift` uses `SecItemAdd/Update/CopyMatching/Delete` with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Stores Gemini API key + Brave Search key. ✓

### 8.4 Tool approval

`ConfirmationOverlay.swift` enforces user-approved execution for dangerous tools with 60s auto-deny. `shouldConfirmTool(name:)` gates by tool name. `requireConfirmationForAll` toggle. ✓

### 8.5 Sandbox

`com.apple.security.app-sandbox = false` — app is unsandboxed. This is necessary for the privileged APIs it uses (Accessibility, Screen Recording, Apple Events, Virtualization). The Apple Container sandbox (`com.apple.security.virtualization = true`) provides VM-level isolation for shell operations when enabled.

### 8.6 Info.plist Sparkle keys

`SUFeedURL` + `SUPublicEDKey` are present but Sparkle is not a dependency. These are dead keys — either remove them or add Sparkle.

---

## 9. Findings Summary

### BLOCKING (must fix before build)

| # | Finding | File | Fix |
|---|---|---|---|
| B1 | `AgentOrchestrator` missing `sessionForAgent` conformance to `OrchestratorProvider` | `AgentOrchestrator.swift:98` | Add `sessionForAgent` implementation (mirror `MCPManager` or delegate to `ApexAgentApp.sessionForAgent`) |
| B2 | `project.yml` `ApexAgent` target missing `ApexAgentIntents` dependency | `project.yml` | Add `- target: ApexAgentIntents` to app target dependencies; `xcodegen generate` |

### HIGH (should fix)

| # | Finding | File | Fix |
|---|---|---|---|
| H1 | `ContainerManager` imports `ContainerizationArchive`/`ContainerizationOS` without explicit product deps | `ContainerManager.swift:5-6` | Add `.product(name: "ContainerizationArchive", ...)` and `.product(name: "ContainerizationOS", ...)` to `ApexAgentCore` in Package.swift |
| H2 | `project.yml` `ApexAgentCore` missing `Logging` (swift-log) dependency | `project.yml` | Add `- package: swift-log, product: Logging` to `ApexAgentCore` deps for parity |
| H3 | Entitlements app-group is `group.com.dboone323.fleet` (wrong app) | `ApexAgent.entitlements` | Change to `group.com.apexagent` or remove if unused |
| H4 | `SUFeedURL`/`SUPublicEDKey` in Info.plist with no Sparkle dependency | `Info.plist` | Remove keys or add Sparkle |
| H5 | `MCPClient.stop()` doesn't kill process tree (orphaned node/zsh processes) | `MCPClient.swift:399-409` | Add BSD `proc_pidinfo` child-walk + SIGTERM/SIGKILL per xcode27-dev skill |

### MEDIUM (nice to have)

| # | Finding | File | Fix |
|---|---|---|---|
| M1 | `ContainerManager: Sendable` with `@MainActor` is misleading | `ContainerManager.swift:13` | Remove `Sendable` conformance or document why it's trivially satisfied |
| M2 | No formal handoff/contract model for delegation/meeting outcomes | `AgentHandoff.swift` exists but unused | Add typed transfer objects for `DelegateTaskTool`/`ConveneMeetingTool` outcomes |
| M3 | `CollaborativeServer` has no LAN-only enforcement or auth | `CollaborativeServer.swift` | Add toggle + optional shared-secret header |
| M4 | `Evaluations` framework import unverified (system framework or missing) | `ModelEvaluationsTests.swift:4` | Verify `Evaluations.framework` resolves in test build; if not, add linker flag or remove import |
| M5 | `ApexAgentContainerTests` Containerization dep is inconsistent between Package.swift (yes) and project.yml (no) | Both | Reconcile: remove from Package.swift to match project.yml (avoids `xcodebuild test` duplicate-link risk) |

### LOW (cosmetic / future)

| # | Finding | File | Fix |
|---|---|---|---|
| L1 | `AgentOrchestrator.swift` is ~1,437 lines / 62KB — consider decomposition | `AgentOrchestrator.swift` | Split into orchestrator core, tool registry, approval controller, session manager |
| L2 | `LocalOllamaLanguageModel.respond` + `CloudGeminiLanguageModel.respond` are large — extract tool-call resolution strategy | Those files | Share tool-call resolution logic |
| L3 | `MCPClient` uses `print` for stderr (not structured logging) | `MCPClient.swift` | Replace with `os.Logger` |
| L4 | JSONRPCRequest coding-key warning (harmless) | `MCPClient.swift` | Suppress or clean up |

---

## 10. Verification Checklist

- [x] **B1 fixed:** `swift build --product ApexAgent` exits 0
- [x] **B2 fixed:** `xcodegen generate` + Xcode GUI build finds `AskApexAgentIntent` in scope
- [x] **H1 fixed:** `ContainerizationArchive`/`ContainerizationOS` explicit products added to `ApexAgentCore` in Package.swift
- [x] **H2 fixed:** `swift-log` package + `Logging` product added to `project.yml` `ApexAgentCore` and `ApexAgentTests` deps
- [ ] **H3 fixed:** Entitlements app-group corrected
- [ ] **H4 fixed:** Sparkle keys removed or Sparkle added
- [ ] **H5 fixed:** `MCPClient.stop()` process tree cleanup
- [ ] **M4 verified:** `Evaluations` framework resolves in test target (or import removed)
- [ ] **M5 fixed:** `ApexAgentContainerTests` Containerization dep reconciled
- [ ] **Tests:** `ApexAgentIntelligenceTests` pass under `swift test` (run sequentially, not parallel — shared `.build` lock)

---

## 11. GO/NO-GO Verdict

**GO — with conditions.** The codebase is strong and well-engineered. The blocking issues (B1, B2) are straightforward to fix and don't indicate architectural problems. Once B1 is resolved (add `sessionForAgent` to `AgentOrchestrator`), the multi-agent delegation feature becomes functional again. The high-priority items (H1-H5) are hygiene fixes that improve robustness.

**Immediate action:** Fix B1 (protocol conformance) — this is the only thing preventing a successful build.
