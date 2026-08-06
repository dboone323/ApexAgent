---
name: run-agent-task
description: Delegate a coding task to ApexAgent's orchestrator. Use when the user asks Xcode to implement a feature, fix a bug, or run a multi-step workflow that ApexAgent can execute against the workspace.
---

# Run an Agent Task

ApexAgent is a local, on-device agentic coding system. Its `AgentOrchestrator`
drives tools through an `LanguageModelSession` and can call any registered tool.

## When to use
- "Add a feature that …", "Fix the bug in …", "Refactor …"
- Any multi-step coding task that benefits from tool use (file read/write, shell,
  search, git, code review).

## How it maps to ApexAgent
- The task text becomes the `prompt` sent to `AgentOrchestrator.sendMessage(_:)`.
- Tool-calling mode is selected via `AgentToolCallingMode` (`.auto` / `.required`
  / `.disabled`); default `.auto` so the model may invoke tools.
- ApexAgent already conforms to Apple's `LanguageModel` protocol for Apple
  on-device, Apple PCC, Cloud Gemini, Local Ollama, and Local MLX — switching
  the backend is a one-line model selection in `ModelRegistry`.

## Guardrails
- ApexAgent runs locally; it can modify the workspace. Confirm destructive
  operations (deletes, force-push) before executing.
- Respect the app's entitlement model: container/VM features require the
  virtualization entitlement and cannot run inside Xcode's test host.
