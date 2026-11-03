# Standard task template

Every dispatched task is expanded into this shape before it reaches an agent.

## Header

**Type:** Goal / Problem / Feature
**Objective:** one sentence
**Done when:** the checkable end state

## Context

The goal, repo state (branch / HEAD commit SHA), relevant files, architectural constraints (macOS 27.0, Swift 6.4, Xcode 27.2, ad-hoc signing, App Sandbox FALSE), and prior decisions the agent cannot see from the repo alone.

## Scope

- **In:** exactly what this task covers.
- **Out:** everything else. Out-of-scope finds become GitHub issues with evidence, not extra work in the current PR.

## Acceptance criteria

Observable, testable statements.
- For a **Goal**: verifiable proof that the target end state exists and holds.
- For a **Problem**: the red/green pair that proves the defect (failing test or reproduction first, then passing), plus a regression test and a green gate.
- For a **Feature**: live behavior verified in the real product (running app/UI/CLI), plus automated tests and a green gate.

## Gate sequence (mandatory ending)

1. Targeted tests for the changed area.
2. Live smoke where applicable (real macOS UI / CLI execution).
3. Canonical gate: `make lint` then `make test-deep`, run SOLO (no overlapping runs).
4. Output ALWAYS tee'd to a fixed repo-root log file.
5. Totals and counts read directly from that log (declaring lines-vs-occurrences method), never from terminal banners or memory.

## Report format

- Base SHA and branch.
- Files changed and byte sizes.
- Gate totals recomputed from the raw log (declaring lines vs occurrences method).
- Log scan: errors and crashes counted separately from test failures.
- Live verification proof / screenshots / CLI outputs where applicable.
- Leftovers and scope check: anything found but not done, with its follow-up issue number.

## Git

Branch per task (`feat/`, `fix/`, `chore/` + slug); PR on the first commit; update the same PR with later commits; no agent merges (Daniel merges only); `Fixes #n` or `Refs #n` in PR body. Always `git --no-pager`, bounded output, bounded-timeout pushes. Pre-push hooks must pass (never use `PUSH_CI_SKIP` or `--no-verify`).
