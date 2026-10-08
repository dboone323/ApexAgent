#!/usr/bin/env bash
# Git commit-msg hook enforcing Conventional Commits for ApexAgent (Batch 37).
set -euo pipefail

MSG_FILE="${1:-}"
if [ -z "$MSG_FILE" ] || [ ! -f "$MSG_FILE" ]; then
  echo "Usage: $0 <commit-msg-file>"
  exit 1
fi

HEADER=$(grep -vE '^\s*#' "$MSG_FILE" | sed '/^\s*$/d' | head -n 1 || true)
if [ -z "$HEADER" ]; then
  echo "❌ [commit-msg] Commit message header cannot be empty."
  exit 1
fi

# Allow Merge and Revert commits
if echo "$HEADER" | grep -Eq '^(Merge |Revert ")'; then
  exit 0
fi

if ! echo "$HEADER" | grep -Eq '^(feat|fix|chore|refactor|test|docs|ci|perf|build|revert|style)(\([^)]+\))?!?: .{4,}'; then
  echo "❌ [commit-msg] Invalid Conventional Commit header:"
  echo "   $HEADER"
  echo "Expected: <type>[optional (scope)]: <subject> (types: feat, fix, chore, refactor, test, docs, ci, perf, build, revert, style)"
  exit 1
fi

exit 0
