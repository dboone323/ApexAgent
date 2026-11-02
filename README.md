# ⚡ Apex Agent

A privacy-first AI personal assistant for macOS 27+ — powered primarily by **Apple Foundation Models** running **on-device** on Apple Silicon.

The default LLM is Apple's on-device Foundation Model (no cloud, no key). You can optionally route agents to **Google Gemini** or a local **Ollama** server; their credentials are stored securely in the macOS **Keychain**, never in plaintext.

---

## 🚀 Getting Started

### Prerequisites
- macOS 27
- Xcode 27 Beta or later (Swift 6.4)
- Apple Intelligence enabled in **System Settings → Apple Intelligence & Siri**
- Apple Silicon Mac (M1 or later)

### Open in Xcode
```bash
open ApexAgent.xcodeproj
```

1. Select the **ApexAgent** scheme
2. Set your **Development Team** in `Signing & Capabilities`
3. Press **⌘R** to run

Or build/test from the command line:
```bash
# Xcodebuild (entitlement-preserving ad-hoc signing "-" embeds ApexAgent.entitlements):
xcodebuild build -project ApexAgent.xcodeproj -scheme ApexAgent -destination "platform=macOS"
xcodebuild test -project ApexAgent.xcodeproj -scheme ApexAgent -testPlan ApexAgent-UnitTests -destination "platform=macOS"
xcodebuild test -project ApexAgent.xcodeproj -scheme ApexAgent -testPlan ApexAgent-UITests -destination "platform=macOS"

# Or Swift Package Manager (with code coverage and zero skipped tests):
xcrun swift build
xcrun swift test --parallel --enable-code-coverage
```

> **Note:** The Foundation Models framework does NOT work in the iOS/macOS Simulator. Run on a real device.

### Command-line prompts

The app's one-shot CLI runs with tools disabled by default. To enable tool calls,
pass `--allow-tools` explicitly; `--no-tools` always disables them. Empty prompts
are rejected with exit status 64 instead of launching the GUI.

```bash
ApexAgent.app/Contents/MacOS/ApexAgent --cli "Explain this Swift error"
ApexAgent.app/Contents/MacOS/ApexAgent --cli --allow-tools "Search the workspace"
```

---

## 🔑 API Keys (Optional)

The on-device Apple Foundation Model needs **no key**. Keys are only needed for optional providers:

- **Google Gemini** — paste your key in **Settings**; stored in the Keychain.
- **Ollama** — point Apex at your local Ollama host URL (default `http://localhost:11434`, default fast/research model `gemma4:12b`, coding/automation model `qwen2.5-coder:7b`, with multimodal vision + `nomic-embed-text:latest` for semantic memory embeddings).
- **Brave Search** (optional web search) — Brave primary with a no-config DuckDuckGo fallback. Add a Brave key in Settings for higher-quality results.

---

## 🧠 LLM Backends

- **Auto Model Picker** (default) — intelligent dynamic routing: AFM 3 → Cloud Gemini → Ollama with task tiering & single-active-local-weights policy
- **On-device Apple Foundation Models** — `NativeAppleEngine`
- **Private Cloud Compute** — Apple's PCC when available
- **Cloud Gemini** — optional, Keychain-backed (`gemini-3.8-flash`, `gemini-3.1-pro`, `gemini-2.5-pro`)
- **Local Ollama** — optional, self-hosted (`gemma4:12b` default, `qwen2.5-coder:7b` coding/automation, with multimodal image attachments + `nomic-embed-text:latest` embeddings)
- **Local MLX-LM** — Apple Silicon metal-optimized local inference
- **Apple FoundationModels CLI** (`fmCLI`)
- **OpenAI-Compatible REST** / **Anthropic Claude** / **GitHub Copilot**

Per-agent model preferences are supported (`autoPicker` / `appleOnDevice` / `applePCC` / `cloudGemini` / `localOllama` / `localMLX` / `fmCLI` / `openAICompatible` / `anthropic` / `gitHubCopilot`).

---

## 🧰 Agent Capabilities

Apex ships **78 static tools** registered in `ToolDispatchEngine.buildAllTools` (verified by census: 78 `AnyExecutableTool(...)` registrations and 78 unique `let name = "..."` identifiers; `AgentSecurity.toolRiskMap` has 80 entries, one unregistered `container_status`).

| Tool | What It Does |
|------|-------------|
| 🐚 `run_shell_command` | Execute any zsh command, capture output |
| 📄 `read_file` / ✍️ `write_file` | Read/write files anywhere |
| 🩹 `patch_file` / ⏪ `rollback_file` | Apply unified diff patches / rollback snapshots |
| 📁 `list_directory` / 📂 `create_directory` | Browse and create directories |
| 🗑️ `delete_file` / 🔀 `move_file` | Delete (to Trash) / move / rename files |
| 🔎 `file_search` / 🔦 `spotlight_search` | Search the filesystem / Spotlight metadata query |
| 🌿 `git_operation` | Inspect git status, branches, commits, diffs |
| 🌐 `web_search` / 📖 `web_reader` | Search the web (Brave → DDG) / scrape page content |
| 🍎 `run_applescript` | Control any scriptable macOS app |
| 🖥️ `get_frontmost_app` / 📸 `take_screenshot` | Identify the active app / capture the screen |
| 📋 `read_clipboard` / `write_clipboard` | Read/set clipboard content |
| 🔔 `send_notification` | Send macOS notifications |
| ℹ️ `get_system_info` / 📊 `get_running_processes` | System & process info |
| 🧩 `control_app` / `control_accessibility` | Drive apps via Accessibility & UI automation |
| 🌍 `control_browser` | Headless WebKit browser automation with persistent session |
| 🖼️ `analyze_image` / `detect_image_text` | Multimodal vision + OCR |
| 🗂️ `audit_projects` | Audit Swift/Xcode projects in a workspace |
| 🧠 `store_memory` / `search_memory` / `delete_memory` | Persistent agent memory & embeddings |
| 🤖 `ask_bot` / 🤝 `delegate_task` | Ask or delegate to a specialized bot with peer review |
| 🐝 `dispatch_swarm` | Fan-out concurrent execution to a multi-bot swarm |
| 👥 `convene_meeting` | Multi-agent panel debate to consensus |
| 🛠️ `create_skill` / `run_workflow` | Author skills / run automated workflows |
| 🧱 `execute_dynamic_tool` | Call MCP-registered dynamic tools |
| 📦 `manage_sandbox` | Apple Silicon container / sandbox lifecycle management |
| 📰 `daily_briefing` | Daily briefing from the shared data bus |
| 📝 `update_plan` | Maintain a live task plan |

---

## 🔌 Model Context Protocol (MCP)

Apex is an MCP client: it launches and supervises external MCP servers (filesystem, git, `xcodebuildmcp`, `xcode-native` via `xcrun mcpbridge`, and any you configure in **Settings**) over stdio JSON-RPC, with circuit-breaking, live latency probing, and auto-restart. It also ships the `ApexAgentXcodePlugin` MCP server for Xcode 27 with live Spotlight (`mdfind`) search.

---

## 🎙️ Voice

Voice input/output is supported via on-device speech recognition and synthesis (`VoiceController`) across both `ChatView` and `BotChatView`.

---

## 🤖 Multi-Agent & Playbooks

Specialized bots (`Apex`, `Chief of Staff`, `Code Architect`, `Researcher`, `Automator`) can be delegated to individually, convened in a panel meeting, or orchestrated via multi-stage **Collaboration Playbooks** (`PlaybookRunner`) with sequential/parallel turn dispatching and interactive human-in-the-loop approval banners (`PlaybookApprovalBannerView`).

---

## 🛡️ Safety

- **Confirmation Gate** — Destructive actions (file deletion, dangerous shell commands, AppleScript) require explicit approval
- **60s Auto-deny** — Unreviewed confirmations are automatically denied
- **On-device by default** — With the Apple Foundation Model, your data never leaves your Mac
- **Sandbox Isolation** — Apple Container (`ContainerManager` + `sandboxctl` with `.strict`, `.standard`, `.ephemeralOverlay` isolation and APFS snapshots) / Docker sandbox support

---

## 🎨 Agent Modes

Access via **Settings → Quick Modes**:
- **💻 Coding Mode** — Software development focused
- **🔍 Research Mode** — Heavy web search and synthesis
- **⚙️ System Mode** — Full system administration

Or edit the **System Prompt** directly in Settings to customize Apex's behavior.

---

## 🧪 Testing

Current verified test-target inventory (as of 2026-10-30 — 272 test files · 1543 `@Test` functions · 44 `XCTestCase` classes):
- `ApexAgentTests`: 254 files (1465 `@Test` + 38 `XCTestCase`) — covering M1–M4 (`CreationSheetsTests`, `PlaybookCollaborationTests`, `R1R2AdversarialStressTests`, `ContainerIsolationSecurityTests`, `MCPServerDashboardTests`, `E2EFeatureMatrixTests`, `CognitiveMemoryTests`)
- `ApexAgentContainerTests`: 1 file (7 `@Test`) — `ContainerManagerTests`
- `ApexAgentIntelligenceTests`: 10 files (71 `@Test`) — on-device intelligence, vision, and runtime contracts
- `ApexAgentUITests`: 7 files (6 `XCTestCase`) — real macOS UI e2e via XCUITest

---

Built with ❤️ on Apple Foundation Models.
