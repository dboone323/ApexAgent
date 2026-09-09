# E2E Test Infra: ApexAgent Next Major Features (R1, R2, R3, R4)

## Test Philosophy
- Real functional execution without mocks, stubs, fake engines, or dummy assertions.
- Requirement-driven verification testing all inventoried features across Tiers 1-4.
- Swift 6.4 strict concurrency compliance, zero warnings.

## Feature Inventory & Test Coverage Goals
| # | Feature | Requirement Source | Tier 1 (Functional) | Tier 2 (Boundaries) | Tier 3 (Cross-Feature) | Tier 4 (Workloads) |
|---|---------|-------------------|:-------------------:|:-------------------:|:----------------------:|:------------------:|
| F1 | `CreateRoutineSheet` | R1 UI Sheets | 5 | 5 | ✓ | ✓ |
| F2 | `CreateSkillSheet` | R1 UI Sheets | 5 | 5 | ✓ | ✓ |
| F3 | `SkillsSection` Settings | R1 UI Sheets | 5 | 5 | ✓ | ✓ |
| F4-F5 | Playbook Presets & Models | R2 Playbooks | 5 | 5 | ✓ | ✓ |
| F6-F7 | Participant Assigner & Runner | R2 Playbooks | 5 | 5 | ✓ | ✓ |
| F8-F9 | Container Isolation & Snapshots | R3 Container | 5 | 5 | ✓ | ✓ |
| F10-F12 | Governance & Host Boundary / sandboxctl | R3 Container | 5 | 5 | ✓ | ✓ |
| F13 | MCP Server Dashboard & Latency | R4 MCP UI | 5 | 5 | ✓ | ✓ |
| F14 | Dynamic Script Editor & Test Runner | R4 Scripts UI | 5 | 5 | ✓ | ✓ |

## Test Suites Architecture
- `ApexAgentTests/CreationSheetsTests.swift`: Tier 1-3 tests for `CreateRoutineSheet`, `CreateSkillSheet`, trigger validation, cron syntax check, SwiftData persistence, and filesystem creation.
- `ApexAgentTests/PlaybookCollaborationTests.swift`: Tier 1-4 tests for all 3 Presets (PR Review, Issue-to-Patch, Standup), participant assignment, sequential & parallel execution, approval card pausing/resumption, and delegation tracking.
- `ApexAgentTests/ContainerIsolationSecurityTests.swift` & `ApexAgentContainerTests/`: Tier 1-4 tests for isolation levels (`strict`/`standard`/`ephemeralOverlay`), disk snapshots and rollbacks, host path guards, symlink traversal prevention, and `sandboxctl` execution.
- `ApexAgentTests/MCPServerDashboardTests.swift`: Tier 1-3 tests for MCP server health, latency measurement, tool catalog discovery, and Dynamic Script Editor test execution.
- `ApexAgentTests/E2EFeatureMatrixTests.swift`: Tier 4 Real-World Application Scenarios exercising end-to-end user workflows.

## Test Runner Invocation
- `swift test` (or `xcodebuild test -scheme ApexAgent -destination "platform=macOS"`)
