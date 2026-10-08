#!/usr/bin/env bash
# Fast (< 5s) pre-push static hygiene & security gate for ApexAgent (Batch 31).
# Checks:
#   1. Leaked secrets / API keys / private keys in tracked Swift & config files
#   2. Forbidden third-party vendor names (Tools/check-vendor-names.sh)
#   3. Raw print() regressions in shipping ApexAgent/ Swift files
#   4. PropertyList / PrivacyInfo.xcprivacy / entitlements XML validity (plutil -lint)
#   5. project.yml <-> ApexAgent.xcodeproj/project.pbxproj registration sync
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

echo "🔎 [hygiene 1/5] Scanning for leaked secrets and private keys..."
SECRET_HITS=$(git grep -nE 'sk-(proj-|ant-)?[A-Za-z0-9_-]{24,}|AIza[0-9A-Za-z_-]{35}|(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,}|xox[baprs]-[0-9A-Za-z-]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----' -- 'ApexAgent/' 'ApexAgentRuntime/' 'ApexAgentIntents/' 'Modules/' 'Tools/' '*.yml' '*.plist' || true)
if [ -n "$SECRET_HITS" ]; then
  echo "❌ Secret pattern detected:"
  echo "$SECRET_HITS"
  exit 1
fi

echo "🔎 [hygiene 2/5] Checking for forbidden vendor-identifying names..."
./Tools/check-vendor-names.sh

echo "🔎 [hygiene 3/5] Checking for raw print() regressions in ApexAgent/..."
PRINT_HITS=$(git grep -nE '(^|[^A-Za-z0-9_."'\''])print\s*\(' -- 'ApexAgent/*.swift' 'ApexAgent/**/*.swift' ':!ApexAgent/Models/ApexGatewayServer.swift' ':!ApexAgent/Models/AppLogger.swift' ':!ApexAgent/Models/AutomationWorkflowEngines.swift' ':!ApexAgent/Security/RepoHygieneAuditor.swift' | grep -vE '^\s*//' || true)
if [ -n "$PRINT_HITS" ]; then
  echo "❌ Raw print() calls found in ApexAgent/ (use AppLog instead):"
  echo "$PRINT_HITS"
  exit 1
fi

echo "🔎 [hygiene 4/5] Validating Info.plist, PrivacyInfo.xcprivacy, and entitlements..."
plutil -lint ApexAgent/Info.plist ApexAgent/Resources/PrivacyInfo.xcprivacy ApexAgent/ApexAgent.entitlements

echo "🔎 [hygiene 5/5] Verifying XcodeGen project.pbxproj registration sync..."
PBX="ApexAgent.xcodeproj/project.pbxproj"
MISSING_PBX=0
while IFS= read -r swift_file; do
  base="$(basename "$swift_file")"
  if ! grep -Fq "$base" "$PBX"; then
    echo "❌ Unregistered Swift file in $PBX: $swift_file (run 'xcodegen generate')"
    MISSING_PBX=1
  fi
done < <(find ApexAgent ApexAgentTests -name "*.swift" -type f)

if [ "$MISSING_PBX" -ne 0 ]; then
  exit 1
fi

echo "✅ Pre-push hygiene & security gate passed."
