# ApexAgent — Master Task Manifest
> Single source of truth. Generated from a 3-agent parallel audit of every Swift file.  
> Last updated: 2026-06-29

---

## Legend
- 🔴 **Critical** — crash, data loss, security vulnerability, or silent incorrect behavior
- 🟠 **High** — severe performance degradation, architectural correctness issue
- 🟡 **Medium** — missing test coverage, code duplication, UX gaps, architectural tech debt
- 🔵 **Low** — polish, accessibility, naming, minor code smells

Statuses: `[x]` = todo · `[/]` = in-progress · `[x]` = done

---

## 1. 🔴 CRITICAL — Crashes & Data Loss

### 1.1 `AgentOrchestrator.swift:891` — `try!` in PTY fallback path
- **Problem**: The PTY fallback branch uses `try!`. If the fallback init also throws (fork limit, permission, etc.) the app crashes with no recovery.
- **Fix**: Replace `try!` with `try` inside a `do/catch`. Surface the error as a user-visible message.
- `[x]`

### 1.2 `AgentOrchestrator.swift:769,782,794` — `isGenerating` stuck on guard exit
- **Problem**: Three `guard let id = self.activeAssistantMessageId else { return }` paths exit without resetting `isGenerating = false` or clearing `activeAssistantMessageId`. The UI is permanently stuck in generating state after certain failures.
- **Fix**: Add `defer { isGenerating = false; activeAssistantMessageId = nil }` at the top of `currentTask`, or reset state explicitly in all early-return guards.
- `[x]`

### 1.3 `AgentOrchestrator.swift:170–181` — Infinite proactive audit loop, non-cancellable
- **Problem**: `startProactiveAudits()` spins a `while true` inside an unstructured `Task {}` that is never stored or cancelled. There is no way to stop it on dealloc or app quit. Leaks for the lifetime of the app.
- **Fix**: Store `private var auditTask: Task<Void, Never>?`. Set it in `startProactiveAudits()`. Cancel it in `deinit` / `stopProactiveAudits()`. Add `Task.isCancelled` check in the loop body.
- `[x]`

### 1.4 `AgentOrchestrator.swift:1224–1230` — Auto-deny Task lacks weak capture and stored reference
- **Problem**: The 60-second auto-deny `Task` captures `self` strongly, is not stored, and cannot be cancelled. On quick confirm/deny, the orphaned task can fire `resolveConfirmation(approved: false)` against a new confirmation.
- **Fix**: Store `private var confirmationTimeoutTask: Task<Void, Never>?`. Guard by matching confirmation ID before resolving. Cancel on explicit resolution.
- `[x]`

### 1.5 `MessageBubble.swift:160,169,170,175` — Force-unwrapped regex range extractions
- **Problem**: `Range(match.range, in: content)!` crashes on malformed Unicode (surrogate pairs, empty matches near string boundaries).
- **Fix**: Replace all force-unwraps with `guard let range = Range(match.range, in: content) else { continue }`.
- `[x]`

### 1.6 `MCPClient.swift:337,383` — `group.next()!` crashes on concurrent cancellation
- **Problem**: `group.next()!` in `ping()` and `sendRequest(...)` crashes if both task group tasks cancel simultaneously, making `next()` return `nil`.
- **Fix**: `guard let result = try await group.next() else { throw MCPError.timeout("No response") }`.
- `[x]`

### 1.7 `CreateSkillTool.swift:38` — Path traversal in skill name
- **Problem**: `sanitizedName` only lowercases and trims whitespace. A skill named `../../.zshrc` could overwrite shell config files.
- **Fix**: Apply allowlist regex: `[a-z0-9_-]+`. Reject anything that doesn't match. Add test.
- `[x]`

### 1.8 `CreateSkillTool.swift:72` — AI-written shell script executed without sandbox
- **Problem**: The LLM writes a script to disk which is immediately `chmod +x`'d and can be executed. No review step, no code signing, no sandbox restriction.
- **Fix**: Add a confirmation gate (route through `shouldConfirmTool`). Document risk clearly in tool schema description. Consider restricting script execution to a sandboxed directory.
- `[x]`

### 1.9 `CreateSkillTool.swift:64–86` — Partial failure leaves orphaned manifest
- **Problem**: If manifest JSON writes successfully but script write fails, a dangling manifest points at a non-existent script with no rollback.
- **Fix**: Write to a temp path first. Atomically move into place only after both writes succeed. Clean up on any failure.
- `[x]`

### 1.10 `SettingsView.swift:299` — Force-unwrap URL in UI
- **Problem**: `URL(string: "http://localhost:\(collaborativeServerPort)")!` crashes if port becomes invalid (corrupt UserDefaults).
- **Fix**: Use `URL(string: ...)` with optional binding. Show a validation error inline.
- `[x]`

### 1.11 `WorkspaceProactiveAuditor.swift:9` — Real developer path hardcoded in production
- **Problem**: `/Users/danielstevens/Developer` is hardcoded. The feature is broken for every other user.
- **Fix**: Use `NSHomeDirectory()` + a user-configurable path from `UserDefaults`. Fallback to `FileManager.default.currentDirectoryPath`. This was partially addressed in `MCPManager` — apply the same pattern here.
- `[x]`

### 1.12 `DynamicToolbox.swift:209` — String interpolation bug: `\\(name)` prints literally
- **Problem**: `"Tool \\(name) missing execution path"` prints `Tool \(name)` — the interpolation never fires. Error messages have the wrong tool name.
- **Fix**: Remove the extra backslash: `"Tool \(name) missing execution path"`.
- `[x]`

### 1.13 `ToolEventLogger.swift:37` — `ToolEventLoggerImpl.requestConfirmation` always returns `true`
- **Problem**: The no-op fallback logger auto-approves ALL dangerous tool confirmations (delete_file, run_shell_command, etc.) if no orchestrator is wired.
- **Fix**: Default return value must be `false`. Require explicit opt-in. Add a comment explaining the risk.
- `[x]`

### 1.14 `WritingToolsSupport.swift:43` — `success` constant always `true`; error path never fires
- **Problem**: `let success = true` is set before any processing. The function always returns `true` regardless of whether `sendMessage` succeeds. `error.pointee` is never set.
- **Fix**: Capture the actual result of `sendMessage`. Set `error.pointee` on failure. Return `false` to signal the error to the Writing Tools API.
- `[x]`

### 1.15 `PTYSession.swift:225–227` — `Darwin.write()` return value ignored
- **Problem**: Partial writes to the PTY master fd are silently ignored. A truncated command could be sent.
- **Fix**: Check the return value of `Darwin.write()`. Loop until all bytes are written or surface a write error.
- `[x]`

---

## 2. 🟠 HIGH — Performance & Architectural Correctness

### 2.1 `TerminalView.swift:22` — `ANSIColorParser.parse()` called inside `body`
- **Problem**: On every state change of `orchestrator` (including every streamed token), the full 50,000-char terminal output is re-parsed synchronously on the main thread. Causes visible frame drops during streaming.
- **Fix**: Cache parsed segments in a `@State private var terminalSegments`. Update only via `.onChange(of: orchestrator.activeTerminalOutput)`.
- `[x]`

### 2.2 `MessageBubble.swift:121+150` — Regex created + full parse on every streaming token
- **Problem**: `parseBlocks()` creates a new `NSRegularExpression` on every call and re-parses the entire message content. During streaming, this runs dozens of times per second per bubble.
- **Fix**: Promote `NSRegularExpression` to `static let`. Memoize parsed blocks keyed by content hash or message ID + length. Only re-parse on actual content change.
- `[x]`

### 2.3 `DiffView.swift:7–9, 100–104` — Diff computed twice per render
- **Problem**: `private var diffLines` (computed property) is called once for body and once for `computeStats`. Both perform O(n²) diff computation.
- **Fix**: Make `diffLines` a single `let` stored in `.task {}` or computed once in `.onAppear`. Pass the single result to `computeStats`.
- `[x]`

### 2.4 `ScreenStreamer.swift:69` — New `CIContext` created on every captured frame
- **Problem**: `let context = CIContext(options: nil)` inside the frame callback allocates a new Metal/GPU context on every frame (~1x/sec but still expensive).
- **Fix**: Promote to a stored property: `private let ciContext = CIContext(options: [.useSoftwareRenderer: false])`.
- `[x]`

### 2.5 `SettingsView.swift:65–99` — Keychain write on every keystroke
- **Problem**: `onChange` for API key / URL fields writes to the Keychain synchronously on every character typed. Keychain I/O is synchronous and relatively expensive.
- **Fix**: Debounce writes (e.g., 0.5s after last keystroke) or write on field `onSubmit`/focus-loss.
- `[x]`

### 2.6 `WorkspaceProactiveAuditor.swift:96–141` — Blocking synchronous file I/O on actor thread
- **Problem**: `findTodos()` and `findTestGaps()` walk the entire workspace tree synchronously on the actor's serial executor. Blocks the actor for seconds on large workspaces.
- **Fix**: Wrap the file I/O in `Task.detached(priority: .background)` or use async file reading.
- `[x]`

### 2.7 `AgentOrchestrator.swift:533–576` — `allTools` computed var creates new tool instances every call
- **Problem**: `var allTools: [any Tool]` is a computed property that allocates fresh instances of every tool on every call. Called at least once per session init.
- **Fix**: Make it `lazy var allTools: [any Tool]` or cache in a private stored property, invalidated only when configuration changes.
- `[x]`

### 2.8 `AgentOrchestrator.swift:456–528` — `rehydrateSession()` has 10 near-identical construction blocks
- **Problem**: A 5-branch `switch` × 2 (`multiAgentMode`) = 10 nearly-identical `LanguageModelSession` construction blocks. Adding a new model type requires touching all 10.
- **Fix**: Resolve model and instructions first (single switch), then call a single `LanguageModelSession(model:instructions:tools:)` constructor.
- `[x]`

### 2.9 `AgentOrchestrator.swift:932–1064` — 130-line `executeToolByName` switch
- **Problem**: A 30+ case switch that manually decode/create/call each tool. Every new tool requires a new case AND updating `allTools`. These can diverge silently.
- **Fix**: Replace with `allTools.first(where: { $0.name == name })` + a unified `decodeAndCall(tool:arguments:)` pattern. Remove the switch entirely.
- `[x]`

### 2.10 `AgentOrchestrator.swift:202–286` — `DispatchQueue.main.sync` deadlock risk
- **Problem**: `isPathAllowed`, `isFolderAccessRestricted`, and `isCommandOrScriptAllowed` use `DispatchQueue.main.sync` from background threads. Calling these from the main thread (e.g., via a sync callback) causes a deadlock.
- **Fix**: Make these `async` functions and replace `DispatchQueue.main.sync` with `await MainActor.run { }`.
- `[x]`

### 2.11 `DynamicToolbox.swift:44–46` — `loadMCPTools()` fire-and-forget races with multiple `loadTools()` calls
- **Problem**: Each call to `loadTools()` spawns a new `Task { await loadMCPTools() }` without cancelling the previous one. Multiple in-flight tasks can clobber each other's results, producing duplicate entries.
- **Fix**: Store the task reference. Cancel the previous task before spawning a new one.
- `[x]`

### 2.12 `MCPClient.swift:164` — Polling loop reads 4096-byte chunks with no backoff
- **Problem**: The stdout read loop busy-reads on quiet servers, wasting CPU.
- **Fix**: Use `DispatchSourceRead` (as PTYSession does) rather than a polling loop.
- `[x]`

### 2.13 `AgentOrchestrator.swift:590` — `Date().formatted()` in hot path
- **Problem**: `Date().formatted()` uses the locale-dependent default formatter (expensive to construct) inside `logReasoning()`, which is called on every reasoning step.
- **Fix**: Cache an `ISO8601DateFormatter` as a private static property and use `.string(from:)`.
- `[x]`

### 2.14 `VoiceController.swift:58–77` — `@MainActor` state mutated from AVFoundation callbacks
- **Problem**: `inputNode.installTap` callback and `recognitionTask` callback run on AVFoundation background threads while accessing `@MainActor`-isolated properties (`recognitionRequest`, `isRecording`, etc.). This is a data race under Swift 6 strict concurrency.
- **Fix**: Dispatch all state mutations through `Task { @MainActor in ... }` inside the callbacks.
- `[x]`

### 2.15 `ScreenStreamer.swift:77–92` — `@MainActor` isolation bypassed via `DispatchQueue.main.async`
- **Problem**: The `SCStreamOutput` callbacks (nonisolated) mutate `@MainActor`-isolated properties via `DispatchQueue.main.async`, bypassing actor isolation guarantees.
- **Fix**: Replace `DispatchQueue.main.async { ScreenStreamer.shared.xxx }` with `Task { @MainActor in ScreenStreamer.shared.xxx }`.
- `[x]`

### 2.16 `CloudGeminiLanguageModel.swift:207` — Gemini model name hardcoded (`gemini-1.5-flash`)
- **Problem**: No user-configurable model selector. All Gemini users are silently pinned to `gemini-1.5-flash` even if they have API access to `gemini-2.0-flash` or `gemini-1.5-pro`.
- **Fix**: Add a `UserDefaults` key `"apex.geminiModel"` with a default of `"gemini-2.0-flash"`. Expose it in Settings alongside the Ollama model selector.
- `[x]`

### 2.17 `CloudGeminiLanguageModel.swift:207` — API key in URL query string
- **Problem**: `&key=\(apiKey)` embeds the API key in the URL, which appears in server access logs and network proxies.
- **Fix**: Remove the key from the URL. Send it as an HTTP header: `"x-goog-api-key": apiKey`.
- `[x]`

### 2.18 `Tool+Logging.swift:61` — Tool output truncation at 1000 chars is too aggressive
- **Problem**: All tool output is truncated to 1000 characters, silently cutting off directory listings, shell output, and file contents. The model makes wrong decisions on incomplete output.
- **Fix**: Raise the limit to at least 8000 characters. Optionally, make the limit configurable per-tool or via a UserDefaults key.
- `[x]`

### 2.19 `Tool+Logging.swift:23` — Tool call limit of 4 per turn too restrictive
- **Problem**: 4 tool calls per turn is routinely hit in normal tasks (e.g., "read file → fix → write → run tests" = exactly 4). Multi-step tasks always fail to complete.
- **Fix**: Raise the default limit to 20. Consider making it configurable in Settings.
- `[x]`

### 2.20 `AgentProfiles.swift:160–175` — `DeveloperAgentProfile` missing `ShellTool`
- **Problem**: Delegated developer agents cannot run compile or test commands. The capability is absent from their tool set.
- **Fix**: Add `ShellTool.self` (and `AnalyzeImageTool.self`) to `DeveloperAgentProfile.tools`.
- `[x]`

### 2.21 `WorkspaceProactiveAuditor.swift:25–63` — Long SwiftData operation blocking `MainActor`
- **Problem**: A single `await MainActor.run { }` block performs SwiftData fetch, object construction, insert, and save. This freezes the UI for the duration.
- **Fix**: Fetch and save using a background `ModelContext`. Only post results back to main actor when complete.
- `[x]`

---

## 3. 🟡 MEDIUM — Missing Tests & Code Quality

### 3.1 Zero test coverage for 7 critical features
- `[x]` `ConfirmCompletionTool` — no tests at all
- `[x]` `ProjectManagementTools` (7 tools: Create/List Project, Sprint, Task; UpdateTaskStatus) — no tests at all
- `[x]` `CodeReviewPersistenceTools` (SaveReviewSession, ListReviewSessions) — no tests
- `[x]` `WorkspaceProactiveAuditor` — no tests
- `[x]` `WritingToolsSupport` — no tests
- `[x]` `ContextWindowManager` (shared-kit) — no tests
- `[x]` `ToolResultCache` (shared-kit) — no tests

### 3.2 `ProjectManagementTools` — `todo` status maps to `.backlog` (logic bug)
- **File**: `ProjectManagementTools.swift` in `UpdateTaskStatusTool`
- **Problem**: Both `"todo"` and `"backlog"` map to `.backlog`. A `todo` task cannot be differentiated from a `backlog` task after creation.
- **Fix**: Map `"todo"` to `.todo` (or document explicitly that `todo` is an alias for `backlog`). Add test coverage.
- `[x]`

### 3.3 `RunWorkflowTool` — Schema/parameter name mismatch
- **File**: `AgentEngine.swift:452` schema defines `"topic"`, but `RunWorkflowTool.Arguments` on line 17 defines `var task: String`.
- **Problem**: Gemini/Ollama will pass `"topic"` but the decoder looks for `"task"` → JSON decode failure on every invocation.
- **Fix**: Align the schema and the `Arguments` struct to use the same key (`"task"` is preferred). Add a decode test.
- `[x]`

### 3.4 `AgentEngine.swift:139–491` — 350-line JSON string literal for tool schemas
- **Problem**: Tool schemas are embedded as a raw JSON string literal in source. Any schema change requires editing this string with no validation. It's unmaintainable as the tool count grows.
- **Fix**: Move to a `ToolSchemas.json` bundled resource file. Load with `Bundle.main.url(forResource:)`. Validate at startup with a test.
- `[x]`

### 3.5 `StateGraph.swift` — No cycle detection; infinite loop risk
- **Problem**: If two edges form a cycle (A→B→A), the workflow runs forever. No `maxIterations` guard or visited-set.
- **Fix**: Add a `var visitedNodes: Set<String>` per execution. Throw `StateGraphError.cyclicExecution` if a node is visited twice. Also add a `maxIterations` guard.
- `[x]`

### 3.6 `StateGraph.swift` — Untyped `[String: Any]` state container
- **Problem**: State sharing between graph nodes is untyped. Type bugs are silent at compile time.
- **Fix**: Replace with a typed `Codable` protocol or generic `StateGraph<State: Codable>`. At minimum, provide typed accessors that throw on type mismatch.
- `[x]`

### 3.7 `StateGraph.swift` — Not concurrency-safe
- **Problem**: `StateGraph` is a `class` with mutable `nodes`, `edges`, and `entryNode` dictionaries with no locking. Concurrent `addNode`/`addEdge` corrupts state.
- **Fix**: Convert to `actor` or use `os_unfair_lock` / `NSLock` around all mutations.
- `[x]`

### 3.8 `WebSearchTool.swift` — DuckDuckGo fallback doesn't actually search
- **Problem**: The DDG fallback uses only the Instant Answer API, which returns useful data for ~10% of queries. The 90% majority get a message saying to try something else. This is a dead fallback.
- **Fix**: Implement real DDG web search via scraping the HTML results page, or integrate a free-tier alternative (SerpAPI, Jina Reader, etc.).
- `[x]`

### 3.9 `WebSearchTool.swift` — No retry or rate-limit backoff
- **Problem**: A single Brave API call failure throws immediately with no retry. HTTP 429 (rate limit) gives no backoff.
- **Fix**: Add a 2-retry exponential backoff wrapper. Log 429 responses distinctly.
- `[x]`

### 3.10 `AgentOrchestrator.swift:339, 707, 727 + 6 more` — `try?` swallows all SwiftData errors
- **Problem**: `try? context.save()` and `try? context.fetch()` appear at least 8 times. All SwiftData failures are silently discarded.
- **Fix**: Create a `private func saveContext() throws` helper that wraps save with structured error logging. Use `do/catch` at each call site and present user-visible error for critical operations.
- `[x]`

### 3.11 `AgentProfiles.swift` — 7 structurally identical profile structs
- **Problem**: 7 profiles with identical 4-field structure, all computing fresh tool instances on every `body` access.
- **Fix**: Define a protocol `AgentProfile` + a generic `DefaultAgentProfile<Tools>` struct. Reduce boilerplate by ~90%. Cache tool instances as `static let`.
- `[x]`

### 3.12 `CloudGeminiLanguageModel.swift` + `LocalOllamaLanguageModel.swift` — Duplicated `jsonObject` helper
- **Problem**: Identical private helper function in both files.
- **Fix**: Extract to `GeneratedContentExtensions.swift` as an `internal` extension method in the module.
- `[x]`

### 3.13 Both executors — Duplicated dynamic tool loop
- **Problem**: The entire `respond(to:model:streamingInto:)` body structure (dynamic tool loop, circuit break, routing) is copy-pasted between Gemini and Ollama executors.
- **Fix**: Extract shared protocol `LLMExecutor` with a base class or mixin that handles the tool loop. Each executor provides only the HTTP layer.
- `[x]`

### 3.14 `ContextWindowManager.swift:27–28` — Integer division loses remainder in token count
- **Problem**: `msg.content.count / 4` produces 0 for messages ≤ 3 chars. Allows infinite such messages.
- **Fix**: Use ceiling division: `(msg.content.count + 3) / 4`.
- `[x]`

### 3.15 `ToolResultCache.swift` — No size limit or proactive eviction
- **Problem**: The cache grows unbounded. Large tool results (files, shell output) will eventually exhaust memory.
- **Fix**: Add a max-entry count (e.g., 500). Evict LRU entries when the limit is reached. Add a periodic expiry sweep.
- `[x]`

### 3.16 `AgentOrchestrator.swift:99` — `nonisolated(unsafe)` static var is a data race in tests
- **Problem**: `static nonisolated(unsafe) var isTestMode: Bool` is written from tests and read across multiple contexts. Concurrent test runs produce a data race.
- **Fix**: Replace with `@TaskLocal static var isTestMode: Bool = false` to scope it per-task, or move it to a proper test-injection mechanism.
- `[x]`

### 3.17 `NotificationTool.swift:39–45` — Permission requested on every notification send
- **Fix**: Request notification authorization once at app launch (in `AppDelegate.applicationDidFinishLaunching`). Cache the result.
- `[x]`

### 3.18 `FileSystemTools.swift` — No path traversal prevention
- **Problem**: Path expansion doesn't guard against `../` sequences. A path like `~/safe/../../etc/passwd` may bypass folder permission checks after `standardized.path` resolution.
- **Fix**: After `standardizedPath`, verify the path still starts with an allowed prefix (`NSHomeDirectory()`, a user-configured workspace root, etc.).
- `[x]`

### 3.19 `FileSystemTools.swift:188` — Recursive listing with no output cap
- **Problem**: `listContents` with depth=5 on a build directory can return megabytes of output.
- **Fix**: Cap the number of returned items (e.g., 500). Return a truncation note if capped. Raise tool output limit per item 3.18 above.
- `[x]`

### 3.20 `AccessibilityControlTool.swift:88` — Force cast `AXUIElement`
- **Fix**: Replace `let axWindow = windowElement as! AXUIElement` with `guard let axWindow = windowElement as? AXUIElement else { return "Error: could not cast to AXUIElement" }`.
- `[x]`

### 3.21 `AccessibilityControlTool.swift` — Registry not cleared between conversations
- **Problem**: Stale element IDs from previous conversations persist in the registry when switching conversations without re-invoking `list_elements`.
- **Fix**: Clear the registry on `startNewConversation()` in the orchestrator.
- `[x]`

### 3.22 `DiagnosticManager.swift:134–163` — Blocking `waitUntilExit()` on main actor
- **Problem**: `process.waitUntilExit()` is called synchronously inside a `@MainActor async` function. Freezes the UI while each of 5 CLI tool checks runs.
- **Fix**: Wrap each `Process` launch and wait in a `Task.detached(priority: .background)`. Collect results via `async let` or `TaskGroup`.
- `[x]`

### 3.23 `AgentSystemPrompt.swift` — Mode variants strip base guardrails instead of extending them
- **Problem**: `codingMode`, `researchMode`, and `systemMode` are complete replacements that omit the base prompt's security guardrails and behavioral constraints.
- **Fix**: Refactor to a base prompt + mode-specific addendum string concatenation. Ensure all modes inherit the base safety instructions.
- `[x]`

### 3.24 `AgentSystemPrompt.swift` — Missing capability descriptions
Key capabilities not described in any mode's prompt:
- `[x]` Memory system (`store_memory`, `search_memory`) — agent doesn't know when to proactively recall
- `[x]` Vision tools (`analyze_image`, `detect_image_text`)
- `[x]` Multi-agent orchestration (`delegate_task`, `convene_meeting`, `update_plan`)
- `[x]` Confirmation protocol — which tool calls trigger user confirmation
- `[x]` Project management tools (`create_project`, `create_sprint`, etc.)

### 3.25 Test file force-unwraps cause crashes instead of failures
- **File**: `ApexAgentTests.swift:692–696, 725–728, 508–513, 1106, 1151, 1163`
- **Problem**: Force-unwrapped values in test setup cause crashes instead of clean `XCTFail`. Test order changes can expose nil paths unexpectedly.
- **Fix**: Replace all `!` force-unwraps in test files with `try XCTUnwrap(...)`.
- `[x]`

### 3.26 Test files reference hardcoded personal paths
- **File**: `ApexAgentTests.swift:618, 638`
- **Problem**: `/Users/danielstevens/Developer/fleet` hardcoded. Test silently no-ops on other machines.
- **Fix**: Create a temp directory fixture in `setUp()`. Use `XCTSkip()` with a clear message if specific paths are required.
- `[x]`

### 3.27 `ChatView.swift:205` — `@StateObject` wrapping a singleton
- **Problem**: `@StateObject private var voiceController = VoiceController.shared` is semantically incorrect and may not re-render correctly if `VoiceController` uses `@Observable` instead of `ObservableObject`.
- **Fix**: Change to `@State private var voiceController = VoiceController.shared` or use the environment.
- `[x]`

### 3.28 `ContentView.swift:147` — String-literal `Notification.Name`
- **Problem**: `Notification.Name("showDiagnosticsSheet")` is a raw string that silently fails if mistyped.
- **Fix**: Add `static extension Notification.Name { static let showDiagnosticsSheet = Notification.Name("showDiagnosticsSheet") }`. Use it everywhere.
- `[x]`

### 3.29 `PlanStep.status` string comparisons — use enum everywhere
- **Files**: `PlanTools.swift`, `PlanDashboardView.swift`, `ToolActivityView.swift`
- **Problem**: `"running"`, `"completed"`, `"failed"` compared as raw strings in 3+ places. Typos are silent.
- **Fix**: Define `enum PlanStepStatus: String, Codable` with all cases. Update `PlanStep.status` to use this type. Fix all comparison sites.
- `[x]`

### 3.30 `AgentOrchestrator` — Access control tightening
Over-exposed mutable properties that should be `private(set)` or `private`:
- `[x]` `messages` → `private(set) var`
- `[x]` `toolEvents` → `private(set) var` + add `func clearToolEvents()`
- `[x]` `isGenerating` → `private(set) var`
- `[x]` `pendingConfirmation` → `private(set) var`
- `[x]` `session` → `private var`
- `[x]` `activeAssistantMessageId` → `private var`
- `[x]` `ptySessions` → `private var`
- `[x]` `activeTurnToolCallCount` → `private(set) var`
- `[x]` Replace direct `orchestrator.activePlan = []` mutation from PlanDashboardView with `orchestrator.clearPlan()`

### 3.31 `VoiceController.swift` — Locale and speech rate hardcoded
- **Fix**: Add `UserDefaults` keys `"apex.voiceLocale"` and `"apex.voiceSpeechRate"`. Expose in Settings. Default `"en-US"` and `0.52`.
- `[x]`

### 3.32 `VoiceController.swift:99–103` — Incomplete markdown stripping for TTS
- **Problem**: `#` headers, `>` blockquotes, `_` italics, `---` dividers, numbered lists are not stripped. Responses sound robotic.
- **Fix**: Expand the regex stripping to cover all common markdown patterns before synthesis.
- `[x]`

---

## 4. 🔵 LOW — Polish, Accessibility & Minor Code Quality

### 4.1 Accessibility — Missing labels across all UI files
Apply to each file:
- `[x]` `ChatView.swift` — Generation banner, send button, cancel button, attachment remove button
- `[x]` `ContentView.swift` — All toolbar buttons (New Conversation, Settings, Diagnostics, Terminal, Plan, Activity), modal overlay
- `[x]` `SettingsView.swift` — Mode button chevrons (mark decorative)
- `[x]` `MessageBubble.swift` — Combine bubble into single element with role+content+time label; hide decorative icons
- `[x]` `SidebarView.swift` — Convert `.onTapGesture` rows to `Button`; add selection accessibility value
- `[x]` `DiagnosticsView.swift` — Cards, Re-Run button, ProgressView
- `[x]` `PlanDashboardView.swift` — Progress bar value, Clear button
- `[x]` `ToolActivityView.swift` — Status icons, expand/collapse button
- `[x]` `QuickPromptPanel.swift` — TextField, Close button; add Escape key dismissal
- `[x]` `ConfirmationOverlay.swift` — Add `.accessibilityAddTraits(.isModal)`; trap focus; announce countdown

### 4.2 Dead code — Remove unused state and parameters
- `[x]` `ChatView.swift:9` — Remove unused `@State private var scrollProxy: ScrollViewProxy?`
- `[x]` `MessageBubble.swift:42` — Remove unused `@State private var isExpanded = true`
- `[x]` `BubbleShape` — Implement asymmetric corners per `isUser` or remove the parameter
- `[x]` `TerminalStateView.swift` — Rename `enum State` to `enum TerminalSessionState` to avoid `SwiftUI.State` collision
- `[x]` `BlinkModifier` — Remove unused `tag: String` parameter

### 4.3 `AppTheme.swift` — Missing semantic color tokens
- `[x]` Add `destructive`, `info`, `disabled`, `warning` color tokens
- `[x]` Replace inline `Color.red`, `Color.orange` at call sites with theme tokens
- `[x]` Add Dynamic Type support (use `Font.system(size:weight:design:)` with `@ScaledMetric` or `Font.body` / `Font.headline` etc.)
- `[x]` Use `.accentColor` environment key or asset catalog for the accent color instead of hardcoded `Color.purple`

### 4.4 `ContentView.swift` — Persist UI layout preferences
- `[x]` Change `showActivityLog`, `showTerminal`, `showPlanDashboard` from `@State` to `@AppStorage` so layout survives relaunches

### 4.5 `SidebarView.swift` — Add context menu
- `[x]` Add right-click context menu with "Rename Conversation" and "Delete" actions
- `[x]` Add inline rename via double-click on the title text

### 4.6 `ScreenStreamer.swift` — Hardcoded resolution and frame rate
- `[x]` Make capture width/height configurable (or match screen pixel dimensions via `NSScreen.main`)
- `[x]` Expose frame rate as a UserDefaults setting

### 4.7 `MCPClient.swift` — Configurable retry constants
- `[x]` Move `maxRetries`, `delayBase`, ping timeout, and request timeout to per-server config or UserDefaults

### 4.8 `AgentOrchestrator.swift` — Extract constants from magic numbers
- `[x]` `0.4` RAG similarity threshold → `private static let ragSimilarityThreshold = 0.4`
- `[x]` `prefix(3)` RAG results → `private static let ragTopK = 3`
- `[x]` `maxChars: 1500` pruning → `private static let contextPruningMaxChars = 1500`
- `[x]` `suffix(10)` rehydration window → `private static let rehydrationWindowSize = 10`
- `[x]` `12000` compaction threshold → `private static let contextCompactionThreshold = 12000`
- `[x]` `50000` terminal output cap → `private static let terminalOutputCap = 50000`
- `[x]` `200` tool event cap → `private static let maxToolEventCount = 200`
- `[x]` `60` auto-deny timeout → `private static let confirmationTimeoutSeconds = 60`
- `[x]` `["run_shell_command", "delete_file", "write_file", "run_applescript"]` dangerous tools list → `private static let dangerousToolNames: Set<String>`
- `[x]` `URL(string: "http://localhost:11434")!` → `private static let defaultOllamaURL`

### 4.9 `WorkspaceProactiveAuditor.swift:107` — Case-insensitive TODO/FIXME matching
- `[x]` Change `line.contains("TODO:")` to `line.range(of: "TODO:|FIXME:", options: [.regularExpression, .caseInsensitive]) != nil`
- `[x]` Also match `// todo`, `// fixme` (without colon)

### 4.10 Logging — Replace `print()` with structured logging
- `[x]` Integrate `os.Logger` with subsystem `"com.apex.agent"` and categories per component
- `[x]` Define log levels: debug, info, warning, error
- `[x]` Replace all `print()` call sites across the codebase
- `[x]` Surface error-level logs in DiagnosticsView

### 4.11 `ConfirmationOverlay.swift:166` — Return key approves destructive action
- `[x]` Change keyboard shortcut mapping: make `⎋` deny, `⌘↩` (not bare `↩`) approve. Add visual affordance showing the shortcuts.

### 4.12 `SettingsView.swift` — UX improvements
- `[x]` Use `Picker`/`SegmentedControl` for the Apple Container / Docker mutual-exclusion instead of two interdependent toggles
- `[x]` Add port number validation (1–65535) to the collaborative server port field
- `[x]` "Clear Conversation History" should also delete persisted conversations from SwiftData (not just reset in-memory state)
- `[x]` Add a confirmation dialog before "Quick Mode" buttons overwrite instructions and reset the session

### 4.13 `ContextWindowManager.swift:33–37` — System message not truncated if it exceeds token budget
- `[x]` If system message alone exceeds `maxTokens`, truncate it with a suffix indicator rather than silently overflowing

### 4.14 `AppGroupDataBus.swift` — Add partial update methods
- `[x]` Add `update(tasks:)`, `update(mood:)` etc. so callers don't need to know the full current state to update one field

---

## 5. Implementation Order Recommendation

Work in this sequence for maximum stability:

```
Phase 1 — Stop the bleeding (Critical crashes & security)
  Items: 1.1 → 1.15 (all 🔴)

Phase 2 — Performance & correctness (High priority)  
  Items: 2.1 → 2.21 (all 🟠)

Phase 3 — Test coverage gaps (Medium, test-related)
  Items: 3.1 → 3.5, 3.25, 3.26

Phase 4 — Architecture cleanup (Medium, code quality)
  Items: 3.6 → 3.24, 3.27 → 3.32

Phase 5 — Polish & accessibility (Low)
  Items: 4.1 → 4.14
```

---

## 6. Files With Zero Test Coverage (Priority Additions)

| File | Priority | Test Cases Needed |
|------|----------|-------------------|
| `ConfirmCompletionTool.swift` | 🔴 | approve path, deny path, missing orchestrator |
| `ProjectManagementTools.swift` | 🟠 | all 7 tools, status mapping, sprint date parsing |
| `CodeReviewPersistenceTools.swift` | 🟠 | save/load round-trip, invalid issuesJSON |
| `WorkspaceProactiveAuditor.swift` | 🟠 | findTodos, findTestGaps, path resolution |
| `WritingToolsSupport.swift` | 🟠 | processText success/failure, always-true bug |
| `ContextWindowManager.swift` | 🟡 | truncation, system msg preservation, overflow |
| `ToolResultCache.swift` | 🟡 | eviction, TTL, size limit |
| `DynamicToolbox.swift` | 🟡 | YAML parsing, duplicate load race |
| `StateGraph.swift` | 🟡 | cycle detection, max iterations |
| `WeeklyReflectionToolTests.swift` | 🟡 | schema completeness, actual data validation |

---

*Total tracked items: 90+ across 5 priority tiers. This manifest supersedes all previous audit reports.*
