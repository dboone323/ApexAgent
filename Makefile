# ApexAgent — local CI mirror & deep test runners
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
SWIFT       ?= xcrun swift
BUILD_FLAGS := -c release
TEST_FLAGS  := --parallel --enable-code-coverage

.PHONY: build test coverage ci clean test-deep test-ui xcresult-summary hygiene lint syntax-check format pre-push full audit-deps sbom changelog release-check provenance sarif cli-smoke traces install-hooks gate-report
hygiene:
	@chmod +x ./Tools/scripts/pre-push-hygiene.sh
	@./Tools/scripts/pre-push-hygiene.sh

audit-deps: hygiene

sbom:
	@$(SWIFT) run ApexAgent sbom

changelog:
	@$(SWIFT) run ApexAgent changelog

release-check:
	@$(SWIFT) run ApexAgent release-check

provenance:
	@$(SWIFT) run ApexAgent provenance --json

sarif:
	@$(SWIFT) run ApexAgent sarif --json

cli-smoke:
	@$(SWIFT) run ApexAgent self-test

traces:
	@$(SWIFT) run ApexAgent traces

install-hooks:
	@chmod +x ./Tools/scripts/pre-commit.sh ./Tools/scripts/commit-msg.sh ./Tools/scripts/pre-push-hygiene.sh ./Tools/scripts/lint-changed-swift.sh
	@if [ -d .git/hooks ]; then \
		ln -sf ../../Tools/scripts/pre-commit.sh .git/hooks/pre-commit; \
		ln -sf ../../Tools/scripts/commit-msg.sh .git/hooks/commit-msg; \
		echo "✅ Installed pre-commit and commit-msg hooks in .git/hooks/"; \
	fi

lint:
	@chmod +x ./Tools/scripts/lint-changed-swift.sh
	@./Tools/scripts/lint-changed-swift.sh

syntax-check: lint

format:
	@git diff --name-only --diff-filter=ACMRTUXB origin/main...HEAD -- '*.swift' | xargs -r xcrun swift format format --in-place --configuration .swift-format

pre-push: hygiene lint
	@xcodebuild build -project ApexAgent.xcodeproj -scheme ApexAgent -destination "platform=macOS" -derivedDataPath /tmp/dd_clean -quiet

full: hygiene lint test-deep

build:
	$(SWIFT) build $(BUILD_FLAGS)

test:
	$(SWIFT) test $(TEST_FLAGS)

coverage:
	@chmod +x ./Tools/scripts/coverage-gate.sh
	@./Tools/scripts/coverage-gate.sh

ci: hygiene lint build test

clean:
	$(SWIFT) package clean

# Deep test runner using Xcode test plan and modern xcresults
test-deep:
	@mkdir -p build
	@rm -rf build/ApexAgent-UnitTests.xcresult
	xcodebuild test -project ApexAgent.xcodeproj -scheme ApexAgent -testPlan ApexAgent-UnitTests -destination "platform=macOS" -resultBundlePath build/ApexAgent-UnitTests.xcresult
	@./Tools/scripts/xcresult-report.sh build/ApexAgent-UnitTests.xcresult --prune

# Comprehensive UI test runner
test-ui:
	@mkdir -p build
	@rm -rf build/ApexAgent-UITests.xcresult
	xcodebuild test -project ApexAgent.xcodeproj -scheme ApexAgent -testPlan ApexAgent-UITests -destination "platform=macOS" -resultBundlePath build/ApexAgent-UITests.xcresult
	@./Tools/scripts/xcresult-report.sh build/ApexAgent-UITests.xcresult --prune

# Inspect latest test results bundle
xcresult-summary:
	@./Tools/scripts/xcresult-report.sh

# Canonical gate runner with automatic issue reporting and deduplication
gate-report:
	@chmod +x ./scripts/gate-report.sh
	@bash -c '\
		set -uo pipefail; \
		overall_exit=0; \
		echo "=== [gate-report] Running step: lint ==="; \
		set +e; \
		$(MAKE) lint 2>&1 | tee gate-lint.log; \
		lint_exit=$${PIPESTATUS[0]}; \
		set -e; \
		./scripts/gate-report.sh gate-lint.log lint "$$lint_exit"; \
		if [ "$$lint_exit" -ne 0 ]; then \
			overall_exit=$$lint_exit; \
		fi; \
		echo "=== [gate-report] Running step: test-deep ==="; \
		set +e; \
		$(MAKE) test-deep 2>&1 | tee gate-test-deep.log; \
		test_exit=$${PIPESTATUS[0]}; \
		set -e; \
		./scripts/gate-report.sh gate-test-deep.log test-deep "$$test_exit"; \
		if [ "$$test_exit" -ne 0 ]; then \
			overall_exit=$$test_exit; \
		fi; \
		exit "$$overall_exit"'
