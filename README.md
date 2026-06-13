# ⚡ Apex Agent

A fully local, privacy-first AI agent for macOS 26 (Golden Gate) — powered by **Apple Foundation Models (AFM 3 Core Advanced)**.

No cloud. No API keys needed. Everything runs on your Apple Silicon, using the same model that powers Apple Intelligence.

---

## 🚀 Getting Started

### Prerequisites
- macOS 26 (Golden Gate) or later
- Xcode 27 or later
- Apple Intelligence enabled in **System Settings → Apple Intelligence & Siri**
- Apple Silicon Mac (M1 or later)

### Open in Xcode
```bash
open ~/Developer/ApexAgent/ApexAgent.xcodeproj
```

1. Select the **ApexAgent** scheme
2. Set your **Development Team** in `Signing & Capabilities`
3. Press **⌘R** to run

> **Note:** The Foundation Models framework does NOT work in the iOS/macOS Simulator. You must run on a real device.

---

## 🔑 Web Search Setup (Optional)

Apex uses **Brave Search** (primary) with **DuckDuckGo** as a no-configuration fallback.

To enable Brave Search:
1. Create a free account at [api.search.brave.com](https://api.search.brave.com)
2. Get your API key (comes with $5/mo free credit ≈ 1,000 searches)
3. In Apex Agent → **Settings** → paste your key in "Brave Search API Key"

---

## 🧰 Agent Capabilities

| Tool | What It Does |
|------|-------------|
| 🐚 `run_shell_command` | Execute any zsh command, capture output |
| 📄 `read_file` | Read any file on your Mac |
| ✍️ `write_file` | Write/create files anywhere |
| 📁 `list_directory` | List directory contents with sizes |
| 📂 `create_directory` | Create directories |
| 🗑️ `delete_file` | Delete files (moves to Trash by default) |
| 🔀 `move_file` | Move or rename files |
| 🌐 `web_search` | Search the web (Brave → DDG fallback) |
| 🍎 `run_applescript` | Control any scriptable macOS app |
| 🖥️ `get_frontmost_app` | Identify the active application |
| 📸 `take_screenshot` | Capture your screen |
| 📋 `read_clipboard` | Read current clipboard |
| 📋 `write_clipboard` | Set clipboard content |
| 🔔 `send_notification` | Send macOS notifications |
| ℹ️ `get_system_info` | OS, hardware, disk, RAM info |
| 📊 `get_running_processes` | List running applications |

---

## 🛡️ Safety

- **No App Sandbox** — Apex has full system access (required for a capable agent)
- **Confirmation Gate** — Destructive actions (file deletion, dangerous shell commands) require your explicit approval
- **60s Auto-deny** — Unreviewed confirmations are automatically denied
- **On-device only** — Your data never leaves your Mac

---

## 🎨 Agent Modes

Access via **Settings → Quick Modes**:
- **💻 Coding Mode** — Software development focused
- **🔍 Research Mode** — Heavy web search and synthesis
- **⚙️ System Mode** — Full system administration

Or edit the **System Prompt** directly in Settings to customize Apex's behavior.

---

## 🗂️ Project Structure

```
ApexAgent/
├── ApexAgent.xcodeproj/
├── ApexAgent/
│   ├── ApexAgentApp.swift          # App entry point
│   ├── AgentOrchestrator.swift     # Core agent engine
│   ├── AgentSystemPrompt.swift     # Persona & instructions
│   ├── ApexAgent.entitlements      # System access entitlements
│   ├── Info.plist
│   ├── Tools/
│   │   ├── ShellTool.swift
│   │   ├── FileSystemTools.swift
│   │   ├── WebSearchTool.swift
│   │   ├── AppleScriptTool.swift
│   │   ├── ScreenshotTool.swift
│   │   ├── ClipboardTool.swift
│   │   ├── NotificationTool.swift
│   │   └── SystemInfoTool.swift
│   ├── UI/
│   │   ├── ContentView.swift
│   │   ├── ChatView.swift
│   │   ├── MessageBubble.swift
│   │   ├── ToolActivityView.swift
│   │   ├── ConfirmationOverlay.swift
│   │   └── SettingsView.swift
│   ├── Models/
│   │   └── ConversationModel.swift
│   └── Assets.xcassets/
└── README.md
```

---

## 🔮 Future Roadmap

- [ ] Conversation history sidebar with SwiftData
- [ ] Multimodal: pass screenshots directly to the model (WWDC 2026 API)
- [ ] Multiple agent personas / profiles
- [ ] MCP (Model Context Protocol) server integration
- [ ] Voice input via whisper / SpeechRecognizer
- [ ] Plugin system for community tools

---

Built with ❤️ using Apple Foundation Models (AFM 3 Core Advanced) — WWDC 2026
