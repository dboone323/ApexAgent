# Project: ApexAgent Next Major Feature Releases (R1, R2, R3, R4)

## Architecture
ApexAgent is a native macOS multi-agent AI assistant built with Swift 6.4 strict concurrency and SwiftUI.
The 4 new major feature areas expand the application into:
1. **Creation & Configuration UI**: Seamless interactive sheet-based creation and configuration of Routines (`CreateRoutineSheet`) and Skills (`CreateSkillSheet`) with SwiftData and filesystem persistence.
2. **Autonomous Multi-Agent Playbooks**: Structured multi-stage collaboration pipelines with built-in presets (PR Review Loop, Issue-to-Patch, Standup & Retro), automated participant assignment, mixed sequential/parallel turn dispatching, and live delegation/approval tracking.
3. **Containerization & Sandboxctl Isolation**: Formalized execution isolation levels (`strict`, `standard`, `ephemeralOverlay`), disk snapshots and rollback capabilities, security governance profiles, and hardened host boundary enforcement.
4. **Dynamic Script & MCP Discovery UI**: Live MCP Server Dashboard (health, latency, stdio/SSE channels, tool discovery) and Dynamic Script Editor in Settings for custom shell tools.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                             SwiftUI Settings View                           │
│  ┌──────────────────────┐  ┌──────────────────────┐  ┌───────────────────┐  │
│  │ RoutinesSection      │  │ SkillsSection        │  │ MCP & Scripts UI  │  │
│  │ (CreateRoutineSheet) │  │ (CreateSkillSheet)   │  │ (Dashboard/Editor)│  │
│  └──────────┬───────────┘  └──────────┬───────────┘  └─────────┬─────────┘  │
└─────────────┼─────────────────────────┼────────────────────────┼────────────┘
              │                         │                        │
              ▼                         ▼                        ▼
┌─────────────────────────┐  ┌──────────────────────┐  ┌──────────────────────┐
│ RoutineManager          │  │ SkillManager / Disk  │  │ DynamicToolbox /     │
│ & SwiftData (Routine)   │  │ & SwiftData (Skill)  │  │ MCPClient Dashboard  │
└─────────────────────────┘  └──────────────────────┘  └──────────────────────┘
              │                         │                        │
┌─────────────┴─────────────────────────┴────────────────────────┴────────────┐
│                       Core Multi-Agent Orchestration                        │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │ CollaborationPlaybook & PlaybookRunner (Presets, Assigner, Runner)    │  │
│  │  - Full PR Review Loop                                                │  │
│  │  - Issue-to-Patch Pipeline                                            │  │
│  │  - Weekly Standup & Retrospective                                     │  │
│  │  Sequential & Parallel Turn Dispatching, Approval Cards, Delegations  │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │ BotManager (5-bot roster: Apex, Chief of Staff, Architect, Researcher,│  │
│  │             Automator), BotSession, PeerApprovalCoordinator           │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────┬───────────────────────────────────────┘
                                      │
┌─────────────────────────────────────▼───────────────────────────────────────┐
│               Security Governance & Native Apple Virtualization             │
│  ┌─────────────────────────────────┐  ┌──────────────────────────────────┐  │
│  │ SecurityGovernanceProfile       │  │ ContainerManager & sandboxctl    │  │
│  │ ApprovalPolicy (Host vs Cont)   │  │ Isolation Levels (strict/std)    │  │
│  │ Host Path Boundary & Traversal  │  │ Checkpoints & APFS Snapshots     │  │
│  └─────────────────────────────────┘  └──────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Feature Inventory
Every feature from the Survey phase is mapped to an assigned milestone:

| # | Feature | Description | Milestone | Source |
|---|---------|-------------|-----------|--------|
| 1 | `CreateRoutineSheet` UI & Logic | Interactive sheet in `RoutinesSection.swift` for creating routines with trigger picker (manual, interval, cron, error, success, message, webhook), target bot picker, interval stepper, and cron validation. | M1 | R1 Survey |
| 2 | `CreateSkillSheet` UI & Logic | Interactive sheet in `SkillsSection.swift` for authoring custom skills, selecting allowed tools, parameter schema, script editing, and dual persistence (SwiftData + `~/.apex/skills/`). | M1 | R1 Survey |
| 3 | `SkillsSection` Settings Integration | Expose `SkillsSection` in `SettingsView.swift` so users can access and manage custom skills alongside routines and toolbox. | M1 | R1 Survey |
| 4 | `CollaborationPlaybook` Data Models | Define `PlaybookPresetKind`, `PlaybookDispatchMode` (`.sequential`, `.parallel`), `PlaybookRoleRequirement`, `PlaybookStageDefinition`, `PlaybookExecutionStatus`, `PlaybookStageResult`, and `PlaybookDelegationEvent`. | M2 | R2 Survey |
| 5 | Built-in Playbook Presets | Production-ready presets: Full PR Review Loop, Issue-to-Patch Pipeline, Weekly Standup & Retrospective with structured stage prompts and schemas. | M2 | R2 Survey |
| 6 | `PlaybookParticipantAssigner` | Heuristic role-to-bot mapping across the standard 5-bot roster (Chief of Staff, Code Architect, Researcher, Automator, Apex) with fallback logic. | M2 | R2 Survey |
| 7 | `PlaybookRunner` Execution Engine | Asynchronous stage runner supporting sequential and parallel (`withTaskGroup`) turn dispatching, stage approval cards (`PlaybookApprovalCard`), delegation tracking, and `TraceBus` event streaming. | M2 | R2 Survey |
| 8 | `ContainerIsolationLevel` Formalization | Define `.strict` (no network, read-only mounts, ephemeral rootfs), `.standard` (network, read-write workspace), and `.ephemeralOverlay` in `ContainerManager` and `PTYSession`. | M3 | R3 Survey |
| 9 | Container Checkpoints & Snapshots | Implement container checkpointing and disk snapshot rollback APIs (`createSnapshot`, `restoreSnapshot`, `listSnapshots`, `deleteSnapshot`) using APFS copy-on-write cloning. | M3 | R3 Survey |
| 10 | `SecurityGovernanceProfile` | Formalize host vs container governance profiles and wire into `ApprovalPolicy` and `AgentOrchestrator`. | M3 | R3 Survey |
| 11 | Host Boundary & Escape Prevention | Hardened host filesystem restrictions for Desktop, Documents, Downloads, Music, root `/`, system roots (`/System`, `/Library`, `/etc`), and symlink traversal detection (`SecuritySandboxError.symlinkTraversal`). | M3 | R3 Survey |
| 12 | `sandboxctl` CLI Subcommands | Upgrade `Tools/sandboxctl/main.swift` with CLI subcommands: `run`, `status`, `snapshot`, `verify-security`, and `--isolation` flags. | M3 | R3 Survey |
| 13 | `MCPServerDashboardView` | Live dashboard in Settings showing connection status (`running`, `stopped`, `circuit_open`), roundtrip latency monitoring (`measureLatency()`), stdio/SSE channels, registered tools explorer, ping and circuit reset controls. | M4 | R4 Survey |
| 14 | `DynamicScriptEditorView` | Interactive view in Settings for inspecting, editing, test running with live stdout/stderr console, and hot-reloading `~/.apex/skills/` scripts into `DynamicToolbox`. | M4 | R4 Survey |
| 15 | Final E2E Integration & Verification | Execute full test matrix across ApexAgentTests and ApexAgentContainerTests, validating 100% clean builds, zero warnings, and passing all Tiers 1-5. | M5 | R1-R4 Acceptance |

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| M1 | Settings & Creation UI Sheets | Implement `CreateRoutineSheet`, `CreateSkillSheet`, dual persistence, and `SettingsView` wiring. | none | PLANNED |
| M2 | Autonomous Playbooks & Multi-Agent Engine | Implement `CollaborationPlaybook`, 3 Presets, `PlaybookParticipantAssigner`, `PlaybookRunner`, sequential/parallel dispatch, approval cards, and delegation tracking. | none | PLANNED |
| M3 | Containerization & Sandboxctl Enhancements | Implement `ContainerIsolationLevel`, Snapshot/Checkpoint APIs, `SecurityGovernanceProfile`, Host boundary & symlink traversal guards, and `sandboxctl` CLI tool. | none | PLANNED |
| M4 | Dynamic Script & MCP Server Discovery UI | Implement `MCPServerDashboardView` with latency probing and tool inspection, and `DynamicScriptEditorView` with test runner console. | M1 | PLANNED |
| M5 | Final E2E Integration & Adversarial Verification | Execute full test suite across all 4 feature areas (Tiers 1-4 functional tests + Tier 5 adversarial verification). | M1, M2, M3, M4 | PLANNED |

## Interface Contracts

### M1 Interface Contracts
- `CreateRoutineSheet`:
  - Input: `targetBot: BotProfile?`, trigger configuration, prompt.
  - Output: Inserts `Routine` into SwiftData `modelContext` and triggers `RoutineManager.shared.loadRoutines()`.
- `CreateSkillSheet`:
  - Input: name, description, parameters schema, allowed tools, shell script content.
  - Output: Writes script to `~/.apex/skills/<name>.sh` (`chmod 0755`), writes metadata `~/.apex/skills/<name>.json`, inserts `Skill` into SwiftData, calls `DynamicToolbox.shared.loadTools()` and `SkillManager.shared.syncFromDisk()`.

### M2 Interface Contracts
- `CollaborationPlaybook`:
  - `PlaybookPresetKind`: `.fullPRReviewLoop`, `.issueToPatchPipeline`, `.weeklyStandupAndRetrospective`.
  - `PlaybookStageDefinition`: `id: String`, `title: String`, `role: PlaybookRoleRequirement`, `dispatchMode: PlaybookDispatchMode`, `promptTemplate: String`, `requiresApproval: Bool`.
  - `PlaybookParticipantAssigner.assignParticipants(for:preset:availableBots:) -> [PlaybookRoleRequirement: BotProfile]`.
  - `PlaybookRunner.execute(playbook:preset:context:onApprovalRequired:onDelegationEvent:) async throws -> PlaybookExecutionReport`.

### M3 Interface Contracts
- `ContainerIsolationLevel`: `enum { case strict, standard, ephemeralOverlay }`.
- `ContainerManager`:
  - `startContainer(workspace:isolationLevel:) async throws`.
  - `createSnapshot(name:) async throws -> ContainerSnapshotRecord`.
  - `restoreSnapshot(id:) async throws`.
  - `listSnapshots() async -> [ContainerSnapshotRecord]`.
- `SecurityGovernanceProfile`:
  - `profile: GovernanceProfileKind` (`.hostStrict`, `.hostDeveloper`, `.containerStandard`, `.containerStrict`).
  - `validateFilesystemAccess(path:isContainerSandboxed:) throws`.

### M4 Interface Contracts
- `MCPClient`:
  - `measureLatency() async -> Double?` (ping latency in ms).
  - `listRegisteredTools() -> [MCPToolDefinition]`.
- `DynamicScriptEditorView`:
  - `testRun(scriptPath:arguments:environment:) async -> ScriptExecutionResult(exitCode: Int, stdout: String, stderr: String, duration: TimeInterval)`.

## Code Layout
- `ApexAgent/UI/RoutinesSection.swift` (CreateRoutineSheet, RoutineRow)
- `ApexAgent/UI/SkillsSection.swift` (CreateSkillSheet, SkillRow)
- `ApexAgent/UI/SettingsView.swift` (Settings tab wiring)
- `ApexAgent/UI/DynamicToolboxManagerSection.swift` (MCPServerDashboardView, DynamicScriptEditorView)
- `ApexAgent/Models/CollaborationPlaybook.swift` (Playbook models, Presets, Assigner)
- `ApexAgent/Models/PlaybookRunner.swift` (Sequential & Parallel runner, Approval cards, Delegations)
- `ApexAgent/Models/ContainerManager.swift` (Isolation levels, Snapshots, Checkpoints)
- `ApexAgent/Security/SecurityGovernanceProfile.swift` (Governance profiles)
- `ApexAgent/Security/ApprovalPolicy.swift` (Approval integration)
- `ApexAgent/Security/AgentOrchestrator.swift` (Path traversal & host boundaries)
- `Tools/sandboxctl/main.swift` (sandboxctl CLI harness)
- `ApexAgentTests/` (Unit, integration, and E2E tests for R1-R4)
- `ApexAgentContainerTests/` (Container and sandbox isolation tests)
