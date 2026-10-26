# APEXAGENT_PLAINTEXT_TOKEN_GATE_FIX_2026-10-26

## What changed

### 1. TestLog.swift + PlaintextTokenFixTests.swift into ApexAgentTests target
- Regenerated project via `xcodegen generate` (project is XcodeGen-driven from repo-root `project.yml`; ApexAgentTests sources = whole `ApexAgentTests` directory).
- Verified in `ApexAgent.xcodeproj/project.pbxproj`:
  - `TestLog.swift`: PBXFileReference (`D180FC2631A2D4BCE7253192`) and `TestLog.swift in Sources` build file (`4C5E5FF6A301ECE960E5E98E`) present in the ApexAgentTests Sources build phase.
  - `PlaintextTokenFixTests.swift`: PBXFileReference (`469440C576A041019E546D86`) and `PlaintextTokenFixTests.swift in Sources` build file (`CA87EA603464134C1F44E210`) present in the ApexAgentTests Sources build phase.
- Source counts: 236 `.swift` files under `ApexAgentTests/` on disk; regeneration picked up both previously-missing files without dropping others.

### 2. GitHubTool `auth token` denial test
- Added `testGitHubToolAuthTokenSubActionIsDenied()` (plus a `setUp` for Keychain/UserDefaults isolation) to `ApexAgentTests/PlaintextTokenFixTests.swift`.
- Asserts calling `GitHubTool` with `action: "auth"`, `subAction: "token"` returns a denial containing "disabled to prevent token leakage", and does not contain `ghp_` or "gh auth token".

### 3. Plaintext-token fix changes kept
- All prior uncommitted migration/leak-removal changes left untouched.

## Gate results

- Full unit plan (`ApexAgent-UnitTests.xctestplan`): **1731 passed / 0 failed / 14 skipped / 0 expected failures** (1745 run). Result: Passed.
- Lint solo (`SwiftSyntaxLintGateTests`): **3/3 passed**. Changed-file lint (`lint-changed-swift.sh`): 23/23 passed.
- Reconciliation vs baseline (1741 run / 1725 passed / 0 failed / 14 skipped / 2 expected failures; lint 3/3):
  - +4 tests passed (3 migration + 1 denial) → 1729.
  - The 2 previously expected-failure on-device/PCC latency tests now pass → 1731.
  - Total run +4 (1745) consistent with the 4 added tests.
  - No failures; no regressions.

## Stop before commit

- No commit or push performed. Changes remain uncommitted. VM/seed/600s/Battery-7 code untouched; no token-handling code changed.