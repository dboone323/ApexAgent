# ApexAgent loop rules (Antigravity)

The full rules live in the repo-root `AGENTS.md`, referenced here:

@../../AGENTS.md

Core rules, in force even if the reference is not followed:

- Canonical gate: `make lint` then `make test-deep`. Gates run SOLO — check for
  running builds/gates first and wait. ALWAYS tee gate output to a fixed
  repo-root log file; report totals from the log, declaring lines vs occurrences.
- Never skip the gate (no PUSH_CI_SKIP or --no-verify), and never weaken,
  delete, skip, or gate a test or bump timeouts. Tests are add-only.
- Every task and issue is typed: [Goal], [Problem], or [Feature], with an
  objective and done criteria. Problems need red/green proof plus a regression
  test. Features must be verified live in the real product.
- Branch per task (`feat/`, `fix/`, `chore/` + slug). PR on the first commit;
  update the same PR afterwards. Never merge a PR — merges are Daniel's only.
- A failure or out-of-scope problem becomes a GitHub issue (one per distinct
  failure signature, evidence + log excerpt required). Lane WIP limits:
  1 spine, max 2 targeted-fixes, continuous unlimited.
- Contacts privacy fence: access Contacts only via ContactsOptInManager.
- Swift 6 concurrency: nonisolated methods on @MainActor cannot touch isolated
  lets; [weak self] illegal in @Sendable closures for non-Sendable Self;
  blocking work in Task.detached with Sendable captures, publish via MainActor.run.
- Standing fence: App sandbox is FALSE. Local gates are the CI.
- No secrets in code, issues, PRs, or chat.
- Verify from files, logs, and the live product — never from delegate summaries.
