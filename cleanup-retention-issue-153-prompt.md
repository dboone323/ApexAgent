# Cline task — ApexAgent issue #153 (Problem)

Run in Act mode with auto-approve on. Use a free model only (cline-free/ or reflection/ model ids) — never click Add Credits or usage-based billing.

## Issue
https://github.com/dboone323/ApexAgent/issues/153 — "[Problem] ApexAgent test gates leave ApexAgent-TestData folders in $TMPDIR — 158 folders / 23 GiB and growing", updated with Daniel's retention policy: important artifacts 30 days, rinse-and-repeat artifacts (per-gate test results, temp test data) 7 days, older removed as newer arrives. Read the full issue body with `gh issue view 153` before starting — it is the spec.

## Objective
Implement the retention system from the issue so test gates stop leaking disk:
1. $TMPDIR/ApexAgent-TestData-<pid>/.apex (DynamicToolbox.swift): delete-on-process-exit in the harness, with a 7-day sweep as backstop. A sweep must NEVER delete a folder belonging to a live PID.
2. <project>/runs/gate-queue/: 7 days for .log, .log.done, .completed.json; 30 days for -report.md and -stale-recovery.md. Never delete .in-progress.json or a job with no .done sentinel.
3. <project>/runs/ (other): 30 days for reports/summaries, 7 days for raw logs.
4. scripts/rotate-test-logs.sh: change the 30-day threshold to 7 days. Verify the LaunchAgent (scripts/com.apexagent.testlog-rotate.plist) is actually loaded on this Mac (`launchctl list | grep apexagent`); if it is not loaded, load it and say so in the report.
5. build/*.xcresult: wire the dormant --prune / PRUNE=1 branch in Tools/scripts/xcresult-report.sh into the Makefile targets, or drop it — do not leave a dead path.
6. ~/Library/Developer/Xcode/DerivedData + .build/: 7-day stale purge (rebuildable cache). Never purge while a gate is running.
7. Docker/container leftovers: check `docker ps -a` and `docker system df` on this Mac first and report what you find; only then decide what the retention call is. Do not delete containers or images you cannot attribute to this project.

## Done criteria (all must be true)
- After a full gate, no new ApexAgent-TestData folder remains in $TMPDIR (including on failure/cancellation), and a follow-up gate leaves the TestData count unchanged.
- Gate-queue and runs/ split 7-day logs / 30-day reports is in place.
- rotate-test-logs at 7 days with the LaunchAgent verified loaded.
- DerivedData + .build/ stale purge in place.
- Dormant xcresult prune wired or dropped.
- Full gate green (make test-deep), no new warnings.

## Rules
- Real fixes only — no placeholders, stubs, or mocks.
- Work on a new branch; open a PR (one PR for this change, no stacked PRs) and report the PR URL + head SHA. Do NOT merge — merging is Monarch's step after verification.
- NEVER auto-delete: sources, committed test fixtures, Package.resolved, any file tracked in git; ~/.apex user stores / Keychain-backed state (in-app logic only); runs/gate.lock.d (stale locks are reported, never broken); any gate-queue .in-progress.json or job file with no .done sentinel; the closed HavenWorld-agent-work archive.
- One gate at a time on this Mac: before starting any gate/test run, check `pgrep -x xcodebuild` (never `pgrep -f`) — if a gate is running, wait for it to finish before starting yours. Never run two gates at once.
- Long runs: write a fixed-path log plus a <log>.done sentinel (exit code + timestamp) on completion; wait in ONE blocking call sized to the run — do not poll in short cycles. Checkpoint your report at phase boundaries and write the completion section last.
- Do not touch, stash, or clean any unrelated pending changes in this checkout.
- When finished, report: PR URL + head SHA, gate totals, and what you verified for each done criterion.
