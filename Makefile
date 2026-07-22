# ApexAgent — local CI mirror (same flags as the GitHub workflow)
# Runs on your machine with the real Xcode 27 beta / macOS 27 SDK.
SWIFT      ?= swift
BUILD_FLAGS := -c release
# Tests build in DEBUG: DynamicToolbox exposes its test-only helpers under
# `#if DEBUG`, so `swift test` must NOT use -c release (standard SwiftPM practice).
# Headless tests that hang locally/CI are skipped deliberately:
#   testBrowserAutomation      -> needs a live WebView (WebKit)
#   testRealToolsGrepAndGitMCP -> spawns a git MCP subprocess that never exits
TEST_FLAGS  := --parallel \
               --skip testBrowserAutomation \
               --skip testRealToolsGrepAndGitMCP

.PHONY: build test ci clean
build:
	$(SWIFT) build $(BUILD_FLAGS)

test:
	$(SWIFT) test $(TEST_FLAGS)

ci: build test

clean:
	$(SWIFT) package clean
