#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# xcresult-report.sh
# Comprehensive diagnostic summary & attachment extractor for .xcresult bundles.
# Uses Apple's modern `xcrun xcresulttool get test-results` API (Xcode 16/27).
# ─────────────────────────────────────────────────────────────────────────────

XCRESULT_PATH="${1:-}"

# Auto-discover latest xcresult in build/ if none specified
if [[ -z "$XCRESULT_PATH" ]]; then
    XCRESULT_PATH=$(find build -maxdepth 1 -name "*.xcresult" -type d 2>/dev/null | xargs ls -td 2>/dev/null | head -n 1 || true)
fi

if [[ -z "$XCRESULT_PATH" || ! -d "$XCRESULT_PATH" ]]; then
    echo "Usage: $0 <path-to-.xcresult>"
    echo "No valid .xcresult bundle found."
    exit 1
fi

echo "================================================================="
echo " ApexAgent Test Result Diagnostic Report"
echo " Bundle: $XCRESULT_PATH"
echo "================================================================="

SUMMARY_JSON=$(xcrun xcresulttool get test-results summary --path "$XCRESULT_PATH" 2>/dev/null || echo "{}")

PASSED=$(echo "$SUMMARY_JSON" | grep -o '"passedTests" : [0-9]*' | head -n 1 | awk '{print $3}' || echo "0")
FAILED=$(echo "$SUMMARY_JSON" | grep -o '"failedTests" : [0-9]*' | head -n 1 | awk '{print $3}' || echo "0")
SKIPPED=$(echo "$SUMMARY_JSON" | grep -o '"skippedTests" : [0-9]*' | head -n 1 | awk '{print $3}' || echo "0")
TOTAL=$(echo "$SUMMARY_JSON" | grep -o '"totalTestCount" : [0-9]*' | head -n 1 | awk '{print $3}' || echo "0")
RESULT=$(echo "$SUMMARY_JSON" | grep -o '"result" : "[^"]*"' | head -n 1 | cut -d'"' -f4 || echo "Unknown")

echo "Result:       $RESULT"
echo "Total Tests:  ${TOTAL:-0}"
echo "Passed:       ${PASSED:-0}"
echo "Failed:       ${FAILED:-0}"
echo "Skipped:      ${SKIPPED:-0}"

# Calculate pass rate
if [[ -n "$TOTAL" && "$TOTAL" -gt 0 ]]; then
    PERCENT=$(( (PASSED * 100) / TOTAL ))
    echo "Pass Rate:    ${PERCENT}%"
fi

echo ""
echo "── Slowest Test Outliers (> 3 Standard Deviations) ──"
INSIGHTS_JSON=$(xcrun xcresulttool get test-results insights --path "$XCRESULT_PATH" 2>/dev/null || echo "{}")
echo "$INSIGHTS_JSON" | grep -E '("title"|"durationOfSlowTests"|"associatedTestIdentifiers")' || echo "No significant duration outliers."

echo ""
echo "── Code Coverage by Target ──"
if xcrun xccov view --report --only-targets "$XCRESULT_PATH" 2>/dev/null; then
    :
else
    echo "No code coverage data available in this bundle."
fi

# Optional prune of old xcresults in build/
if [[ "${2:-}" == "--prune" || "${PRUNE:-0}" == "1" ]]; then
    echo ""
    echo "── Pruning Old xcresult Bundles in build/ (keeping 5 most recent) ──"
    find build -maxdepth 1 -name "*.xcresult" -type d | xargs ls -td | tail -n +6 | while read -r old_bundle; do
        echo "Removing obsolete bundle: $old_bundle"
        rm -rf "$old_bundle"
    done
fi

echo "================================================================="

# Append GitHub Actions step summary if running under CI
if [[ -n "${GITHUB_STEP_SUMMARY:-}" && -w "$GITHUB_STEP_SUMMARY" ]]; then
    {
        echo "### 📊 ApexAgent Test Result Diagnostic Report"
        echo ""
        echo "| Metric | Value |"
        echo "| :--- | :--- |"
        echo "| **Result** | \`$RESULT\` |"
        echo "| **Total Tests** | \`${TOTAL:-0}\` |"
        echo "| **Passed** | \`${PASSED:-0}\` |"
        echo "| **Failed** | \`${FAILED:-0}\` |"
        echo "| **Skipped** | \`${SKIPPED:-0}\` |"
        if [[ -n "$TOTAL" && "$TOTAL" -gt 0 ]]; then
            echo "| **Pass Rate** | \`${PERCENT}%\` |"
        fi
        echo ""
        echo "#### 🎯 Target-Level Code Coverage"
        echo '```text'
        xcrun xccov view --report --only-targets "$XCRESULT_PATH" 2>/dev/null || echo "No code coverage data available"
        echo '```'
    } >> "$GITHUB_STEP_SUMMARY"
fi
