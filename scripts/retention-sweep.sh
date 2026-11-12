#!/usr/bin/env bash
# Retention sweep — test-gate hygiene (§153).
#
# Retention policy (Daniel, Nov 12 2026):
#   Important artifacts:        30 days
#   Rinse-and-repeat artifacts: 7 days
#
# Sweeps three locations:
#   1. runs/gate-queue/  — 7 days for .log / .log.done / .completed.json
#                          30 days for -report.md / -stale-recovery.md
#                          NEVER delete .in-progress.json or a job with no .done sentinel
#   2. runs/ (other)     — 30 days for reports/summaries, 7 days for raw logs
#   3. DerivedData + .build/ — 7-day stale purge (never while a gate is running)
#
# Usage: retention-sweep.sh [--project <path>] [--skip-derived-data] [--skip-build]
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKIP_DERIVED_DATA=0
SKIP_BUILD=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project)
            PROJECT_DIR="$2"; shift 2 ;;
        --skip-derived-data)
            SKIP_DERIVED_DATA=1; shift ;;
        --skip-build)
            SKIP_BUILD=1; shift ;;
        *)
            echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
NOW=$(date +%s)
SEVEN_DAYS=$((7 * 24 * 60 * 60))
THIRTY_DAYS=$((30 * 24 * 60 * 60))

# Temp files for live/done job tracking (avoids bash associative arrays).
LIVE_JOBS_FILE="$(mktemp)"
DONE_JOBS_FILE="$(mktemp)"
trap 'rm -f "$LIVE_JOBS_FILE" "$DONE_JOBS_FILE"' EXIT

# Gate-running guard: never purge DerivedData/.build while a gate is running.
gate_running() {
    pgrep -x xcodebuild >/dev/null 2>&1
}

# age_seconds <file> — age in seconds since mtime, or -1 on error.
age_seconds() {
    local f="$1"
    local mtime
    mtime=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null) || { echo -1; return; }
    echo $((NOW - mtime))
}

# delete_if_old <file> <max_age_seconds> <label>
delete_if_old() {
    local f="$1" max_age="$2" label="$3"
    local age
    age=$(age_seconds "$f")
    [[ "$age" -lt 0 ]] && return 0
    if [ "$age" -gt "$max_age" ]; then
        rm -f "$f"
        echo "deleted $label ${age}s old: $f"
    fi
}

# is_live_job <base_path> — true if job has an .in-progress.json file.
is_live_job() {
    local base="$1"
    grep -qF -- "${base}.in-progress.json" "$LIVE_JOBS_FILE" 2>/dev/null || true
}

# is_done_job <base_path> — true if job has a .log.done sentinel.
is_done_job() {
    local base="$1"
    grep -qF -- "${base}.log.done" "$DONE_JOBS_FILE" 2>/dev/null || true
}

echo "============================================================"
echo " §153 Retention Sweep"
echo " Project: $PROJECT_DIR"
echo " Now:     $(date)"
echo "============================================================"

# ──────────────────────────────────────────────────────────────
# 1. runs/gate-queue/
# ──────────────────────────────────────────────────────────────
GATE_QUEUE="$PROJECT_DIR/runs/gate-queue"
if [[ -d "$GATE_QUEUE" ]]; then
    echo ""
    echo "-- runs/gate-queue/ --"

    # Collect live jobs (have .in-progress.json) — never touch these.
    : > "$LIVE_JOBS_FILE"
    while IFS= read -r -d '' f; do
        echo "$f" >> "$LIVE_JOBS_FILE"
    done < <(find "$GATE_QUEUE" -maxdepth 1 -name '*.in-progress.json' -print0 2>/dev/null || true)

    # Collect completed jobs (have .log.done sentinel).
    : > "$DONE_JOBS_FILE"
    while IFS= read -r -d '' f; do
        echo "$f" >> "$DONE_JOBS_FILE"
    done < <(find "$GATE_QUEUE" -maxdepth 1 -name '*.log.done' -print0 2>/dev/null || true)

    # Process each completed job that is not live.
    while IFS= read -r -d '' done_file; do
        base="${done_file%.log.done}"

        # Skip live jobs (have .in-progress.json).
        if grep -qF -- "${base}.in-progress.json" "$LIVE_JOBS_FILE" 2>/dev/null; then
            continue
        fi

        # 7 days: .log, .log.done, .completed.json
        for ext in .log .log.done .completed.json; do
            f="${base}${ext}"
            [[ -e "$f" ]] || continue
            delete_if_old "$f" "$SEVEN_DAYS" "gate-queue/7d"
        done

        # 30 days: -report.md, -stale-recovery.md
        for suffix in -report.md -stale-recovery.md; do
            f="${base}${suffix}"
            [[ -e "$f" ]] || continue
            delete_if_old "$f" "$THIRTY_DAYS" "gate-queue/30d"
        done

        # .stale-recovered.json — recovered job spec, audit trail → 30 days
        f="${base}.stale-recovered.json"
        [[ -e "$f" ]] || continue
        delete_if_old "$f" "$THIRTY_DAYS" "gate-queue/30d"

    done < <(find "$GATE_QUEUE" -maxdepth 1 -name '*.log.done' -print0 2>/dev/null || true)

    # Standalone -stale-recovery.md not tied to a .done sentinel → 30 days
    while IFS= read -r -d '' f; do
        delete_if_old "$f" "$THIRTY_DAYS" "gate-queue/30d"
    done < <(find "$GATE_QUEUE" -maxdepth 1 -name '*-stale-recovery.md' -print0 2>/dev/null || true)

    # Standalone -stale-recovered.json not tied to a .done sentinel → 30 days
    while IFS= read -r -d '' f; do
        delete_if_old "$f" "$THIRTY_DAYS" "gate-queue/30d"
    done < <(find "$GATE_QUEUE" -maxdepth 1 -name '*-stale-recovered.json' -print0 2>/dev/null || true)
else
    echo ""
    echo "-- runs/gate-queue/ not found (skip) --"
fi

# ──────────────────────────────────────────────────────────────
# 2. runs/ (other) — 30 days reports/summaries, 7 days raw logs
# ──────────────────────────────────────────────────────────────
RUNS_DIR="$PROJECT_DIR/runs"
if [[ -d "$RUNS_DIR" ]]; then
    echo ""
    echo "-- runs/ (other) --"

    # 7 days: raw logs (*.log) — skip .done sentinels, skip gate-queue
    while IFS= read -r -d '' f; do
        case "$f" in
            */gate-queue/*) continue ;;
        esac
        delete_if_old "$f" "$SEVEN_DAYS" "runs/logs/7d"
    done < <(find "$RUNS_DIR" -maxdepth 1 -name '*.log' -print0 2>/dev/null || true)

    # 30 days: reports/summaries (*-report.md, *-brief.md, *-summary.md)
    # Never delete .done sentinels or directories.
    while IFS= read -r -d '' f; do
        case "$f" in
            */gate-queue/*) continue ;;
            *.done) continue ;;
        esac
        delete_if_old "$f" "$THIRTY_DAYS" "runs/reports/30d"
    done < <(find "$RUNS_DIR" -maxdepth 1 \( -name '*-report.md' -o -name '*-brief.md' -o -name '*-summary.md' \) -print0 2>/dev/null || true)
else
    echo ""
    echo "-- runs/ not found (skip) --"
fi

# ──────────────────────────────────────────────────────────────
# 3. DerivedData + .build/ — 7-day stale purge (never during gate)
# ──────────────────────────────────────────────────────────────
if gate_running; then
    echo ""
    echo "-- DerivedData/.build SKIPPED -- gate (xcodebuild) is running --"
else
    # ~/Library/Developer/Xcode/DerivedData
    if [[ $SKIP_DERIVED_DATA -eq 0 ]]; then
        DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"
        if [[ -d "$DERIVED_DATA" ]]; then
            echo ""
            echo "-- DerivedData --"
            while IFS= read -r -d '' f; do
                delete_if_old "$f" "$SEVEN_DAYS" "DerivedData/7d"
            done < <(find "$DERIVED_DATA" -maxdepth 1 -mindepth 1 -print0 2>/dev/null || true)
        fi
    fi

    # <project>/.build/ (SPM)
    if [[ $SKIP_BUILD -eq 0 ]]; then
        BUILD_DIR="$PROJECT_DIR/.build"
        if [[ -d "$BUILD_DIR" ]]; then
            echo ""
            echo "-- .build/ --"
            while IFS= read -r -d '' f; do
                delete_if_old "$f" "$SEVEN_DAYS" ".build/7d"
            done < <(find "$BUILD_DIR" -maxdepth 1 -mindepth 1 -print0 2>/dev/null || true)
        fi
    fi
fi

echo ""
echo "============================================================"
echo " §153 Retention Sweep complete"
echo "============================================================"
