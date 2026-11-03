# ApexAgent — Copilot instructions

Source of truth: `AGENTS.md` in this repo root. Read it before starting any
task. The non-negotiables below apply even if you read nothing else.

- Canonical gate: `make lint` then `make test-deep`. Gates run SOLO. ALWAYS
  tee gate output to a fixed repo-root log file and report totals from the log,
  never from terminal banners. Declare lines vs occurrences method for counts.
- Never skip the gate (no PUSH_CI_SKIP or --no-verify), and never weaken,
  delete, skip, or gate a test or bump timeouts. Tests are add-only.
- Every task and issue is typed: [Goal], [Problem], or [Feature], with an
  objective and done criteria. Problems need red/green proof plus a regression
  test. Features must be verified live in the real product.
- Branch per task (`feat/`, `fix/`, `chore/` + slug). PR on the first commit;
  update the same PR afterwards. Never merge a PR — merges are Daniel's only.
- A failure or out-of-scope problem becomes a GitHub issue (one per distinct
  failure signature, evidence + log excerpt required). Lane WIP limits:
  1 spine, max 2 targeted-fixes, continuous unlimited. Lint warnings roll into
  the standing tech-debt issue.
- Contacts privacy fence: access Contacts only via ContactsOptInManager.
- Swift 6 concurrency: nonisolated methods on @MainActor cannot touch isolated
  lets; [weak self] illegal in @Sendable closures for non-Sendable Self;
  blocking work in Task.detached with Sendable captures, publish via MainActor.run.
- Standing fence: App sandbox is FALSE (never change). Local gates are the CI.
- No secrets in code, issues, PRs, or chat.
- Verify from files, logs, and the live product — never from summaries.
