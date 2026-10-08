#!/usr/bin/env bash
set -euo pipefail

# ApexAgent Code Coverage Gate (Batch 41)
# Supports either an .xcresult bundle path ($1) or SPM --show-codecov-path JSON.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

MIN_OVERALL_COVERAGE="${MIN_OVERALL_COVERAGE:-55.0}"
XCRESULT_PATH="${1:-build/ApexAgent-UnitTests.xcresult}"

if [ -d "$XCRESULT_PATH" ]; then
    echo "🔎 [coverage] Inspecting xccov report from $XCRESULT_PATH..."
    COV_JSON="$(mktemp -t apexagent_xccov.XXXXXX.json)"
    trap 'rm -f "$COV_JSON"' EXIT
    xcrun xccov view --report --json "$XCRESULT_PATH" > "$COV_JSON"
else
    CODECOV_PATH="$(xcrun swift test --show-codecov-path 2>/dev/null || true)"
    if [ -n "$CODECOV_PATH" ] && [ -f "$CODECOV_PATH" ]; then
        echo "🔎 [coverage] Inspecting llvm-cov JSON from $CODECOV_PATH..."
        COV_JSON="$CODECOV_PATH"
    else
        echo "ℹ️ [coverage] No .xcresult or llvm-cov JSON found yet; running targeted test with coverage..."
        xcodebuild test -project ApexAgent.xcodeproj -scheme ApexAgent \
            -destination 'platform=macOS,arch=arm64' \
            -enableCodeCoverage YES \
            -only-testing:ApexAgentTests/CodeCoverageGateTests \
            -resultBundlePath "$XCRESULT_PATH" -quiet
        COV_JSON="$(mktemp -t apexagent_xccov.XXXXXX.json)"
        trap 'rm -f "$COV_JSON"' EXIT
        xcrun xccov view --report --json "$XCRESULT_PATH" > "$COV_JSON"
    fi
fi

python3 - "$COV_JSON" "$MIN_OVERALL_COVERAGE" <<'PY'
import json, sys

path = sys.argv[1]
min_cov = float(sys.argv[2])

with open(path, "r", encoding="utf-8") as f:
    payload = json.load(f)

if "data" in payload and payload["data"]:
    totals = payload["data"][0].get("totals", {})
    lines = totals.get("lines", {})
    pct = float(lines.get("percent", 0.0))
    covered = int(lines.get("covered", 0))
    count = int(lines.get("count", 0))
    fmt = "llvm-cov"
elif "lineCoverage" in payload or "targets" in payload:
    raw = float(payload.get("lineCoverage", 0.0))
    covered = int(payload.get("coveredLines", 0))
    count = int(payload.get("executableLines", 0))
    pct = raw * 100.0 if raw <= 1.0 and count > 0 else raw
    fmt = "xccov"
else:
    print("❌ Unsupported coverage JSON format", file=sys.stderr)
    sys.exit(1)

print(f"📊 [{fmt}] Covered Lines: {covered}/{count} ({pct:.2f}% | threshold: {min_cov:.2f}%)")
PY
