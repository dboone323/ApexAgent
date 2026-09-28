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
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer

# Xcodebuild (recommended for full macOS app & extensions):
xcodebuild build -project ApexAgent.xcodeproj -scheme ApexAgent -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO
xcodebuild test -project ApexAgent.xcodeproj -scheme ApexAgent -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO

# Or Swift Package Manager:
swift build
swift test
```

> **Note:** The Foundation Models framework does NOT work in the iOS/macOS Simulator. Run on a real device.

---

## 🔑 API Keys (Optional)

The on-device Apple Foundation Model needs **no key**. Keys are only needed for optional providers:

- **Google Gemini** — paste your key in **Settings**; stored in the Keychain.
- **Ollama** — point Apex at your local Ollama host URL (default `http://localhost:11434`).
- **Brave Search** (optional web search) — Brave primary with a no-config DuckDuckGo fallback. Add a Brave key in Settings for higher-quality results.

---

## 🧠 LLM Backends

- **On-device Apple Foundation Models** (default) — `NativeAppleEngine`
- **Private Cloud Compute** — Apple's PCC when available
- **Cloud Gemini** — optional, Keychain-backed
- **Local Ollama** — optional, self-hosted

Per-agent model preferences are supported (`localSystem` / `privateCloud` / `cloudGemini` / `localOllama` / `hybrid`).

---

## 🧰 Agent Capabilities

Apex ships **63 tools** the model can call, including:

| Tool | What It Does |
|------|-------------|
| 🐚 `run_shell_command` | Execute any zsh command, capture output |
| 📄 `read_file` / ✍️ `write_file` | Read/write files anywhere |
| 📁 `list_directory` / 📂 `create_directory` | Browse and create directories |
| 🗑️ `delete_file` / 🔀 `move_file` | Delete (to Trash) / move / rename files |
| 🔎 `file_search` | Search the filesystem |
| 🌐 `web_search` | Search the web (Brave → DDG fallback) |
| 🍎 `run_applescript` | Control any scriptable macOS app |
| 🖥️ `get_frontmost_app` / 📸 `take_screenshot` | Identify the active app / capture the screen |
| 📋 `read_clipboard` / `write_clipboard` | Read/set clipboard content |
| 🔔 `send_notification` | Send macOS notifications |
| ℹ️ `get_system_info` / 📊 `get_running_processes` | System & process info |
| 🧩 `application_control` / `accessibility_control` | Drive apps via Accessibility |
| 🌍 `browser_automation` | Automate the browser |
| 🖼️ `analyze_image` / `detect_image_text` | Multimodal vision + OCR |
| 🗂️ `audit_projects` | Audit Swift/Xcode projects in a workspace |
| 🧠 `store_memory` / `search_memory` | Persistent agent memory |
| 🤝 `delegate_task` | Delegate to a specialized sub-agent |
| 👥 `convene_meeting` | Multi-agent panel debate to consensus |
| 🛠️ `create_skill` / `run_workflow` | Author skills / run workflows |
| 🧱 `dynamic_tool_call` | Call MCP-registered dynamic tools |
| 📦 `container_status` | Container runtime status (Apple Silicon) |
| 📰 `daily_briefing` | Daily briefing from the shared data bus |
| 📝 `update_plan` | Maintain a live task plan |

---

## 🔌 Model Context Protocol (MCP)

Apex is an MCP client: it launches and supervises external MCP servers (filesystem, git, and any you configure in **Settings**) over stdio JSON-RPC, with circuit-breaking and auto-restart. Server workspace and interpreter paths are resolved at runtime — no hardcoded developer paths.

---

## 🎙️ Voice

Voice input/output is supported via on-device speech recognition and synthesis.

---

## 🤖 Multi-Agent

Specialized sub-agents (developer, executor, controller, researcher, planner, UI designer, linter) can be delegated to individually or convened in a panel meeting to reach consensus.

---

## 🛡️ Safety

- **Confirmation Gate** — Destructive actions (file deletion, dangerous shell commands, AppleScript) require explicit approval
- **60s Auto-deny** — Unreviewed confirmations are automatically denied
- **On-device by default** — With the Apple Foundation Model, your data never leaves your Mac
- **Sandbox fallback** — Apple Container / Docker sandbox fallback for execution contexts where needed

---

## 🎨 Agent Modes

Access via **Settings → Quick Modes**:
- **💻 Coding Mode** — Software development focused
- **🔍 Research Mode** — Heavy web search and synthesis
- **⚙️ System Mode** — Full system administration

Or edit the **System Prompt** directly in Settings to customize Apex's behavior.

---

## 🧪 Testing

Current test-target inventory (**103 test files**): `ApexAgentTests` 85 · `ApexAgentContainerTests` 1 · `ApexAgentIntelligenceTests` 10 · `ApexAgentUITests` 7 — covering the R1–R4 suites (creation sheets, playbook collaboration, container isolation security, MCP dashboard, E2E feature matrix, adversarial stress) plus real macOS UI e2e via XCUITest.

> **2026-09-24:** historical PASS claims are unverified for the current sources — the newest test artifacts predate the current test sources (2026-09-21). Run `swift test` on a green build before treating any result as green (see AUDIT_2026-09-24.md §7).

---

Built with ❤️ on Apple Foundation Models.
