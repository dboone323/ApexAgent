# ApexAgent — local CI mirror & deep test runners
SWIFT       ?= swift
BUILD_FLAGS := -c release
TEST_FLAGS  := --parallel \
               --skip testBrowserAutomation \
               --skip testRealToolsGrepAndGitMCP

.PHONY: build test ci clean test-deep test-ui xcresult-summary
build:
	$(SWIFT) build $(BUILD_FLAGS)

test:
	$(SWIFT) test $(TEST_FLAGS)

ci: build test

clean:
	$(SWIFT) package clean

# Deep test runner using Xcode test plan and modern xcresults
test-deep:
	@mkdir -p build
	@rm -rf build/ApexAgent-UnitTests.xcresult
	xcodebuild test -project ApexAgent.xcodeproj -scheme ApexAgent -testPlan ApexAgent-UnitTests -destination "platform=macOS" -resultBundlePath build/ApexAgent-UnitTests.xcresult
	@./Tools/scripts/xcresult-report.sh build/ApexAgent-UnitTests.xcresult

# Comprehensive UI test runner
test-ui:
	@mkdir -p build
	@rm -rf build/ApexAgent-UITests.xcresult
	xcodebuild test -project ApexAgent.xcodeproj -scheme ApexAgent -testPlan ApexAgent-UITests -destination "platform=macOS" -resultBundlePath build/ApexAgent-UITests.xcresult
	@./Tools/scripts/xcresult-report.sh build/ApexAgent-UITests.xcresult

# Inspect latest test results bundle
xcresult-summary:
	@./Tools/scripts/xcresult-report.sh
