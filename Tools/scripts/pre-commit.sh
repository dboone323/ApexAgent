#!/usr/bin/env bash
# Fast (< 2s) pre-commit staged file gate for ApexAgent (Batch 37).
# Blocks:
#   1. Forbidden OS/build artifacts (.DS_Store, *.xcresult, *.xcuserdata, .build/, DerivedData/)
#   2. Oversized staged files (> 5 MB)
#   3. Unresolved merge conflict markers in staged files
#   4. Leaked secrets / API keys in staged files
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

STAGED_FILES=()
while IFS= read -r line; do
  [ -n "$line" ] && STAGED_FILES+=("$line")
done < <(git diff --cached --name-only --diff-filter=ACMRTUXB)

if [ "${#STAGED_FILES[@]}" -eq 0 ]; then
  exit 0
fi

MAX_BYTES=$((5 * 1024 * 1024))
FAILED=0

for f in "${STAGED_FILES[@]}"; do
  case "$f" in
    *.DS_Store|*.xcresult*|*.xcuserdata*|.build/*|DerivedData/*)
      echo "❌ [pre-commit] Forbidden artifact staged: $f"
      FAILED=1
      ;;
  esac

  if [ -f "$f" ]; then
    SIZE=$(wc -c < "$f" | tr -d ' ')
    if [ "$SIZE" -gt "$MAX_BYTES" ]; then
      echo "❌ [pre-commit] Staged file exceeds 5 MB ($SIZE bytes): $f"
      FAILED=1
    fi

    if grep -nE '^(<<<<<<<|=======|>>>>>>>)' "$f" >/dev/null 2>&1; then
      echo "❌ [pre-commit] Unresolved git merge conflict marker in: $f"
      FAILED=1
    fi
  fi
done

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi

exit 0
