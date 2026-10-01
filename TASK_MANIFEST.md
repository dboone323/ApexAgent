# ApexAgent — Master Manifest

> **Single source of truth** (consolidates root `TASK_MANIFEST.md` and `docs/TASK_MANIFEST.md`).
> **Last updated**: 2026-10-01 (Phase C Full-Potential Fixes + M1–M4 completion + 2026-09-28 P0–P3 audit remediation).
> **Scope**: `ApexAgentCore`, `ApexAgent`, `ApexAgentIntents`, `sandboxctl`, `apexflow`, `benchmark-repro`, `Modules/*`, `ApexAgentTests`, `ApexAgentContainerTests`, `ApexAgentIntelligenceTests`, `ApexAgentUITests`.

---

## 1. Verified Test Targets & Coverage Matrix

| Test Target | Files | Framework | `@Test` Functions | `XCTestCase` Classes | Coverage (`xctestplan`) | Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **`ApexAgentTests`** | 85 Swift files | Swift Testing + XCTest | 591 | 17 | Yes (`--enable-code-coverage`) | 🟢 **GREEN** |
| **`ApexAgentContainerTests`** | 1 Swift file | Swift Testing (`@Test`) | 7 | 0 | Yes (`--enable-code-coverage`) | 🟢 **GREEN** |
| **`ApexAgentIntelligenceTests`** | 10 Swift files | Swift Testing (`@Test`) | 71 | 0 | Yes (`--enable-code-coverage`) | 🟢 **GREEN** |
| **`ApexAgentUITests`** | 7 Swift files | XCTest (`XCTestCase`) | 0 | 6 | UI runner (`ApexAgent-UITests`) | ✅ **ACTIVE** |
| **Total** | **103 files** | **Mixed** | **669 `@Test`** | **23 `XCTestCase`** | **6 module targets covered** | 🟢 **VERIFIED** |

- **Code Coverage Targets** (`ApexAgent-UnitTests.xctestplan`): `ApexAgentCore`, `SharedKit`, `MCPKit`, `SharedModels`, `SharedLogging`, `ApexAgentIntents`.
- **Zero Skipped Tests**: `Makefile` runs `xcrun swift test --parallel --enable-code-coverage` with no `--skip` flags (`testBrowserAutomation` and `testRealToolsGrepAndGitMCP` both pass standalone and in parallel).

---

## 2. Build & Verification Gates

```bash
# SwiftPM build (zero unhandled-file warnings, StrictConcurrency enabled across all targets & test targets):
xcrun swift build

# Targeted R1–R4 & Phase C verification suites:
xcrun swift test --filter "PlaybookCollaborationTests|R1R2AdversarialStressTests|CognitiveMemoryTests"

# Entitlement-preserving Xcode build & test (ad-hoc signs "-" with ApexAgent.entitlements):
xcodebuild build -project ApexAgent.xcodeproj -scheme ApexAgent -destination "platform=macOS"
xcodebuild test -project ApexAgent.xcodeproj -scheme ApexAgent -testPlan ApexAgent-UnitTests -destination "platform=macOS"
```

---

## 3. Milestones & Phase Status (M1–M4 + Phase C)

| Milestone / Area | State | Summary of Verified Implementation |
| :--- | :--- | :--- |
| **M1 (R1): Creation & Configuration UI** | ✅ **Complete** | `CreateRoutineSheet` (bot picker, trigger picker, cron validation), `CreateSkillSheet` (strict `[a-z0-9_-]+` validation, dual SwiftData + `~/.apex/skills/` persistence), and `SkillsSection` wired in `SettingsView.swift`. Verified by `CreationSheetsTests` & `R1R2AdversarialStressTests`. |
| **M2 (R2): Autonomous Multi-Agent Playbooks** | ✅ **Complete** | `CollaborationPlaybook`, 3 built-in presets (`fullPRReviewLoop`, `issueToPatchPipeline`, `weeklyStandupAndRetrospective`), `PlaybookParticipantAssigner`, `PlaybookRunner` with live `BotSession` execution (`.live` vs `.simulated`), `onApprovalRequired` / `onDelegationEvent` hooks, 300s fail-safe auto-reject timeout, and interactive `PlaybookApprovalBannerView` in `BotChatView.swift` wired to `botManager.resolvePlaybookApproval(approved:notes:)`. Verified by `PlaybookCollaborationTests` & `R1R2AdversarialStressTests`. |
| **M3 (R3): Containerization & `sandboxctl`** | ✅ **Complete** | `ContainerIsolationLevel` (`.strict`, `.standard`, `.ephemeralOverlay`) wired into `ContainerManager` & `PTYSession`, APFS copy-on-write snapshots (`createSnapshot`, `restoreSnapshot`, `listSnapshots`, `deleteSnapshot`), `SecurityGovernanceProfile` wired into `ApprovalPolicy`, symlink traversal throwing `SecuritySandboxError.symlinkTraversal`, and full `sandboxctl` CLI subcommands (`run`, `status`, `snapshot`, `verify-security`). Verified by `ContainerIsolationSecurityTests` & `ApexAgentContainerTests`. |
| **M4 (R4): Dynamic Script & MCP Discovery UI** | ✅ **Complete** | `MCPServerDashboardView` (health, latency probing via `measureLatency()`, tool discovery, circuit reset), `DynamicScriptEditorView` (separate stdout/stderr capture, live execution, hot-reload), and auto-seeding of `xcodebuildmcp` and `xcode-native` (`xcrun mcpbridge`) in `MCPManager.loadConfigs()`. Verified by `MCPServerDashboardTests` & `MCPResilienceTests`. |
| **Phase C: Full-Potential AI, RAG, MCP & UI** | ✅ **Complete** | Default Ollama model unified to `gemma4:12b` in `SettingsView` and `ModelRegistry`; multimodal `NSImage` base64 encoding in `OllamaAgentEngine` (`"images"` payload); real semantic embeddings via Ollama `nomic-embed-text:latest` (`/api/embed`) with deterministic local hash fallback and cosine-similarity retrieval over `AgentMemoryEntry.embedding` in `CognitiveMemoryEngine`; `VoiceController.shared` mic button wired in `BotChatInputBar`; real `mdfind` Spotlight execution wired in `ApexAgentMCPServer` (`search_spotlight`). |
| **WS3: LaunchAgent Daemon** | ✅ **Complete** | Plist generator, process boot supervision, UI toggle, and test coverage (`BrowserAndDaemonTests`). |
| **WS4: Keychain Vault & Security** | ✅ **Complete** | Credentials stored exclusively in macOS Keychain (`KeychainManager`), plaintext `UserDefaults` mirror removed with one-shot migration (`KeychainMigrationTests`). |
| **WS5: Proactive Cross-Bot Handoffs** | ✅ **Complete** | `ProactiveScheduler` autonomous monitoring, status transitions, and peer approval gating (`PeerApprovalCoordinator`). |

---

## 4. Consolidated Historical Audit Backlog (All 5 Tiers Completed)

All 90+ items from the legacy `docs/TASK_MANIFEST.md` (June–September 2026 audits) have been remediated and verified:

- `[x]` **Tier 1 — Critical Crashes & Security (1.1–1.15)**: Replaced `try!` in `PTYSession` fallback; added `defer` cleanup for `isGenerating`; made proactive audit loop cancellable; guarded confirmation auto-deny task with weak capture & ID check; removed force-unwraps in `MessageBubble` and `MCPClient`; enforced `[a-z0-9_-]+` skill name allowlist and atomic writes in `CreateSkillTool`; removed hardcoded developer workspace paths in `WorkspaceProactiveAuditor`; fixed `ToolEventLogger` default confirmation to fail-closed (`false`); checked `Darwin.write()` return values in `PTYSession`.
- `[x]` **Tier 2 — High-Priority Performance & Concurrency (2.1–2.21)**: Cached terminal ANSI segments and regex instances; reused `CIContext` in `ScreenStreamer`; debounced Keychain saves in `SettingsView`; moved workspace scanning off the main actor; unified `executeToolByName` dispatch; eliminated `DispatchQueue.main.sync` deadlocks; enforced `@MainActor` isolation in `VoiceController` and `ScreenStreamer`; moved Gemini API key to `x-goog-api-key` header; raised tool output and per-turn tool call limits.
- `[x]` **Tier 3 — Test Coverage & Architecture (3.1–3.32)**: Added real functional tests across all previously uncovered tools (`ConfirmCompletionTool`, `ProjectManagementTools`, `CodeReviewPersistenceTools`, `WorkspaceProactiveAuditor`, `WritingToolsSupport`, `ContextWindowManager`, `ToolResultCache`, `DynamicToolRoutingTests`, `ToolSchemasTests`); added cycle detection and concurrency safety to `StateGraph`; added symlink & path traversal defenses in `FileSystemTools` and `SecurityAuditor`.
- `[x]` **Tier 4 & 5 — UI Polish, Accessibility & Linting (4.1–4.14)**: Added accessibility identifiers and labels across all primary views (`ChatView`, `BotChatView`, `ContentView`, `SettingsView`, `DiagnosticsView`, `PlanDashboardView`, `ToolActivityView`, `ConfirmationOverlay`); persisted workspace layout toggles via `@AppStorage`; enforced Swift 6.4 `StrictConcurrency` across all package and test targets.
