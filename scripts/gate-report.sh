#!/usr/bin/env bash
set -uo pipefail

# Ensure homebrew binaries like gh and standard utilities are accessible
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <logfile> <step-name> <exit-code>"
  exit 1
fi

LOGFILE="$1"
STEP_NAME="$2"
EXIT_CODE="$3"

# If exit-code is 0: print a one-line confirmation and exit 0 (files nothing).
if [[ "$EXIT_CODE" -eq 0 ]]; then
  echo "✅ Gate step '${STEP_NAME}' passed (exit code 0). No issue filed."
  exit 0
fi

echo "⚠️ Gate step '${STEP_NAME}' failed with exit code ${EXIT_CODE}. Analyzing log: ${LOGFILE}..."

# Extract failing test names from the log
# Checks for xcodebuild Failing tests block, Swift Testing failure markers, and XCTest failures
extract_failing_tests() {
  local log="$1"
  local tests=""

  if [[ ! -f "$log" ]]; then
    return
  fi

  # 1. Try xcodebuild "Failing tests:" section
  if grep -q "Failing tests:" "$log" 2>/dev/null; then
    tests=$(awk '
      /Failing tests:/ { flag=1; next }
      /(\*\* TEST FAILED \*\*|^$)/ { if (flag) flag=0 }
      flag {
        gsub(/^[ \t]+|[ \t]+$/, "", $0)
        if (length($0) > 0) print $0
      }
    ' "$log")
  fi

  # 2. If empty, check for Swift Testing (✘ Test ...) or XCTest (Test case ... failed) lines
  if [[ -z "$tests" ]]; then
    tests=$(grep -E '(✘ Test |Test case .*\ failed)' "$log" 2>/dev/null | \
      sed -E "s/.*✘ Test ([^ (]+).*/\1/; s/.*Test case '([^']+)' failed.*/\1/" | \
      grep -v '^$' || true)
  fi

  # Sort and deduplicate
  if [[ -n "$tests" ]]; then
    echo "$tests" | sort -u
  fi
}

FAILING_TESTS=$(extract_failing_tests "$LOGFILE")

# Signature calculation:
# Signature = step name + sorted failing test names, hashed (shasum) to <=12 chars.
# If no test names (e.g. lint failure), signature falls back to the step name (hashed to <=12 chars).
if [[ -n "$FAILING_TESTS" ]]; then
  SIG_INPUT="${STEP_NAME}"$'\n'"${FAILING_TESTS}"
else
  SIG_INPUT="${STEP_NAME}"
fi

SIG=$(printf "%s" "$SIG_INPUT" | shasum -a 256 | awk '{print $1}' | cut -c1-12)
TITLE="[Problem] Gate failure: ${STEP_NAME} (${SIG})"

echo "Signature: ${SIG}"
echo "Title: ${TITLE}"

# Dedupe: gh issue list --search "<sig>" --state open — if a match exists, print its URL and exit 0 without filing.
EXISTING_URL=$(gh issue list --search "$SIG" --state open --json url --jq '.[0].url // empty' 2>/dev/null || true)

if [[ -n "$EXISTING_URL" ]]; then
  echo "ℹ️ Dedupe match found! An open issue already exists for signature ${SIG}: ${EXISTING_URL}"
  echo "Skipping issue creation (exit 0)."
  exit 0
fi

# Build log excerpt: the failing block plus ~30 lines of context, fenced
get_log_excerpt() {
  local log="$1"
  if [[ ! -f "$log" ]]; then
    echo "Log file not found: $log"
    return
  fi

  local match_line=""
  # Prefer line of Failing tests: or ** TEST FAILED **
  match_line=$(grep -n "Failing tests:" "$log" 2>/dev/null | tail -n 1 | cut -d: -f1 || true)
  if [[ -z "$match_line" ]]; then
    match_line=$(grep -n "\*\* TEST FAILED \*\*" "$log" 2>/dev/null | tail -n 1 | cut -d: -f1 || true)
  fi

  if [[ -n "$match_line" ]]; then
    local start_line=$(( match_line > 30 ? match_line - 30 : 1 ))
    local end_line=$(( match_line + 50 ))
    sed -n "${start_line},${end_line}p" "$log"
  else
    # Fallback: last 60 lines of log (for lint or other non-test failures)
    tail -n 60 "$log"
  fi
}

EXCERPT=$(get_log_excerpt "$LOGFILE")

if [[ -n "$FAILING_TESTS" ]]; then
  FORMATTED_TESTS=""
  while IFS= read -r t; do
    [[ -n "$t" ]] && FORMATTED_TESTS="${FORMATTED_TESTS}- \`${t}\`"$'\n'
  done <<< "$FAILING_TESTS"
else
  FORMATTED_TESTS="No individual test names extracted (lint or step failure)."$'\n'
fi

# Construct issue body conforming to AGENTS.md typed Problem format
# Keep body under ~6,000 chars
BODY=$(cat <<EOF
## Type: Problem

**Objective:** Investigate and resolve canonical gate failure in step \`${STEP_NAME}\`.
**Done when:** Step \`${STEP_NAME}\` passes with a clean exit code (0) and no test or lint regressions.

### Failure Summary
- **Step:** \`${STEP_NAME}\`
- **Command:** \`make ${STEP_NAME}\`
- **Exit Code:** \`${EXIT_CODE}\`
- **Signature:** \`${SIG}\`
- **Log File:** \`${LOGFILE}\`

### Failing Tests
${FORMATTED_TESTS}
### Log Excerpt
\`\`\`text
${EXCERPT}
\`\`\`
EOF
)

# Enforce body length limit (< 6000 chars)
if [[ ${#BODY} -gt 5800 ]]; then
  BODY="${BODY:0:5600}
... (log excerpt truncated to keep body under 6,000 characters)
\`\`\`"
fi

echo "Creating new GitHub issue..."
# Create issue with labels: type:problem, lane:spine, status:ready, gate-failure
CREATE_OUT=$(gh issue create \
  --title "$TITLE" \
  --label "type:problem" \
  --label "lane:spine" \
  --label "status:ready" \
  --label "gate-failure" \
  --body "$BODY" 2>&1 || true)

echo "✅ Gate report completed: ${CREATE_OUT}"

# The script must exit 0 even when filing (the gate's own exit code is preserved by the caller)
exit 0

