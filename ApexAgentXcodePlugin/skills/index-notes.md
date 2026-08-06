---
name: index-notes
description: Tell the Xcode agent how ApexAgent's memory/search tools work so it can surface relevant notes, Spotlight results, and persisted reviews during a task.
---

# ApexAgent Index & Retrieval

ApexAgent integrates several retrieval surfaces that the Xcode agent can rely on:

- **SpotlightSearchTool** — queries the user's Spotlight index (NSMetadataQuery).
  Wrap time-sensitive lookups here rather than guessing file paths.
- **CoreSpotlight RAG** — when available on the deployment OS, ApexAgent can
  retrieve semantically similar notes via CoreSpotlight. On the current macOS 27
  beta this API is not yet present in the SDK; the `LocalRetrievalIndex` protocol
  in ApexAgentCore is guarded behind a runtime availability check and degrades to
  Spotlight-only. Do NOT assume CoreSpotlight RAG symbols exist when compiling.
- **DynamicToolbox** — user-installed dynamic tools registered at runtime; check
  `DynamicToolbox.shared.dynamicTools` before assuming a tool name is static.
