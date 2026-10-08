#!/usr/bin/env bash
# Diff-scoped Swift syntax, conflict-marker, and lint gate (Batch 32).
# Lints only the .swift files changed relative to origin/main (or HEAD) in < 3s.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

BASE_REF="${BASE_REF:-origin/main}"
CHANGED_FILES=()
while IFS= read -r f; do
  if [ -n "$f" ] && [ -f "$f" ]; then
    CHANGED_FILES+=("$f")
  fi
done < <(
  {
    git diff --name-only --diff-filter=ACMRTUXB "${BASE_REF}...HEAD" -- '*.swift' 2>/dev/null || true
    git diff --name-only --diff-filter=ACMRTUXB HEAD -- '*.swift' 2>/dev/null || true
  } | sort -u
)

if [ "${#CHANGED_FILES[@]}" -eq 0 ]; then
  echo "✅ [lint] No changed .swift files relative to ${BASE_REF}."
  exit 0
fi

echo "🔎 [lint] Checking ${#CHANGED_FILES[@]} changed .swift file(s)..."

FAILED=0
for file in "${CHANGED_FILES[@]}"; do
  # 1. Check for git merge conflict markers
  if grep -nE '^(<<<<<<<|=======|>>>>>>>)' "$file"; then
    echo "❌ [lint] Merge conflict marker in $file"
    FAILED=1
  fi

  # 2. Check for leading tab indentation
  if grep -n $'^\t' "$file"; then
    echo "❌ [lint] Leading tab indentation in $file (use 4 spaces)"
    FAILED=1
  fi
done

# 3. Run swiftlint on changed files if installed
if command -v swiftlint >/dev/null 2>&1 && [ -f ".swiftlint.yml" ]; then
  swiftlint lint --quiet --config .swiftlint.yml "${CHANGED_FILES[@]}" || FAILED=1
fi

if [ "$FAILED" -ne 0 ]; then
  echo "❌ [lint] Diff-scoped Swift lint gate failed."
  exit 1
fi

echo "✅ [lint] All ${#CHANGED_FILES[@]} changed .swift file(s) passed syntax & lint checks."
