# Xcode 27 Free Integration & Autonomous Agent Plan

**Goal:** Transform Xcode 27 into a free-only, agent-ready iOS/macOS 27 development environment by integrating free MCP servers, restricting plugins, connecting local Ollama, and enabling ACP agent autonomy inside Xcode.

**Architecture:**
1) Lock plugins/MCP to free-tier/no-cost integrations only.
2) Add local-first and free-cloud MCP servers under Xcode's CodingAssistant.
3) Bridge Ollama (local LLM) into Xcode via codex/gemini agents/MCP.
4) Register ACP agents so they can drive Xcode autonomously for scaffolding, building, testing, and PRs.

**Tech Stack:**
- Xcode 27.0 Beta 2 (27A5209h) + macOS 27.0 (26A5368g)
- Xcode CodingAssistant: codex 0.140.0 + gemini 0.42.0-nightly
- MCP + ACP bridge inside Xcode CodingAssistant
- Ollama local (HTTP 11434)
- Free-tier services: GitHub public API, free Ollama models, free file/system MCP, free browser MCP

---

## Current Context / Assumptions

- Xcode 27 Beta 2 installed at `/Applications/Xcode-beta.app`.
- macOS 27.0 (26A5368g).
- `xcrun` 72 present.
- CodingAssistant lives under `~/Library/Developer/Xcode/CodingAssistant/`.
- Current plugins: `browser`, `canva`, `chrome`, `computer-use`, `documents`, `github`, `openai-developers`, `pdf`, `presentations`, `product-design`, `spreadsheets`.
- Current agents: `codex/0.140.0`, `gemini/0.42.0-nightly.20260512.gc987b9939`.
- `mcp-servers.json` is empty.
- `/Library/Developer/CommandLineTools/SDKs/MacOSX27.0.sdk` present.
- Ollama endpoint expected at `http://localhost:11434`.

### Assumptions we will enforce
- No paid-cloud providers allowed unless the user explicitly adds billing later.
- Open-XCUITest, Xcode Server, `xcodebuild`, `xcrun`, and Simulator are free and on-device.
- GitHub integration uses unauthenticated/public endpoints or a user-supplied free token stored in Keychain; no hosted SaaS.
- "ACPs can use Xcode completely" means command-line + MCP + project-file access; no cloud wrapper is required.

---

## Free MCP Servers To Integrate

| MCP Server | Cost | Purpose | Xcode Benefit |
|------------|------|---------|----------------|
| `filesystem` / `file-search` | Free (local) | Search/read/edit project files | Context-aware edits in SDKs/Resources |
| `git` | Free (local) | Repo status, diffs, log | Test commits before Xcode source control actions |
| `github` (public REST or local CLI) | Free (public quota / local `gh`) | Issues, PRs, Actions | Automate PR descriptions/reviews |
| `fetch` / `web` | Free (local) | HTTP GET docs/samples | Pull Apple docs during rewrite |
| `browser` (Chromium via Playwright) | Free (local) | Screenshots/DOM | Preview web content for assistant |
| `ollama` (local) | Free | Local LLM inference | Connect codex/gemini to local models |
| `sqlite` | Free (local) | Query DerivedData/logs | Analyze build/test DBs |
| `xcode` (proposed local MCP) | Free | `xcodebuild`, `xcrun`, Simulator control | Drive builds, tests, simulators from agents |

> NOTE: Canva/OpenAI Developers/PDF/Spreadsheets/Presentations typically require paid accounts. Those plugins should be disabled until the user opts into paid tiers.

---

## Proposed Approach

### Phase 0 — Freeze plugin surface
- Disable non-free plugins in `PluginsManifest.json` and `config.toml`.
- Keep only free-capable plugins: `browser`, `chrome`, `computer-use`, `documents`, `github`, `pdf`, `product-design`, `spreadsheets`, `presentations`. Re-evaluate per-team choice.

### Phase 1 — Local MCP servers
- Add `filesystem`, `git`, `sqlite`, `xcode`, and `ollama` entries to `mcp-servers.json`.
- Install/config any missing local MCP packages; store credentials in Keychain.

### Phase 2 — ACP bridge
- Add an `xcode-acp` bridge that exposes an ACP endpoint and translates calls into Xcode tool invocations (`xcodebuild`, `open`, Simulator CLI).

### Phase 3 — Ollama local
- Ensure Ollama is installed/running; configure codex/gemini to call `ollama` endpoints in `config.toml` + plugin.

### Phase 4 — Validation
- Smoke-test each integration with a repeatable script and verify free-tier limits.

---

## Step-by-Step Plan

### Task 1: Inventory current Xcode 27 paths + target plugins
**Objective:** Confirm exact paths and exact plugin sets before editing.
**Files:**
- Read: `~/Library/Developer/Xcode/CodingAssistant/AgentPlugins/PluginsManifest.json`
- Read: `~/Library/Developer/Xcode/CodingAssistant/codex/config.toml`
- Read: `~/Library/Developer/Xcode/CodingAssistant/mcp-servers.json`
- Read: `~/Library/Developer/Xcode/CodingAssistant/Agents/*/`
**Step 1:** List plugins per manifest/config.
**Step 2:** List agents per folder.
**Step 3:** Validate Ollama endpoint: `curl -s http://localhost:11434/api/tags`.
**Verification:** screenshots/CLI output saved under `.hermes/plans/artifacts/xcode27-audit.txt`.

---

### Task 2: Disable-paid-plugin lockdown
**Objective:** Restrict plugins to free-tier-capable integrations only.
**Files:**
- Modify: `~/Library/Developer/Xcode/CodingAssistant/AgentPlugins/PluginsManifest.json`
- Modify: `~/Library/Developer/Xcode/CodingAssistant/codex/config.toml`
**Step 1:** Set `enabled = false` for:
- `canva`
- `openai-developers`
**Step 2:** Keep enabled for free-tier plugins:
- `browser`
- `chrome`
- `computer-use`
- `documents`
- `github`
- `pdf`
- `product-design`
- `spreadsheets`
- `presentations`
**Step 3:** Add comment block at top explaining free-only policy.
**Verification:** Re-read both files and confirm only free plugins are enabled.

---

### Task 3: Add local MCP server registry
**Objective:** Register local MCP servers so codex/gemini can use them.
**Files:**
- Create/modify: `~/Library/Developer/Xcode/CodingAssistant/mcp-servers.json`
**Step 1:** Draft JSON with:
```json
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/Users/danielstevens"],
      "env": {}
    },
    "git": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-git"],
      "env": {}
    },
    "sqlite": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-sqlite", "~/Library/Developer/Xcode/DerivedData"],
      "env": {}
    },
    "xcode": {
      "command": "python3",
      "args": ["-m", "xcode_mcp_server"],
      "cwd": "/Users/danielstevens/.hermes/skills/xcode27-mcp-server",
      "env": {}
    },
    "ollama": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-ollama"],
      "env": {
        "OLLAMA_HOST": "http://localhost:11434"
      }
    },
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_TOKEN}"
      }
    }
  }
}
```
**Step 2:** Ensure each command succeeds in foreground via `terminal()`.
**Step 3:** Document failure fallbacks in `/Users/danielstevens/.hermes/plans/artifacts/xcode27-mcp-fallback.md`.
**Verification:** `cat mcp-servers.json`, then run each `command --version` equivalent.

---

### Task 4: Build the Xcode local MCP server
**Objective:** Provide `xcodebuild`/`xcrun`/Simulator control to agents via MCP.
**Files:**
- Create: `/Users/danielstevens/.hermes/mcp-servers/xcode_mcp_server.py`
**Step 1:** Implement a FastMCP-style HTTP server over stdio exposing tools:
- `xcode_build(project, scheme, destination)`
- `xcode_test(project, scheme)`
- `xcode_simulator_boot(device)`
- `xcode_simulator_shutdown(device)`
- `xcode_open_project(path)`
- `xcode_package_swift(path)`
**Step 2:** Validate each tool by running `xcodebuild -list` in a known project.
**Step 3:** Add unit tests at `/Users/danielstevens/.hermes/tests/test_xcode_mcp.py`.
**Verification:** Run `python3 -m xcode_mcp_server --help` and run tests.

---

### Task 5: Enable Ollama in Xcode agents
**Objective:** Route codex/gemini generative requests to local Ollama when network is constrained.
**Files:**
- Modify: `~/Library/Developer/Xcode/CodingAssistant/codex/config.toml`
- Create: `/Users/danielstevens/.hermes/skills/xcode27-ollama/ollama-bridge.py`
**Step 1:** Add an Ollama endpoint and model block to `config.toml`.
**Step 2:** Add a plugin manifest that loads `ollama` MCP.
**Step 3:** Verify Ollama is running locally and list models via HTTP.
**Step 4:** Test an end-to-end prompt that hits Ollama and publishes a build command.
**Verification:** `curl -s http://localhost:11434/api/generate` succeeds.

---

### Task 6: Register ACP agents inside Xcode
**Objective:** Allow Anthropic/OpenAI agents to drive Xcode directly through ACP.
**Files:**
- Create: `/Applications/Xcode-beta.app/Contents/Developer/AgentPlugins/acp/plugin.json`
- Create: `/Applications/Xcode-beta.app/Contents/Developer/AgentPlugins/acp/acp-bridge.sh`
**Step 1:** Define plugin manifest declaring ACP tools:
- `acp.init(workdir)`
- `acp.run(command)`
- `acp.status()`
**Step 2:** Implement bridge script to call `claude --acp --stdio` or `codex --acp --stdio`, forwarding Xcode tool invocations.
**Step 3:** Add this plugin to `PluginsManifest.json` and `config.toml`.
**Step 4:** Test with a noop ACP workload that prints `xcodebuild -version`.
**Verification:** Run the bridge script manually and ensure exit 0.

---

### Task 7: Add Xcode 27 agent rules + skills
**Objective:** Give agents safe, precise behavior for iOS/macOS 27.
**Files:**
- Modify: `~/Library/Developer/Xcode/CodingAssistant/codex/rules/xcode.rules`
- Create: `~/.hermes/skills/xcode27-dev/SKILL.md`
**Step 1:** Write rules covering:
- SDK targeting: iOS 27, macOS 27, watchOS 27, tvOS 27, visionOS 27.
- Swift 6.4 rule checklist: `Sendable` correctness, data-race safety, concurrency isolation.
- Test discipline: Swift Testing + XCTest hybrid, Test Plans, XCUIAutomation for UI.
- SPM-only dependencies unless org policy allows CocoaPods/Carthage.
- No paid/external accounts in automation scripts.
**Step 2:** Document the skill with exact commands for SPM, xcodebuild, Test Plans.
**Verification:** Read the skill/rules and confirm it covers iOS 27/macOS 27 minimums.

---

### Task 8: Automate a free-tier validation script
**Objective:** Continuously verify no paid APIs are referenced.
**Files:**
- Create: `/Users/danielstevens/.hermes/scripts/xcode27-free-tier-audit.sh`
**Step 1:** Scan for provider domains/registrations that indicate paid SaaS.
**Step 2:** Blocklist keys: Canva, OpenAI billed, Anthropic billed, Google Workspace billing endpoints.
**Step 3:** Exit 0 on clean, >0 on violation.
**Verification:** Run in dry-run mode and inspect output.

---

## Files Likely To Change

| Path | Action | Purpose |
|------|--------|---------|
| `~/Library/Developer/Xcode/CodingAssistant/AgentPlugins/PluginsManifest.json` | Modify | Lock plugin surface |
| `~/Library/Developer/Xcode/CodingAssistant/codex/config.toml` | Modify | Set free-only plugins + Ollama endpoint |
| `~/Library/Developer/Xcode/CodingAssistant/mcp-servers.json` | Create | Register local MCP servers |
| `~/Library/Developer/Xcode/CodingAssistant/codex/rules/xcode.rules` | Modify | iOS/macOS 27 rule checklist |
| `/Users/danielstevens/.hermes/mcp-servers/xcode_mcp_server.py` | Create | Xcode MCP bridge |
| `/Users/danielstevens/.hermes/mcp-servers/ollama-bridge.py` | Create | Ollama bridge |
| `/Applications/Xcode-beta.app/Contents/Developer/AgentPlugins/acp/plugin.json` | Create | ACP plugin manifest |
| `/Applications/Xcode-beta.app/Contents/Developer/AgentPlugins/acp/acp-bridge.sh` | Create | ACP CLI bridge |
| `/Users/danielstevens/.hermes/skills/xcode27-dev/SKILL.md` | Create | Shared dev skill |
| `/Users/danielstevens/.hermes/scripts/xcode27-free-tier-audit.sh` | Create | Free-tier validator |

---

## Tests / Validation

1. **Plugin lockdown:** Read `PluginsManifest.json`/`config.toml`; assert paid plugins `enabled = false`.
2. **MCP server launch:** For every `mcpServers.<name>.command`, run a help/version command; assert non-zero output and exit 0.
3. **Ollama end-to-end:** `curl -s http://localhost:11434/api/generate`; assert JSON body contains `response`.
4. **Xcode MCP tool:** Call `xcode_mcp_server.py` with each tool; assert JSON response.
5. **ACP bridge:** Execute `acp-bridge.sh --help`; assert ACP usage text.
6. **Free-tier audit:** Run `xcode27-free-tier-audit.sh`; assert exit 0 and empty findings.
7. **iOS 27 build smoke test:** Create a sample SPM project, set deployment target iOS 27, build with `xcodebuild`; assert SUCCESS.

---

## Risks, Tradeoffs, and Open Questions

- **Beta instability:** Xcode 27 Beta 2 may change plugin API; finalize after WWDC seed stabilizes, or pin 26.6 for CI.
- **MCP packages:** `@modelcontextprotocol/server-*` packages assume Node 18+; pin versions in `package.json` to avoid breakage.
- **Ollama model size:** Local models may exceed memory; gate by `ollama list` before enabling.
- **ACPs need a CLI:** We assume `claude --acp --stdio` or `codex --acp --stdio` are available; verify before Task 6.
- **Xcode plugin signing:** Adding plugins under `/Applications/Xcode-beta.app/Contents/Developer/` may require re-codesign or SIP bypass; test first, and prefer user-level CodingAssistant plugins when possible.

---

## Execution Note

This plan assumes:
- Editing `PluginsManifest.json` and `config.toml` does not require Xcode to be closed.
- User is comfortable adding Node packages via `npm` and Python packages via `pip` in a virtual environment.
- If any step fails, it will be treated as a planned blocker with a fallback documented in `.hermes/plans/artifacts/`.
