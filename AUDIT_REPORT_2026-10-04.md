# ApexAgent Deep Audit — 2026-10-04

## Executive verdict

**Release readiness remains conditional.** ApexAgent builds and launches on the target macOS 27 toolchain. The initial audit found broken test-plan registration, test instability, a Settings termination, unsafe Gemini credential tests, and a CLI tool-policy failure. The remediation and current verification status are summarized below; the original findings remain as an audit trail.

## Remediation status

| Priority area | Status after remediation |
|---|---|
| P1 — Xcode test-plan registration | **Fixed.** `xcodebuild -showTestPlans` lists both `ApexAgent-UnitTests` and `ApexAgent-UITests`. |
| P1 — Credential handling and test isolation | **Fixed and verified.** Plaintext Gemini preference fallback/write removed; migrations retain sources if Keychain persistence fails. Tests use PID-scoped Keychain and `.apex` storage roots; the full unit plan passes. |
| P1 — Settings gear termination | **Not reproduced in the live retest.** The real toolbar gear opened one Settings sheet, Done closed it, and the app stayed running. The focused test still skips the toolbar case; the complete XCUITest plan also has separate unresolved chat-composer discovery failures. |
| P1 — Regression failures | **Both full test gates passed.** The final Xcode unit plan passed 133 XCTest cases, 502 Swift Testing cases in 92 suites, 71 intelligence cases, and 7 container cases (713 total). The SwiftPM gate passed 602 tests in 102 suites, 71 intelligence tests, and 7 container tests (680 total) after isolating live MCP homes, per-instance gateway tokens, and manager/TraceBus state. |
| P1 — CLI tool policy | **Fixed and live-tested.** Tools are disabled by default; a real on-device CLI prompt returned the exact requested output and reported no tool calls. Empty `--cli` exits 64 with usage text. |
| P2 — Provider alias and peer approvals | **Fixed.** `appleFoundation` is recognized; remembered grants are scoped to sender + action + target; approval cards support deny/allow and stale-request expiry. |
| P2 — Settings Skills environment | **Fixed.** Settings and the Skills section render in the SwiftUI hosting test using the dedicated Skills environment key. |
| P3 — Provider timing/progress | **Added/verified.** Provider attempts emit duration-only structured logs; existing streaming and generating indicators provide user-visible progress without exposing prompt or error text in logs. |
| P2 — Release signing/distribution | **Partially verified.** The Release configuration builds successfully. Developer ID signing, notarization, external installation, and full privileged-surface review remain release gates. |

## Important test-safety disclosure

The existing `RuntimeContractTests.testGeminiAPIKeyKeychainMigration` is not isolated from the logged-in user's credentials. It writes a generated key to `~/.apex/gemini_key`, deletes the `geminiAPIKey` Keychain item and then fails before its expected migration/cleanup. During this audit it left its generated fixture in that path and an empty Keychain item. I compared the file privately against the generated test fixture, removed that fixture, and removed the test-created empty Keychain item without displaying any credential value.

The test deleted the Keychain item before the audit could know whether one existed. **I cannot determine whether a pre-existing Gemini key was removed or a prior `~/.apex/gemini_key` file was overwritten.** If Gemini was configured before this audit and is now unavailable, re-enter the key in ApexAgent Settings. The migration test has since been rewritten to use an isolated temporary file and unique Keychain account; it does not recover any credential that may have been lost during the original audit.

A later review found that `RuntimeContractTests.testA2ABearerAuthentication` also wrote to and deleted the fixed `a2aAuthToken` Keychain account. I stopped the in-flight full test run immediately; its interrupted output did not identify which test was active, so I cannot confirm whether this case ran or whether an existing A2A token was affected. Test processes now use a separate PID-scoped Keychain service, and the test uses deferred cleanup. If A2A authentication stopped working after the audit, re-enter its token in the app.

The first isolated intelligence-target run (after Keychain isolation but before app-data isolation) enumerated manifests from the developer's `~/.apex/skills` directory. No evidence showed those user scripts being executed. It also exercised durable memory with a random test bot ID and may have left a test episode and audit metadata in the normal `~/.apex` store. Existing matching memory records prevent safely attributing one directory to this run; I did not delete or rewrite user memory. Subsequent runs use a PID-scoped temporary root for Keychain, dynamic tools/skills, memory, audit records, sandbox files, and related state; dynamic-script tests still create and execute real shell fixtures there.

## Environment and validation

- Host: Apple Silicon MacBook Pro; macOS 27.2
- Toolchain: Xcode 27.2 (27B5028f), Swift 6.4
- XcodeBuildMCP: 2.7.0; `xcodebuildmcp tools` listed 72 canonical / 100 total tools

| Check | Result |
|---|---|
| XcodeBuildMCP Debug build | **Passed**; build completed in 53.6s |
| App bundle identity | **Passed**; `com.apexagent.ApexAgent` |
| App launch | **Passed**; launch reported PID 83047; process remained alive several minutes, with no new ApexAgent crash report observed |
| Initial XcodeBuildMCP test run (baseline) | **Incomplete / failed**; discovered 841 tests, reported the first 133 complete with no failures, then stopped advancing. An `xctest` crash report named `ComprehensiveBotCapabilitiesTests.testBotSessionConversationPersistsAcrossRelaunch` and showed an array-subscript trap at its assertion. A later attempt was stopped when review found the fixed-account A2A Keychain test. |
| Isolated persistence test | **Passed** once with SwiftPM and once with `xcodebuild`; the final complete Xcode unit plan also passed. |
| Final full Xcode unit plan | **Passed** sequentially with exit code 0: 133 XCTest cases, 502 Swift Testing cases in 92 suites, 71 intelligence tests, and 7 container tests (713 total). No failing tests were reported. |
| Final full SwiftPM gate (`make test`) | **Passed** with exit code 0: 602 tests in 102 suites, 71 tests in 11 suites, and 7 container tests. The two documented FoundationModels timeout cases were reported as known issues; the suite completed successfully. |
| Release Xcode build | **Passed** with exit code 0 for the macOS Release configuration. This confirms compilation only; Developer ID signing, notarization, and external installation remain unverified. |
| Settings UI-test selector | **Passed with 1 explicit skip, 0 failures.** The test documents the XCTest toolbar limitation; the live Settings gear and Done behavior were verified separately through System Events. |
| Full Xcode UI test plan (before latest test-surface corrections) | **Failed:** 8 passed, 18 failed, 3 skipped. Most failures stop in shared setup because XCTest cannot find `chatInputField` after opening a new conversation. The bot-selection failure was caused by missing sidebar accessibility identifiers; the focused bot-switch test passed after those identifiers were added. The focused chat-input test still fails after switching to a universal accessibility query and clicking the New Conversation toolbar item. The app launches and remains alive outside the UI runner; this UI-state/accessibility path remains unresolved. |
| Isolated intelligence target | **Passed twice** with 71 tests in 11 suites. The first run preceded app-data isolation and is covered by the safety disclosure above; the second passed with isolation. |
| Earlier full SwiftPM run | **Failed at baseline** before remediation completed. It reported 71 Swift Testing tests across 11 suites with 8 issues (including 2 known model timeouts); separately, the `ApexAgentTests` helper exited with signal 5 after a SwiftUI fatal error because a hosted view had no `BotManager` environment object. The final SwiftPM gate now passes after the fixes described below. |
| Initial XCTest plan invocation | **Failed at baseline**, because the generated scheme did not register test plans. The scheme now registers both plans; `xcodebuild -showTestPlans` lists them. |
| Initial app CLI smoke prompt | **Failed at baseline**; the no-tools policy was subsequently implemented and a live on-device prompt passed with the exact output and no tool calls. Empty CLI input exits 64. |
| Manual UI testing | Same-day observations are recorded in [BETA_TEST_2026-10-04.md](./BETA_TEST_2026-10-04.md). The live Settings gear and Done action were verified with System Events; the XCTest toolbar case is explicitly skipped due to the macOS 27 host limitation. |
| GitHub Actions history | `gh run list` returned no runs for `main`; there is no recent remote result to use as an independent green signal. |

## Findings — ordered by release risk

### P1 — Fix before release

1. **Resolved — Xcode test-plan registration.** The baseline shared scheme did not register plans, so the documented `-testPlan` command failed. The plans are now registered through [project.yml](./project.yml); `xcodebuild -showTestPlans` lists both, and the full unit plan passes.

2. **Resolved in code — Gemini Keychain handling and destructive migration coverage.** [ModelRegistry.swift](./ApexAgent/Models/ModelRegistry.swift) no longer writes or falls back to plaintext preferences and migrates supported legacy sources without deleting them until a Keychain write succeeds. [KeychainManager.swift](./ApexAgent/Models/KeychainManager.swift) test operations use a PID-scoped service. [RuntimeContractTests.swift](./ApexAgentIntelligenceTests/RuntimeContractTests.swift) uses isolated fixtures and asserts that test storage is separate. The original run's possible credential loss remains unresolved as described above.

3. **Resolved/not reproduced — Settings gear termination.** The initial Debug UI pass saw the app disappear after clicking the gear. In the live retest the real gear opened exactly one Settings sheet, Done closed it, and the app remained running. The focused XCTest selector builds and reports the toolbar limitation as a skip, not as a pass. The original observation is documented in [BETA_TEST_2026-10-04.md](./BETA_TEST_2026-10-04.md).

4. **Resolved for both full test gates.** The initial Xcode run stalled after 133 of 841 discovered tests and produced an array-bounds crash report. Follow-up found outdated expectations for authenticated gateway broadcasts, tests placing scripts outside the hardened dynamic-tool roots, and test data touching user directories. Parallel SwiftPM runs also exposed shared test state: MCP clients reused one mutable `npx` home, gateway tests raced through a fixed Keychain token, and manager/trace tests used global singletons. The tests now use per-client temporary homes, per-instance gateway tokens, isolated non-persisting manager instances, and a local TraceBus for stress coverage. The final Xcode unit plan passed 713 test cases, and the SwiftPM gate passed 680 tests. The earlier SwiftPM run failed with:
   - a fatal missing `BotManager` environment object in `testBotChatViewPlaybookApprovalBannerResolution`;
   - an alias expectation failure (`ModelProvider.parse("appleFoundation")`);
   - an `AskBotTool` peer-approval expectation failure;
   - a bubble-orientation test comparing `Path.description` values that were equal;
   - provider-chain priority assertions expecting zero-based priorities while the implementation assigns priorities starting at 1;
   - the Gemini key migration failures described above.

   Those baseline SwiftPM findings were corrected. Two intelligence tests still hit the known macOS 27 FoundationModels 40-second timeouts; Swift Testing records them as known issues, and the gate exits successfully. The Release configuration now builds, but signing, notarization, distribution, and broader UI acceptance are still open.

5. **Resolved — one-shot CLI tool-policy failure.** The baseline exact-response probe attempted `send_notification` despite a no-tools instruction. CLI prompts now default to no tools, `--allow-tools` opts in, `--no-tools` overrides, and empty prompts exit 64. The live on-device no-tools probe returned the exact requested response with no tool calls.

### P2 — Address before broad beta

6. **Provider CLI alias coverage disagreed with implementation.** The alias `appleFoundation` is now supported and its contract test passes.

7. **Peer-approval behavior was strengthened and targeted-tested.** Pending requests are surfaced in the sender's chat; deny settles the request, allow dispatches the saved request, and remembered grants are scoped to the sender/action/target tuple. The expiry path is covered by coordinator tests.

8. **Privileged app surface needs a release security review.** [ApexAgent.entitlements](./ApexAgent/ApexAgent.entitlements) disables App Sandbox and grants network client/server, Apple Events, user-selected/download file access, app-group, and virtualization capabilities. These may be required for the product, but combined with shell, filesystem, and computer-control tools they create a large consequence radius. Keep confirmation policy consistent across all dispatch paths, test it in a Release-signed build (Debug auto-approves), and consider isolating high-risk operations in a narrowly entitled helper.

9. **UI automation and several UI flows remain unresolved or unverified.** The live Settings gear opened Settings and Done closed it while the app remained running. Before the latest test-surface corrections, the full XCUITest plan reported 8 passed, 18 failed, and 3 skipped; most failures shared the inability to find `chatInputField` after requesting a new conversation. The multi-bot selector test passes after adding the missing sidebar accessibility identifiers, but the focused composer test still fails. The original page-delete observation was incorrect; page deletion already exists in the page context menu and toolbar trash action in `SpacesViews.swift`. File > New Conversation, Compose, full attachment send, bot deletion, popup options, playbook approval/deny, and invite flows still need UI acceptance coverage.

10. **Distribution readiness is partially verified.** Both Debug and Release configurations build, but this audit did not verify Developer ID signing, notarization, or an external-install path. No recent Actions runs were found. These remain pre-distribution gates if the intended beta is outside local development.

### P3 — Improve

11. **On-device multi-agent latency is high on this beta.** The SwiftPM output measured a single on-device/PCC prompt at about 42.8 seconds; meeting and delegation tests each exceeded their 40-second allowance and were marked as known OS regressions. Provider-attempt duration telemetry is now logged without prompt content; existing streaming and generating indicators provide user-visible progress. Re-baseline once the macOS 27 FoundationModels issue is resolved.

12. **CLI tool behavior is now explicit.** One-shot CLI prompts default to no tools and disable dynamic script loading. `--allow-tools` opts in, `--no-tools` overrides it, and an empty prompt returns a usage error. The on-device live smoke test confirmed the exact response and no tool calls.

## What worked

- The macOS 27.2 Debug app compiled, produced the expected bundle ID, and stayed running after launch.
- The persistence case implicated by the full Xcode crash passed in isolation under both SwiftPM and Xcode.
- SwiftPM passed multiple system-tool, filesystem, gateway, memory, UI-rendering, and concurrency tests before the failing cases; the `ToolSuiteTests` and project-management tests shown in the run passed.
- The same-day manual UI report records successful basic chat, thread reply, page creation/rename, memory save/discard, bot edit/pin, terminal and diagnostics panels, and syncing a newly created bot into a space.
- In the earlier live team check-in documented by [AUDIT_MULTIAGENT_2026-10-02.md](./AUDIT_MULTIAGENT_2026-10-02.md), nine bots responded in order without visible cross-talk. Optional Ollama/MLX providers were unavailable in that test environment, while the error display worked.
- A targeted scan found no obvious hard-coded API-key/password literals in the application/tool source. This is not a substitute for a dedicated secret scan.

## Recommended order of work

1. Diagnose why the XCUITest launch path does not expose the chat composer after New Conversation, then rerun the full UI plan.
2. Complete Release-build confirmation-gate tests and Developer ID signing/notarization/distribution validation.
3. Re-baseline the two on-device FoundationModels timeouts after the macOS 27 regression is resolved; expand acceptance coverage for the remaining flows.
