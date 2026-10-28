# ApexAgent Comprehensive Architecture & Hardening Review Report
**Date:** October 27, 2026  
**Auditor:** Autonomous Staff Swift Systems Architect  
**Workspace:** `/Users/danielstevens/Developer/ApexAgent`  
**Target Platform:** macOS 27 (Apple Silicon, 16GB Unified Memory), Xcode 27, Swift 6.4  
**Audit Scope:** Swift 6 Strict Concurrency, Subprocess & Memory Safety, Credential Defense, Test Gate Coverage, and Context Compaction Ceilings.

---

## Executive Summary

A comprehensive architectural and systems audit of `ApexAgent` was conducted on branch `feat/spaces-vm`. ApexAgent represents a high-performance, native macOS multi-agent system orchestrating on-device Apple Foundation Models (AFM), local Ollama/MLX backends, Tart virtualization micro-VMs, and sandboxed developer tooling.

The codebase demonstrates rigorous adherence to modern Apple development principles:
- `@MainActor` and actor boundaries are cleanly delineated across view models and coordinators.
- Credential isolation uses `KeychainManager` for critical secrets (GitHub tokens, Gemini keys, LAN collaboration tokens) with strict deprecation/migration of `UserDefaults` plaintext stores.
- Static gate coverage (`RepoHygieneAuditor`, `SARIFReportExporter`, `CenturionMilestoneTests`, `DoctorExpansionAuditor`) actively validates 70/70 workflows and 12/12 doctor subsystems without mocks.

However, several critical systems-level hazards exist in native subprocess management, pipe I/O synchronization, external command construction, and streaming task cancellation that could lead to deadlocks, command injection, or thread starvation in constrained environments.

---

## Summary of Findings by Severity

| ID | Severity | Category | File & Location | Description |
|---|---|---|---|---|
| **P1-01** | **P1 (Critical)** | Command Injection | `ApexAgent/Tools/FileSearchTool.swift:45` | Unsanitized `arguments.filePattern` interpolated directly into shell string executed via `backend.runShell`. |
| **P1-02** | **P1 (Critical)** | Subprocess Deadlock | `ApexAgent/Tools/GitOperationsTool.swift:234-237` | Synchronous pipe deadlock: `process.waitUntilExit()` called before reading `outPipe.readDataToEndOfFile()`. |
| **P1-03** | **P1 (Critical)** | Subprocess Deadlock | `ApexAgent/Tools/GitHubTool.swift:106-109` | Synchronous pipe deadlock: `process.waitUntilExit()` called before reading `pipe.readDataToEndOfFile()`. |
| **P1-04** | **P1 (Critical)** | Subprocess Deadlock | `ApexAgent/Tools/SimctlTool.swift:67-69` | Synchronous pipe deadlock on `simctl list devices -j`: blocks thread if JSON output exceeds 64KB pipe buffer; no watchdog timer. |
| **P1-05** | **P1 (Critical)** | CLI Bug / Invocations | `ApexAgent/Tools/GitHubTool.swift:125-308` | Path duplication bug: `var cmd = [ghPath, ...]` passed to `runCommand(ghPath, cmd)` prefixes executable path twice, causing `gh` to fail with `unknown command "/opt/homebrew/bin/gh"`. |
| **P2-01** | **P2 (High)** | Concurrency / Thread Hang | `ApexAgent/Tools/AppleScriptTool.swift:37-58` | `NSAppleScript.executeAndReturnError` runs on `DispatchQueue.global` inside `withCheckedContinuation` without timeout, leaking thread pool slots on modal dialogs. |
| **P2-02** | **P2 (High)** | Concurrency / Cancellation | `ApexAgent/Models/OllamaAgentEngine.swift:202-218` | Missing `Task.checkCancellation()` check inside SSE lines consumption loop in `executeTurn`. |
| **P2-03** | **P2 (High)** | Process Hygiene | `ApexAgent/Tools/ShellTool.swift:189-195` | `process.terminate()` on timeout only terminates `/bin/zsh`, potentially leaving spawned build subprocess trees orphaned. |
| **P2-04** | **P2 (High)** | Concurrency / Timeout | `ApexAgent/Models/AgentEngine.swift:103-113` | Multimodal fallback in `NativeAppleEngine` lacks task timeout wrapper, unlike text generation turns (which enforce 90s/180s timeout). |
| **P3-01** | **P3 (Medium)** | Memory / Heuristic Drift | `ApexAgent/Models/ContextCompactor.swift:69-71` | Token approximation uses static character division (`text.count / 4`), underestimating multibyte code tokens during compaction. |
| **P3-02** | **P3 (Medium)** | Compiler Diagnostics | `ApexAgent/Models/SpaceModels.swift:95, 399` | Redundant `@unchecked Sendable` on `@Model` classes triggers Swift 6 macro expansion warnings. |

---

## Detailed Audit & Risk Analysis

### 1. Swift 6 Concurrency & Actor Isolation Audit

#### Engine Implementations
- **`NativeAppleEngine` (`ApexAgent/Models/AgentEngine.swift:24-232`)**:
  - Conforms to `@MainActor protocol AgentEngine`.
  - Turns are wrapped with `withThrowingTaskGroup` enforcing a 90s (subsequent) or 180s (initial) timeout against beta foundation model hangs.
  - *Risk Identified (P2-04)*: Multimodal path (`session.respond(to: multimodalPrompt, options: options)`) at line 103 lacks the throwing task group timeout present in text generation. If image feature extraction hangs on macOS 27 beta, it stalls the turn.
- **`OllamaAgentEngine` (`ApexAgent/Models/OllamaAgentEngine.swift:12-286`)**:
  - Model unload and multi-turn loops run asynchronously with `@MainActor` thread dispatching for `onUpdate` callbacks.
  - *Risk Identified (P2-02)*: Inside `executeTurn`, `for try await line in stream.lines` processes streamed chunks without querying `Task.isCancelled`. If a user stops generation in the UI, the network bytes continue draining and updating internal state.
- **`FMCLIAgentEngine` (`ApexAgent/Models/AgentEngine.swift:237-343`)**:
  - Implements `withTaskCancellationHandler` correctly terminating the spawned `/usr/bin/fm` subprocess upon cancellation.
- **`MLXAgentEngine` (`ApexAgent/Models/MLXAgentEngine.swift:15-164`)**:
  - Fully checks cancellation inside its stream reader: `try Task.checkCancellation()` at line 94. Actor boundaries between background network SSE parsing and `@MainActor orchestrator.executeToolByName` are cleanly respected.

#### TaskGroup Parallel Loops
- **`PlaybookRunner.swift:399-430`**:
  - Parallel turns use `withThrowingTaskGroup(of: (Int, PlaybookBotResult).self)`.
  - Ordered indexing preserves pipeline determinism.
  - `runLiveTurn` (line 774) wraps individual bot sessions in a race between session execution and a 60s hard timeout with `group.cancelAll()`.

---

### 2. Subprocess & Input Sanitization Review

#### Subprocess Deadlock Hazards (P1-02, P1-03, P1-04)
On Darwin/macOS, anonymous pipes (`Pipe()`) have a fixed buffer capacity of 64KB. If a child process produces more than 64KB of standard output or standard error, writing to the pipe blocks until data is consumed by the parent process.
- **`GitOperationsTool.swift:234-237`**:
  ```swift
  try process.run()
  process.waitUntilExit() // BLOCKS here if stdout > 64KB!
  let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
  ```
  If `git diff` or `git log` produces >64KB, `git` blocks on `write()` while `ApexAgent` blocks on `wait4()`. The app hangs permanently.
- **`GitHubTool.swift:106-109`**:
  Same pattern in `runCommand`: `process.waitUntilExit()` precedes `readDataToEndOfFile()`.
- **`SimctlTool.swift:67-69`**:
  In `SimctlTool.swift:boot`, `simctl list devices -j` is executed synchronously. In developer setups with iOS, watchOS, visionOS runtimes, JSON output frequently exceeds 64KB, triggering immediate freeze on `boot`.

#### Command Injection Hazard (P1-01)
- **`FileSearchTool.swift:45`**:
  When running against a guest VM workspace (`backend.runShell`):
  ```swift
  var cmd = "grep -rnI --exclude-dir=.git --exclude-dir=.build --exclude-dir=.swiftpm"
  if let pattern = arguments.filePattern { cmd += " --include=\(pattern)" }
  cmd += " -e '\(arguments.query.replacingOccurrences(of: "'", with: "'\\''"))' '\(guestDir.replacingOccurrences(of: "'", with: "'\\''"))'"
  ```
  While `arguments.query` and `guestDir` escape single quotes, `arguments.filePattern` is interpolated raw into `cmd`. An attacker or unconstrained LLM supplying `filePattern: "*.swift; rm -rf /"` achieves arbitrary command execution in the guest shell.

#### CLI Command Construction Defect (P1-05)
- **`GitHubTool.swift:125-308`**:
  All subcommand functions construct argument arrays starting with `ghPath`:
  ```swift
  var cmd = [ghPath, "issue", "list"]
  return try await runCommand(ghPath, cmd)
  ```
  Inside `runCommand`:
  ```swift
  process.executableURL = URL(fileURLWithPath: path)
  process.arguments = args // args already contains path as first element!
  ```
  This passes `argv[0] = "/usr/local/bin/gh"`, `argv[1] = "/usr/local/bin/gh"`, `argv[2] = "issue"`. `gh` rejects this with `unknown command "/usr/local/bin/gh" for "gh"`.

#### AppleScript Execution Boundaries (P2-01)
- **`AppleScriptTool.swift:37-58`**:
  Uses `withCheckedContinuation` to execute `NSAppleScript(source: ...).executeAndReturnError(&error)` on `DispatchQueue.global()`. If a script triggers a modal alert (`display dialog`), blocks on network AppleEvents, or targets a hung application, the thread and continuation are leaked forever with zero timeout recovery.

---

### 3. Keychain & Credential Defense

1. **Storage Matrix**:
   - `geminiAPIKey`: Stored in macOS Keychain (`"geminiAPIKey"`), fallback to `GEMINI_API_KEY` environment variable.
   - `githubToken`: Stored in macOS Keychain (`"githubToken"`), fallback to `GITHUB_COPILOT_TOKEN` / `GITHUB_TOKEN` environment variables.
   - `collabToken`: Stored in macOS Keychain (`"collabToken"`).
   - `linearAPIToken` / `discordBotToken`: Stored in macOS Keychain.
2. **Hygiene Verification**:
   - `RepoHygieneAuditorTests` scans all source trees for high-entropy tokens (`ghp_`, `sk-`, `AIza`, AWS keys, PEM private blocks). Scans report 0 findings across the codebase.
   - Previous migration passes purged legacy `UserDefaults` keys (`apex.model.copilotToken`, `apex.collabToken`, `apex.geminiKey`) upon read.

---

### 4. Test Suite Health & Gate Coverage

#### Target Coverage
1. **`ApexAgentTests` (236 test files)**:
   - Covers core models, tools, routers, security auditors, and git hygiene.
   - `ApexCLIRouterTests` (3/3 passed), `SpaceLandingServiceTests` (6/6 passed), `VMWorkspaceManagerTests` (10/10 passed), `ChatAutocompleteTests` (9/9 passed).
   - `RepoHygieneAuditorTests` (5/5 passed), `CenturionMilestoneTests` (3/3 passed), `CLISmokeTestHarnessTests` (3/3 passed).
2. **`ApexAgentContainerTests`**:
   - 7/7 passed (Container isolation, snapshots, host diagnostics).
3. **`ApexAgentIntelligenceTests`**:
   - 71 tests in 11 suites passed.
   - Environment-specific handling: `DelegateTaskTool` and `ConveneMeetingTool` gracefully record `.withKnownIssue` when Apple Foundation Model on-device latency exceeds 40s on beta macOS releases without failing CI.

---

### 5. Unified Memory & Context Window Ceilings (16GB Environment)

#### Memory Budget Analysis on 16GB macOS 27:
- **Base OS + WindowServer + UI**: ~4.0 GB – 4.5 GB
- **ApexAgent Process + WebKit/PTY Instances**: ~600 MB – 1.0 GB
- **On-Device 3B AFM / System Language Model**: ~2.5 GB – 3.2 GB
- **Local Ollama / MLX Model (7B/8B Q4)**: ~4.5 GB – 5.5 GB
- **Total Committed**: ~11.6 GB – 14.2 GB
- **Safe Working Headroom**: ~1.8 GB – 4.4 GB

#### Context Window Compaction & Sliding Windows:
- **`BotSession.pruneExcessiveToolOutputs(maxOutputChars: 3000)`**:
  Truncates oversized command outputs (such as massive compiler errors or diffs) to 3,000 characters (1,500 char head + 1,500 char tail).
- **`AgentSessionCoordinator.rehydrationWindowSize = 10`**:
  Limits session memory rehydration to the last 10 messages with 3,000-character caps, preventing quadratic memory bloat across multi-turn chats.
- **`ContextCompactor.compact`**:
  Converts turns prior to `recentTurnsToPreserve` into compact single-line bullet summaries.
- *Recommendation (P3-01)*: The static heuristic `text.count / 4` under-counts CJK and formatted code tokens. In high-density code chats, context compaction could trigger late. A multiplier of 0.35 * characters for code-heavy strings is recommended.

---

## Actionable Recommendations & Hardening Plan

### Recommendation 1: Sanitize `filePattern` in `FileSearchTool.swift` (Fix for P1-01)
**File:** `ApexAgent/Tools/FileSearchTool.swift:45`  
**Current Code:**
```swift
if let pattern = arguments.filePattern { cmd += " --include=\(pattern)" }
```
**Recommended Hardening:**
```swift
if let pattern = arguments.filePattern {
    let sanitizedPattern = pattern.replacingOccurrences(of: "'", with: "'\\''")
    cmd += " --include='\(sanitizedPattern)'"
}
```

---

### Recommendation 2: Eliminate Pipe Deadlock in `GitOperationsTool.swift` (Fix for P1-02)
**File:** `ApexAgent/Tools/GitOperationsTool.swift:234-239`  
**Current Code:**
```swift
try process.run()
process.waitUntilExit()

let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
```
**Recommended Hardening:**
```swift
try process.run()

// Read pipe concurrently or prior to waitUntilExit to prevent 64KB buffer deadlock
let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
process.waitUntilExit()
```

---

### Recommendation 3: Eliminate Pipe Deadlock and Argument Duplication in `GitHubTool.swift` (Fix for P1-03, P1-05)
**File:** `ApexAgent/Tools/GitHubTool.swift:106-110, 125, 135, etc.`  
**Current Code (`runCommand`):**
```swift
try process.run()
process.waitUntilExit()
let data = pipe.fileHandleForReading.readDataToEndOfFile()
```
**Recommended Hardening (`runCommand`):**
```swift
try process.run()
let data = pipe.fileHandleForReading.readDataToEndOfFile()
process.waitUntilExit()
```
**Current Code (Subcommand argument builders):**
```swift
var cmd = [ghPath, "issue", "list"]
```
**Recommended Hardening:**
```swift
var cmd = ["issue", "list"]
```
(Apply across all subcommand methods: `runIssue`, `runPR`, `runRepo`, `runWorkflow`, `runAuth`).

---

### Recommendation 4: Asynchronous Read & Timeout for Simctl List (Fix for P1-04)
**File:** `ApexAgent/Tools/SimctlTool.swift:67-70`  
**Current Code:**
```swift
try listProcess.run()
listProcess.waitUntilExit()
let listData = try listPipe.fileHandleForReading.readToEnd() ?? Data()
```
**Recommended Hardening:**
```swift
try listProcess.run()
let listData = try listPipe.fileHandleForReading.readToEnd() ?? Data()
listProcess.waitUntilExit()
```
Add a 15-second timeout watchdog task to cancel `listProcess` if `xcrun` hangs.

---

### Recommendation 5: Enforce Timeout on `AppleScriptTool` Execution (Fix for P2-01)
**File:** `ApexAgent/Tools/AppleScriptTool.swift:37-58`  
**Recommended Hardening:**
Wrap `NSAppleScript.executeAndReturnError` with an async timeout race using `withThrowingTaskGroup` (default 30 seconds). If timeout elapses, return `"ERROR: AppleScript execution timed out after 30 seconds."` instead of blocking the thread continuation.

---

### Recommendation 6: Propagate Cancellation in `OllamaAgentEngine.swift` (Fix for P2-02)
**File:** `ApexAgent/Models/OllamaAgentEngine.swift:202`  
**Current Code:**
```swift
for try await line in stream.lines {
```
**Recommended Hardening:**
```swift
for try await line in stream.lines {
    try Task.checkCancellation()
```

---

### Recommendation 7: Remove Redundant `@unchecked Sendable` in SwiftData Models (Fix for P3-02)
**File:** `ApexAgent/Models/SpaceModels.swift:95, 399`  
**Current Code:**
```swift
@Model
public final class SpaceModel: @unchecked Sendable {
...
@Model
public final class SpacePageProposal: @unchecked Sendable {
```
**Recommended Hardening:**
```swift
@Model
public final class SpaceModel {
...
@Model
public final class SpacePageProposal {
```
(Removes redundant conformance warnings produced by the Swift 6 `@Model` macro expansion).

---

## Conclusion

ApexAgent's core architecture is resilient, modular, and secure. Addressing the 5 identified P1 pipe-deadlock, command-injection, and CLI argument issues will fortify the tool runtime against unexpected hangs and security vulnerabilities during high-load multi-agent orchestration on macOS 27.
