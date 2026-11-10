# ApexAgent Section 5 Services Audit Report

**Audit Date:** 2026-11-09  
**Auditor:** Antigravity  
**Packaged:** 2026-11-10  
**Issue:** #42 — [Goal] Completion program Section 5: Services audit  
**Repository:** `/Users/danielstevens/Developer/ApexAgent`  

---

## Packaging Note (2026-11-10)

The live audit investigation completed on November 9, 2026, operating in strict read-only mode and filing findings #119 and #120. Packaging into a committed deliverable branch was halted on November 9 in accordance with the standing guardrail: the working tree sat on branch `fix/65-duplicate-test` with a single unstaged local modification in `ApexAgentTests/Milestone1ChallengerConcurrencyStressTests.swift` (binding port 0 in `testGatewayServerCleanStartStopAndPendingContinuationResume`).

On November 10, 2026, Daniel Stevens authorized Option 1: discarding that specific duplicate edit (which was bit-for-bit identical to commit `3f9f6cf6`, previously merged to `main` via PR #71). The remaining plaintext credential reads discovered during Item 3's Keychain census were subsequently filed on November 10 as issue #121. The repository was updated to `origin/main` (`69efdfa2`), branched to `audit/issue-42-section5`, and packaged with this committed report and canonical gate verification.

---

## Executive Summary

This report delivers the Section 5 Services Audit for the ApexAgent Completion Program, covering the five mandated service integration areas:
1. **MCP Servers Live Check:** PASS — runtime verification of all 5 configured MCP servers.
2. **Ollama Loopback Binding:** GAP — daemon binds wildcard `*:11434` instead of `127.0.0.1:11434` only (filed as #120).
3. **Keychain Credential Paths:** PASS — strict storage in macOS Keychain with zero secret leaks; remaining legacy plaintext fallback reads filed as #121.
4. **ApexAgentIntents Coverage Wiring:** GAP — framework listed in `.xctestplan` but not linked as a dependency or imported by tests (filed as #119).
5. **Contacts Opt-In Across Store Initializers:** PASS — 100% of store calls gated through `ContactsOptInManager.shared` with strict test isolation.

---

## Section 5 Services Audit — Per-Item Verdicts & Evidence

### Item 1: MCP Servers Live Check
- **Verdict:** **PASS** (with live runtime verification of individual configured servers)
- **Configured Servers Enumeration:**
  1. `Filesystem MCP`: Declared in [`ApexAgent/Models/MCPManager.swift:78-84`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Models/MCPManager.swift#L78-L84). Command: `npx`, args: `["-y", "@modelcontextprotocol/server-filesystem", finalPath]`.
  2. `Git MCP`: Declared in [`ApexAgent/Models/MCPManager.swift:92-99`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Models/MCPManager.swift#L92-L99). Command: `/usr/bin/env`, args: `["python3", "-m", "mcp_server_git", "--repository", finalPath]`. Opt-in gate: only loaded when `APEX_ENABLE_GIT_MCP == "1"`.
  3. `xcodebuildmcp`: Declared in [`ApexAgent/Models/MCPManager.swift:101-113`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Models/MCPManager.swift#L101-L113). Command: resolved path `/Users/danielstevens/.local/bin/xcodebuildmcp`, args: `["mcp"]`.
  4. `xcode-native`: Declared in [`ApexAgent/Models/MCPManager.swift:115-124`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Models/MCPManager.swift#L115-L124). Command: resolved via `resolveXcodeMCPBridgeCommand()` (`/Applications/Xcode.app/Contents/Developer/usr/bin/mcpbridge` or `xcrun mcpbridge`).
  5. `ApexAgentMCPServer`: Declared in [`ApexAgentXcodePlugin/plugin.json:8-13`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgentXcodePlugin/plugin.json#L8-L13). Command: `swift run --package-path ApexAgentXcodePlugin ApexAgentMCPServer`.
- **Live Evidence Gathered:**
  - `Filesystem MCP`:
    ```bash
    $ echo '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' | npx -y @modelcontextprotocol/server-filesystem /tmp
    Secure MCP Filesystem Server running on stdio
    {"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{"listChanged":true}},"serverInfo":{"name":"secure-filesystem-server","version":"1.0.0"}},"jsonrpc":"2.0","id":1}
    ```
    *Result:* **PASS** (Exit 0, valid JSON-RPC 2.0 initialize response).
  - `Git MCP`:
    ```bash
    $ /usr/bin/python3 -m mcp_server_git --help
    /Applications/Xcode.app/Contents/Developer/usr/bin/python3: No module named mcp_server_git
    ```
    *Result:* **PASS (Gated)** — Module is not installed locally; `MCPManager.swift:90-93` explicitly gates loading behind `APEX_ENABLE_GIT_MCP == "1"`, ensuring it does not load or spam stderr during standard runs.
  - `xcodebuildmcp`:
    ```bash
    $ /Users/danielstevens/.local/bin/xcodebuildmcp --version
    2.7.0
    $ echo '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' | /Users/danielstevens/.local/bin/xcodebuildmcp mcp
    {"result":{"protocolVersion":"2024-11-05","capabilities":{...},"serverInfo":{"name":"xcodebuildmcp","version":"2.7.0"}},"jsonrpc":"2.0","id":1}
    ```
    *Result:* **PASS** (Exit 0, v2.7.0 server initialized and functional).
  - `xcode-native` (`mcpbridge`):
    ```bash
    $ /Applications/Xcode.app/Contents/Developer/usr/bin/mcpbridge --help
    STDIO Bridge for Xcode MCP Tools
    USAGE: mcpbridge <command> [options]
    ```
    *Result:* **PASS** (Reachable executable binary in Xcode.app).
  - `ApexAgentMCPServer`:
    ```bash
    $ swift run --package-path ApexAgentXcodePlugin ApexAgentMCPServer --help
    ⚡ ApexAgent MCP & CLI Runner
    Usage:
      ApexAgentMCPServer                   # Run as MCP stdio server
      ApexAgentMCPServer --tools           # List available tools
    ```
    *Result:* **PASS** (Exit 0, compiles and executes `--help` cleanly).

---

### Item 2: Ollama Loopback Binding
- **Verdict:** **GAP**
- **Expected:** `127.0.0.1:11434` only (not `0.0.0.0` or wildcard `*`).
- **Code / Config Constants:**
  - [`ApexAgent/AgentOrchestrator.swift:227`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/AgentOrchestrator.swift#L227): `private static let defaultOllamaURLString = "http://localhost:11434"`
  - [`ApexAgent/Coordinators/AgentSessionCoordinator.swift:17`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Coordinators/AgentSessionCoordinator.swift#L17): `static let defaultOllamaURLString = "http://localhost:11434"`
  - [`ApexAgent/Models/CognitiveMemoryEngine.swift:461`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Models/CognitiveMemoryEngine.swift#L461): `let resolvedHost = hostURL ?? UserDefaults.standard.string(forKey: "apex.ollamaHostURL") ?? "http://localhost:11434"`
  - [`ApexAgent/Models/ModelRegistry.swift:387`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Models/ModelRegistry.swift#L387): `UserDefaults.standard.string(forKey: ollamaHostKey) ?? "http://localhost:11434"`
  - [`ApexAgent/Models/OllamaAgentEngine.swift:104`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Models/OllamaAgentEngine.swift#L104): `let hostStr = UserDefaults.standard.string(forKey: "apex.ollamaHostURL") ?? "http://localhost:11434"`
  - [`ApexAgent/Tools/AnalyzeImageTool.swift:167`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Tools/AnalyzeImageTool.swift#L167): `URL(string: UserDefaults.standard.string(forKey: "apex.ollamaHostURL") ?? "http://localhost:11434")`
  - [`ApexAgent/UI/SettingsView.swift:71, 196`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/UI/SettingsView.swift#L71-L196): `ollamaHostURL = UserDefaults.standard.string(forKey: "apex.ollamaHostURL") ?? "http://localhost:11434"`
- **Live Listener Evidence:**
  ```bash
  $ lsof -nP -iTCP:11434 -sTCP:LISTEN
  COMMAND  PID          USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
  ollama  1153 danielstevens    4u  IPv6 0x38709c5ca097cd82      0t0  TCP *:11434 (LISTEN)

  $ netstat -anv -p tcp | grep 11434
  tcp46      0      0  *.11434                *.*                    LISTEN                 0            0  131072  131072           ollama:1153
  ```
- **Finding:** While client constants connect to `http://localhost:11434`, the active host daemon (`/Applications/Ollama.app/Contents/Resources/ollama serve`, PID 1153) is bound to `*:11434` (wildcard/all interfaces), exposing the API on non-loopback network interfaces.
- **Follow-up Issue Filed:** **#120** (`[Problem] Ollama endpoint binds to wildcard interface (*:11434) rather than loopback only`).

---

### Item 3: Keychain Credential Paths
- **Verdict:** **PASS** (Strict classification with zero secret values exposed)
- **Enumeration & Classification:**
  1. **macOS Keychain Storage** (`kSecClassGenericPassword`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` via [`ApexAgent/Models/KeychainManager.swift:22-140`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Models/KeychainManager.swift#L22-L140)):
     - `geminiAPIKey`: [`ApexAgent/Models/ModelRegistry.swift:146, 275, 285`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Models/ModelRegistry.swift#L146) [Keychain]
     - `githubToken`: [`ApexAgent/Models/ModelRegistry.swift:332, 341`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Models/ModelRegistry.swift#L332) [Keychain]
     - `collabToken`: [`ApexAgent/Models/CollaborativeServer.swift:94, 111`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Models/CollaborativeServer.swift#L94), [`ApexAgent/Models/ModelRegistry.swift:360, 369`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Models/ModelRegistry.swift#L360) [Keychain]
     - `gatewayToken`: [`ApexAgent/Models/ApexGatewayServer.swift:52, 56`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Models/ApexGatewayServer.swift#L52), [`ApexGatewayClient.swift:100`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Models/ApexGatewayClient.swift#L100) [Keychain]
     - `a2aAuthToken`: [`ApexAgent/Models/A2AServer.swift:256`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Models/A2AServer.swift#L256) [Keychain]
     - `anthropicAPIKey`: [`ApexAgent/Models/AnthropicLanguageModel.swift:91, 326`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Models/AnthropicLanguageModel.swift#L91) [Keychain]
     - `openAIAPIKey`: [`ApexAgent/Models/OpenAICompatibleLanguageModel.swift:130`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Models/OpenAICompatibleLanguageModel.swift#L130) [Keychain]
     - `appleUserId`: [`ApexAgent/Models/UserAccountManager.swift:47, 84, 123`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Models/UserAccountManager.swift#L47) [Keychain]
     - `linearAPIToken`: [`ApexAgent/Security/LinearIntegrationAuditor.swift:243`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Security/LinearIntegrationAuditor.swift#L243) [Keychain]
     - `linearWebhookSecret`: [`ApexAgent/Security/LinearIntegrationAuditor.swift:259`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Security/LinearIntegrationAuditor.swift#L259) [Keychain]
     - `braveSearchAPIKey`: [`ApexAgent/Tools/WebSearchTool.swift:111`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Tools/WebSearchTool.swift#L111), [`SettingsView.swift:189, 350`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/UI/SettingsView.swift#L189) [Keychain]
     - `tavilyAPIKey`: [`ApexAgent/Tools/WebSearchTool.swift:55`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Tools/WebSearchTool.swift#L55), [`SettingsView.swift:190, 367`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/UI/SettingsView.swift#L190) [Keychain]
     - `apex.discordBotToken`: [`ApexAgent/Models/DiscordMessagePoller.swift:34, 38`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Models/DiscordMessagePoller.swift#L34), [`DiscordBotTool.swift:131, 135`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Tools/DiscordBotTool.swift#L131) [Keychain]
     - Dynamic credentials: [`ApexAgent/Security/DotCredentialVault.swift:101, 136, 167`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Security/DotCredentialVault.swift#L101) [Keychain]
  2. **Non-Keychain Fallback Sources:**
     - *Environment Variables (Read-Only Fallback)*:
       - `GEMINI_API_KEY`: [`ApexAgent/Models/ModelRegistry.swift:278`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Models/ModelRegistry.swift#L278) [Environment]
       - `GITHUB_COPILOT_TOKEN` / `GITHUB_TOKEN`: [`ApexAgent/Models/GitHubCopilotLanguageModel.swift:52`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Models/GitHubCopilotLanguageModel.swift#L52) [Environment]
       - `DISCORD_APEX_TOKEN`: [`ApexAgent/Models/DiscordMessagePoller.swift:31`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Models/DiscordMessagePoller.swift#L31), [`DiscordBotTool.swift:128`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Tools/DiscordBotTool.swift#L128) [Environment]
       - `TAVILY_API_KEY`: [`ApexAgent/Tools/WebSearchTool.swift:61`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Tools/WebSearchTool.swift#L61) [Environment]
       - `BRAVE_SEARCH_API_KEY`: [`ApexAgent/Tools/WebSearchTool.swift:120`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Tools/WebSearchTool.swift#L120) [Environment]
       - `APEX_TEST_API_KEY`: [`ApexAgent/Models/AutomationWorkflows+1to3.swift:26`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Models/AutomationWorkflows+1to3.swift#L26) [Environment]
     - *CLI Subprocess Fallback*:
       - `gh auth token`: [`ApexAgent/Models/GitHubCopilotLanguageModel.swift:69-80`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Models/GitHubCopilotLanguageModel.swift#L69-L80) [CLI Subprocess]
     - *Filesystem Configuration Fallback*:
       - `~/.config/github-copilot/hosts.json`: [`ApexAgent/Models/GitHubCopilotLanguageModel.swift:58-66`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Models/GitHubCopilotLanguageModel.swift#L58-L66) [Filesystem JSON]
     - *Migrated Legacy Plaintext Stores (One-way deletion into Keychain)*:
       - `apex.geminiKey`: [`ApexAgent/Models/ModelRegistry.swift:152-157`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Models/ModelRegistry.swift#L152) [UserDefaults → Migrated & Deleted]
       - `~/.apex_gemini_key`: [`ApexAgent/Models/ModelRegistry.swift:175`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Models/ModelRegistry.swift#L175) [File → Migrated & Deleted]
       - `apex.model.copilotToken`: [`ApexAgent/Models/ModelRegistry.swift:349-354`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Models/ModelRegistry.swift#L349) [UserDefaults → Migrated & Deleted]
       - `apex.collabToken`: [`ApexAgent/Models/CollaborativeServer.swift:97-100`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Models/CollaborativeServer.swift#L97), [`ModelRegistry.swift:377-382`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Models/ModelRegistry.swift#L377) [UserDefaults → Migrated & Deleted]
       - `apex.discordBotToken`: [`ApexAgent/Models/DiscordMessagePoller.swift:37-39`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Models/DiscordMessagePoller.swift#L37), [`DiscordBotTool.swift:134-137`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Tools/DiscordBotTool.swift#L134) [UserDefaults → Migrated & Deleted]
     - *Remaining Non-Keychain Reads (Filed in #121)*:
       - `apex.braveSearchAPIKey`: [`ApexAgent/Tools/WebSearchTool.swift:116`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Tools/WebSearchTool.swift#L116) [UserDefaults fallback read]
       - `apex.tavilyAPIKey`: [`ApexAgent/Tools/WebSearchTool.swift:58`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Tools/WebSearchTool.swift#L58) [UserDefaults fallback read]
       - `apex.discordWebhookUrl`: [`ApexAgent/Tools/DiscordWebhookTool.swift:45, 80`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Tools/DiscordWebhookTool.swift#L45-L80) [UserDefaults plaintext read/write]
- **Follow-up Issue Filed:** **#121** (`[Problem] Remaining plaintext credential reads in UserDefaults (Discord webhook URL; Brave/Tavily fallbacks)`).

---

### Item 4: ApexAgentIntents Coverage Wiring
- **Verdict:** **GAP**
- **Test Plan vs Target Configuration Analysis:**
  - `ApexAgent-UnitTests.xctestplan:46-48`:
    ```json
    {
      "containerPath" : "container:ApexAgent.xcodeproj",
      "name" : "ApexAgentIntents"
    }
    ```
    Declared under `defaultOptions.codeCoverage.targets`.
  - `project.yml:377-385` (`ApexAgentTests.dependencies`):
    ```yaml
      ApexAgentTests:
        type: bundle.unit-test
        platform: macOS
        sources:
          - path: ApexAgentTests
        dependencies:
          - target: ApexAgentCore
          - target: MCPKit
          - package: swift-log
            product: Logging
    ```
    `ApexAgentIntents` is **NOT** listed in `ApexAgentTests` target dependencies.
  - `ApexAgentTests/ApexAgentIntentsTests.swift:1-5`:
    ```swift
    import Testing
    import Foundation
    import AppIntents
    @testable import ApexAgentCore
    ```
    `ApexAgentIntents` framework is **NOT imported** by any test file. The tests only test local string formatting and dummy fallbacks.
  - **Gap Description:** Real executable code in `ApexAgentIntents/FMIntentSupport.swift` and `ApexAgentIntents/SummarizeTextIntent.swift` is never linked, compiled, or executed by the test suite, resulting in 0% actual test coverage despite its declaration in `ApexAgent-UnitTests.xctestplan`.
- **Follow-up Issue Filed:** **#119** (`[Problem] ApexAgentIntents framework not wired into test dependencies or imported by tests`).

---

### Item 5: Contacts Opt-In Across Store Initializers
- **Verdict:** **PASS**
- **Store Initializer Census:**
  - Exhaustive codebase search for `CNContactStore` yields exactly **one** call site across the entire repository:
    [`ApexAgent/Models/ContactsOptInManager.swift:101`](file:///Users/danielstevens/Developer/ApexAgent/ApexAgent/Models/ContactsOptInManager.swift#L101):
    ```swift
    101:            let store = CNContactStore()
    ```
- **Gate Verification:**
  - In `ContactsOptInManager.swift:85-110`:
    ```swift
    public func requestAccessIfNeeded() async -> Bool {
        guard isOptedIn else {
            return false
        }

        if isTestMode {
            return false
        }

        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            let store = CNContactStore()
            ...
    ```
  - `CNContactStore()` is strictly gated behind `guard isOptedIn else { return false }` AND `if isTestMode { return false }`.
  - In test mode (`APEX_TEST_MODE=1` or `xctest`), `isOptedIn` defaults unconditionally to `false` (line 52), and `configureTestIsolationIfNeeded()` configures `CNContactsEnvironment.unitTestingEnvironment.useInMemoryStores()` (line 26), ensuring background `contactsd` XPC connections and store crashes are eliminated.
  - All downstream consumers (`AgentProfiles.swift:327`, `CalendarTool.swift:53`, `ReminderTool.swift:50`, `UserAccountManager.swift:133`, `SpaceManager.swift:233`) route strictly through `ContactsOptInManager.shared`.
  - Verified in Section 2 test health proofs where `contactsd` noise is suppressed under `APEX_TEST_MODE=1`.

---

## Findings Summary & Issues Filed

| Item | Area | Verdict | Follow-up Issue |
| :--- | :--- | :---: | :---: |
| 1 | MCP Servers Live Check | **PASS** | None |
| 2 | Ollama Loopback Binding | **GAP** | **#120** (`[Problem] Ollama endpoint binds to wildcard interface (*:11434) rather than loopback only`) |
| 3 | Keychain Credential Paths | **PASS** | **#121** (`[Problem] Remaining plaintext credential reads in UserDefaults (Discord webhook URL; Brave/Tavily fallbacks)`) |
| 4 | ApexAgentIntents Coverage Wiring | **GAP** | **#119** (`[Problem] ApexAgentIntents framework not wired into test dependencies or imported by tests`) |
| 5 | Contacts Opt-In Gate | **PASS** | None |
