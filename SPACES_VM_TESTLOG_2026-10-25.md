# Spaces-on-VM: per-test append logs + control time limits

## Pre-flight
- HEAD cb914329, branch feat/spaces-vm.
- ~/.tart -> /Volumes/ApexDev/tart; tart list: only stopped apex-base.
- 600s default + .timeLimit traits present uncommitted.

## Log directory chosen
- Repo `build/test-logs/` (candidate 1). Writability proven by TestLogTests (3/3 passed).

## Helper API
- TestLog.append(test:phase:message:) and TestLog.beginRun(test:runID:).
- Serial DispatchQueue; errors swallowed with print.

## Unit tests
- TestLogTests: 3 passed. VMWorkspaceManagerTests: 10 passed. Bundle build/RW-TESTLOG-1.xcresult.

## Full unit plan
- 1725 passed, 0 failed, 14 skipped, 2 expected failures. Bundle build/RW-TESTLOG-2.xcresult.

## Lint gate
- SwiftSyntaxLintGateTests 3/3. Bundle build/RW-TESTLOG-3.xcresult.

## Live logging verification
- Log file: /Users/danielstevens/Developer/ApexAgent/build/test-logs/VMRoutingLiveTests-smoke.log
- Contains provision/ready/seed lines; last line before hang: seed start. Trait fired ~10min.
- Leftover VMs stopped/deleted; tart list clean.

## Rotation script
- scripts/rotate-test-logs.sh: >5MB keep last 2000 lines, >30 days delete, skip <1h. Scratch tests passed. Real dir: 0 acted.

## LaunchAgent
- ~/Library/LaunchAgents/com.apexagent.testlog-rotate.plist, daily 03:00, RunAtLoad false. Loaded; launchctl list shows entry.

## Commit
- Commit hash: 1b65148e
## Notes
- Does not fix hang. Battery wiring follow-up.
