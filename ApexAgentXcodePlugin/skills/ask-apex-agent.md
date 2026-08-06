---
name: ask-apex-agent
description: Ask ApexAgent a question or request analysis (code explanation, summarization, review) without modifying files. Use for "what does this do", "summarize", "review this change".
---

# Ask ApexAgent

For read-only questions and analysis, route to ApexAgent with tool-calling
disabled (`.disabled`) so it answers from context without taking actions.

## Supported capabilities (mirrored from ApexAgent's tools)
- `AnalyzeImageTool` — multimodal image understanding (Apple on-device vision or
  Cloud Gemini).
- `WeeklyReflectionTool` / `ConveneMeetingTool` — summarization of notes and
  meetings.
- `CodeReview*` tools — static defect scanning and persisted findings.

## Model selection
Prefer Apple on-device (`SystemLanguageModel.default`) for privacy; fall back to
Cloud Gemini or Local Ollama for larger context. `ModelRegistry.automatic`
replicates the legacy fallback chain.
