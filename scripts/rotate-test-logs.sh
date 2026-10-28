#!/usr/bin/env bash
# Rotate per-test append logs in a given directory.
# Usage: rotate-test-logs.sh <log-dir>

set -u

LOG_DIR="${1:-}"
if [[ -z "$LOG_DIR" ]]; then
    echo "usage: $0 <log-dir>" >&2
    exit 2
fi
if [[ ! -d "$LOG_DIR" ]]; then
    echo "log dir not found: $LOG_DIR" >&2
    exit 2
fi

MAX_BYTES=$((5 * 1024 * 1024))
NOW=$(date +%s)
ONE_HOUR=$((60 * 60))
THIRTY_DAYS=$((30 * 24 * 60 * 60))

acted=0
for f in "$LOG_DIR"/*.log; do
    [[ -e "$f" ]] || continue
    mtime=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null)
    age=$((NOW - mtime))
    # skip files modified in last hour
    if (( age < ONE_HOUR )); then
        continue
    fi
    size=$(stat -f %z "$f" 2>/dev/null || stat -c %s "$f" 2>/dev/null)
    if (( age > THIRTY_DAYS )); then
        rm -f "$f"
        echo "deleted (old): $f"
        acted=$((acted + 1))
        continue
    fi
    if (( size > MAX_BYTES )); then
        tmp="${f}.rotating.$$"
        tail -n 2000 "$f" > "$tmp" && mv "$tmp" "$f"
        echo "truncated (>${MAX_BYTES} bytes): $f"
        acted=$((acted + 1))
        continue
    fi
done

echo "summary: acted on $acted file(s) in $LOG_DIR"
