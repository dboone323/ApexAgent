# Investigation: SwiftData crash in `ApexCLIRouterTests.renderImmediateSubcommands`

**Date:** 2026-10-20 · **Type:** Read-only root-cause investigation (no code changed)
**Failure:** `SwiftData/BackingData.swift:941: Fatal error: This model instance was destroyed by calling ModelContext.reset and is no longer usable. PersistentIdentifier(id: … <x-coredata://…/Routine/p1>)`

---

## Verdict (one line)

**This is a test bug — cross-test pollution through the `RoutineManager.shared` singleton — enabled by a fragile production pattern (a singleton that caches live `@Model` instances and consumers that read the cache without re-fetching). The shipping app, as wired today, cannot hit this crash.**

---

## 1. The stale access — proven by the crash backtrace

macOS captured the trap in `~/Library/Logs/DiagnosticReports/xctest-2026-10-20-132511.ips` (13:25:11 local, during the unit-test run). Faulting thread (main), key frames:

```
Routine.name.getter
closure #3 in static ApexCLIRouter.renderImmediateSubcommand(_:)   ApexCLIRouter.swift:604
Collection.map
static ApexCLIRouter.renderImmediateSubcommand(_:)                 ApexCLIRouter.swift:604
ApexCLIRouterTests.renderImmediateSubcommands()                    ApexCLIRouterTests.swift:113
```

The code at those exact lines:

`ApexAgentTests/ApexCLIRouterTests.swift:113`
```swift
let routinesOut = try #require(ApexCLIRouter.renderImmediateSubcommand(.routinesList(jsonOutput: true)))
```

`ApexAgent/Models/ApexCLIRouter.swift:601-604`
```swift
case .routinesList(let jsonOutput):
    let routines = RoutineManager.shared.routines
    if jsonOutput {
        let items = routines.map { ["name": $0.name, "trigger": $0.trigger.rawValue, "enabled": "\($0.enabled)"] }
```

So the render reads the singleton's **cached** `[Routine]` array and touches `$0.name` on an instance whose context has already been destroyed. The router itself never calls `reset()`, never creates a context, and `ApexCLIRouterTests` itself contains **no** ModelContainer, ModelContext, or `reset()` anywhere (verified by full read of the 133-line file).

## 2. Who poisoned the cache — `PendingRoadmapItemsTests`

`ApexAgentTests/PendingRoadmapItemsTests.swift`, `setUp()` (lines 49-51):

```swift
routineManager = RoutineManager.shared
routineManager.modelContext = modelContext      // its own throwaway in-memory context
routineManager.botManager = botManager
```

Its routine test (lines 75-82) creates the suite's only `Routine` and saves it through the singleton:

```swift
let failRoutine = Routine(name: "DeployFailureReaction", … trigger: .onMessage, …)
routineManager.save(failRoutine)
```

`RoutineManager.save` inserts into that context and calls `loadRoutines()` (`ApexAgent/Models/RoutineManager.swift:126-137`), which fetches into the singleton's cache (`RoutineManager.swift:110-124`):

```swift
func loadRoutines() {
    guard let context = modelContext else { routines = []; return }
    …
    routines = try context.fetch(descriptor)   // live @Model instances, cached in the singleton
}
```

Because "DeployFailureReaction" is the **first and only** `Routine` inserted into that in-memory store, its identifier is `Routine/p1` — an exact match for the identifier in the crash message.

`tearDown()` (lines 54-62) nils only the test's own properties. It **never** clears `RoutineManager.shared.routines`, never restores `RoutineManager.shared.modelContext`. The poisoned cache outlives the test.

## 3. Who "resets" — nobody calls it; the context is destroyed by teardown

An exhaustive check of every file that references `RoutineManager` or `ModelContext` (production router, `RoutineManager`, `BotManager`, `SkillManager`, `SpaceManager`, `AgentOrchestrator`, `ContentView`, `SettingsView`, `RoutinesSection`, `ApexAgentApp`, and all routine/CLI/persistence/hosting test files) found **no explicit `ModelContext.reset()` call anywhere**.

The destruction happens by lifetime: `PendingRoadmapItemsTests` creates a **fresh** in-memory container in `setUp()` before **each** of its 11 test methods. The next `setUp()` reassigns `RoutineManager.shared.modelContext` to the new container's context; once the previous test instance is released, the old container/context lose their last strong references and deallocate — and SwiftData destroys every model instance registered in a torn-down context, through the same internal path that produces the "destroyed by calling ModelContext.reset" trap. The cached `Routine/p1` in `RoutineManager.shared.routines` is left dangling.

Sequence of the crash:

1. `PendingRoadmapItemsTests.testRoutineOnMessageTriggerMatchingAndDispatch` runs → singleton cache = `[DeployFailureReaction]` (context C1).
2. Any later `PendingRoadmapItemsTests.setUp()` runs → singleton repointed to C2; C1 deallocates; the cached instance is destroyed.
3. Later still, `ApexCLIRouterTests.renderImmediateSubcommands` runs → reads the stale cache → `$0.name` traps. Process dies; the failure is attributed to the CLI test that happened to touch the body.

This also explains the intermittency: `ApexAgent-UnitTests.xctestplan` sets `"testExecutionOrdering": "random"`. The crash only occurs when that interleaving (routine test → another PendingRoadmap setUp → CLI render test) happens. **A single green rerun does not prove anything** — and equally, the failure can appear/disappear between runs with zero code changes.

## 4. Test bug or production bug? — Test bug (with a production design weakness)

Deciding evidence:

- The destroyed instance was created, inserted, and cached **by test code** pointing a production singleton at a throwaway context it then abandoned. No production code path does this.
- In the **GUI app**, nothing ever assigns `RoutineManager.shared.modelContext` (verified: `ContentView.onAppear` wires orchestrator/BotManager/SpaceManager only; `SettingsView`/`RoutinesSection` never assign it) — the cache stays empty and the CLI render prints `[]`.
- In **daemon mode** (`ApexAgentApp.swift`, `runDaemonMode()`), the singleton *is* wired (`RoutineManager.shared.modelContext = context; …loadRoutines(); …startScheduledRoutines()`), but that context is created once and lives for the process lifetime — its instances are never destroyed.
- The production weakness that made the trap possible: `RoutineManager` caches live `@Model` instances in `routines` (RoutineManager.swift:29) and the CLI consumers read the cache **without** calling `loadRoutines()` first. Any future code that repoints the singleton's context (exactly what the test does) re-arms the trap. Worth hardening, but it is not the cause of this crash.

## 5. Blast radius

Same-pattern readers of the un-refreshed cache (all would trap on a destroyed instance):

- `ApexCLIRouter.swift:602-611` — `.routinesList`, JSON and text branches (the crash site + its twin).
- `ApexCLIRouter.swift:779` — `runNamedRoutine` reads `RoutineManager.shared.routines.first(where: { $0.name… })`.
- `RoutineManager.exportRoutinesSummaryAsMarkdown()` and `startScheduledRoutines()` also consume the cached array (safe in daemon mode only because that context never dies).

Safe consumers (re-fetch first): `dispatchOnMessage` and `dispatchWebhook` both call `loadRoutines()` before touching instances.

Structural twin: `SkillManager` repeats the pattern exactly (`static let shared`, cached `var skills: [Skill] = []`, `weak var modelContext`). No current consumer renders skills from that cache (the CLI skills path is file-based via `SkillCatalog`), so there is no second crash today — but the same test-pollution trap exists if a test repoints `SkillManager.shared`.

In the test target, `PendingRoadmapItemsTests` is the only suite found that assigns `RoutineManager.shared.modelContext`. (`ApexAgentTests.sharedOrchestrator` also holds model instances, but its container is a `static let` that is never replaced, so its instances can never be destroyed — safe by accident.)

**Running-app risk: none from this pattern as wired today** (see §4). The risk is confined to the test process.

## 6. Recommended fix (NOT applied)

**Primary — fix the test pollution** in `ApexAgentTests/PendingRoadmapItemsTests.swift`:

- Preferred: stop using the singleton. At line 49, use a fresh instance — `routineManager = RoutineManager()` — keep the line 50-51 wiring on that instance. All routine calls in the suite are instance calls, so nothing else changes, and the suite can no longer poison (or be poisoned by) shared state.
- If `.shared` must be used: in `tearDown()` (before nil-ing the locals, ~line 54), restore the singleton:
  ```swift
  routineManager.routines = []
  routineManager.modelContext = nil
  routineManager.botManager = nil
  ```

**Secondary — harden the production read path** in `ApexAgent/Models/ApexCLIRouter.swift`:

- In the `.routinesList` case (line 601-602) and in `runNamedRoutine` (~line 779), call `RoutineManager.shared.loadRoutines()` immediately before reading `RoutineManager.shared.routines`, so rendering always works on instances owned by the *current* context. This makes the CLI immune to context repointing in any environment.

**Verification note:** because the failure is ordering-dependent, verify by running the full unit plan several times (or with test-iteration/shuffle-seed variation), not once — and specifically confirm `PendingRoadmapItemsTests` and `ApexCLIRouterTests` co-run in the same process.

## 7. Independence of the other four pending fixes

The other failures from the 2026-10-20 run are **fully independent** of this crash and safe to apply separately, in any order:

1. `testCollaborativeServerHTTPEndpoints` 401s — test doesn't send the auth token (test-only change in `ApexAgentTests.swift`).
2. `OpenDotsTests.testDotSandboxDirectoryTraversalRejection` — test must expect the correctly-thrown 403 (test-only).
3. `SwiftSyntaxLintGateTests.liveChangedSwiftFilesPassGate` — should skip when the git tree is clean (test-only).
4. `ToolGovernanceTests` — add `ToolPolicy` risk levels for the 8 unclassified tools (production `ToolPolicy.swift`, no SwiftData involvement).

None of them touch `RoutineManager`, `PendingRoadmapItemsTests`, or any `ModelContext` lifetime.

---

*Investigation method: full reads of `ApexCLIRouter.swift`, `ApexCLIRouterTests.swift`, `RoutineManager.swift`, `PendingRoadmapItemsTests.swift`, `ApexAgentApp.swift`; targeted reads/greps of all managers, views, and test files referencing `RoutineManager`/`ModelContext`; and the macOS crash report `xctest-2026-10-20-132511.ips`, whose backtrace pins the stale access to `ApexCLIRouter.swift:604` from `ApexCLIRouterTests.swift:113`.*
