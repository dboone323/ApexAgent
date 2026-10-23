# Spaces-on-VM Phase 4 — Retire the ~/ApexSandbox harness

## Step 0 inventory (~/ApexSandbox top level, pre-archive)

| Item | Disposition |
|---|---|
| `run.sh` | archived → `~/ApexSandbox/archive-2026-10-23/` |
| `watcher.py` | archived → `~/ApexSandbox/archive-2026-10-23/` |
| `task-prompt.txt` | archived → `~/ApexSandbox/archive-2026-10-23/` |
| `stop.sh` | archived → `~/ApexSandbox/archive-2026-10-23/` (old-loop VM helper) |
| `proxy.py` | archived → `~/ApexSandbox/archive-2026-10-23/` |
| `allowlist.txt` | archived → `~/ApexSandbox/archive-2026-10-23/` |
| `review-clone/` | kept (landing infrastructure) |
| `exports/` | kept (landing infrastructure) |
| `logs/` | kept |
| `SETUP_REPORT.md` | kept |
| `tasks-initial.md`, `tasks-ws6-mcp-resilience.md` | kept (records) |
| `archive-2026-10-23/` | created |

## Proxy decision

No longer needed by the Spaces-on-VM flow. Evidence: no app code references `proxy.py`, `allowlist.txt`, port 3128, or proxy env vars (`http_proxy`/`https_proxy`); `VMWorkspaceManager` runs VMs with `softnet: true` and configures no proxy. The proxy was only used by the retired `run.sh` harness for guest egress. Archived alongside the driver scripts; no in-app supervision added.

## Docs changed

- `TASK_MANIFEST.md` — added Spaces-on-VM architecture section (per-Space VMs, landing gate, harness retirement).
- `PROJECT.md` — added Spaces-on-VM architecture section.
- `SECURITY.md` — added Spaces-on-VM sandbox section (isolation, no host creds, proxy retired).

## Final ~/ApexSandbox top-level listing (post-archive)

```
SETUP_REPORT.md
archive-2026-10-23/
exports/
logs/
review-clone/
tasks-initial.md
tasks-ws6-mcp-resilience.md
```

## Gate totals

- Clean build: SUCCEEDED (0 warnings observed this run).
- Unit plan (fresh bundle `build/ApexAgent-UnitTests.xcresult`, no `APEX_LIVE_VM`): 1728 run / 1720 passed / 0 failed / 8 skipped — matches post-Phase-3 baseline.
- SwiftSyntaxLintGate solo: PASSED (3 tests).
- Live suite (`APEX_LIVE_VM=1`): TEST SUCCEEDED; post-run `tart list`: `apex-base` stopped, no `apex-space-smoke`, nothing running.

## Commit

Commit on `feat/spaces-vm`: `693482ea` — `Spaces-on-VM Phase 4: retire ApexSandbox harness, archive loop scripts, update docs`

Contains repo-side changes only: `TASK_MANIFEST.md`, `PROJECT.md`, `SECURITY.md`, `SPACES_VM_PHASE4_2026-10-23.md`. The archive moves (`run.sh`, `watcher.py`, `task-prompt.txt`, `stop.sh`, `proxy.py`, `allowlist.txt`) live outside the repo under `~/ApexSandbox/archive-2026-10-23/` and are not part of the commit.
EOF