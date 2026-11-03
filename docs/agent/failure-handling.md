# Failure handling — from error to issue to PR

## When a gate, build, or test fails

1. Stop. Read the actual log file; identify the failing step and the failure signature (test name / error class / gate step).
2. Search open GitHub issues for the same signature.
   - **Found:** comment with the new evidence (run date, log excerpt, PR or branch link). Do not duplicate the issue.
   - **Not found:** file one issue — `[Problem]` title, `type: problem` + `gate-failure` + lane label; body: the exact command run, the failing step, a log excerpt, and a link to the PR or branch.
3. Warnings are different: lint warnings update the single standing `tech-debt` issue. They never spawn individual issues.
4. Report the failure as-is. Never weaken, delete, skip, or gate a test or bump timeouts to force a green run. Tests are add-only.

## Classification

- **Test failure (assertion):** a real signal until proven flaky. Flaky means: the same test passes solo twice and fails in the suite, with timings recorded in the issue.
- **Log errors with zero failed tests:** still a failure. Summary counts are not the log — scan for errors and crashes, then file.
- **Environment failure (Xcode, build lock, toolchain, network):** name the layer that failed. One bounded retry at most, then report; never retry in a loop.
- **Blocked harness / tooling:** files as its own `[Problem]` issue with reproduction and logs.

## Lane triage & WIP limits

Issues and PRs are categorized by lane:
- **`lane:spine`** — milestone spine / critical path items.
- **`lane:targeted-fix`** — scoped bug fixes and regressions.
- **`lane:continuous`** — background hygiene, ongoing automation, maintenance.

**WIP limits:**
- Exactly **1 spine** active at a time.
- Maximum **2 targeted-fixes** active concurrently.
- **continuous** tasks are unlimited.

At any WIP limit, finishing and merging active work outranks starting new work.

## Follow-ups

A new problem or defect found while working on, reviewing, or verifying a task becomes a NEW GitHub issue labeled `follow-up`, linked to the original issue. The current task's PR scope does not grow.

## Deploy and release failures

Same flow: file an issue with full log evidence, label `ops` or `gate-failure`, and stop until Daniel decides.
