# Privacy Architecture & Data Governance

ApexAgent is engineered with a strict **local-first, zero-telemetry default** privacy architecture. User privacy and operational confidentiality are foundational design constraints across all app targets, background daemons, and CLI tooling.

---

## 1. Local-Only Processing & Data Storage

All user context, conversation histories, vector databases, file indexes, knowledge graphs, and workspace configurations reside strictly on the local macOS file system:

- **Local Storage Paths**:
  - Application configuration and session databases: `~/Library/Application Support/ApexAgent/`
  - Workspace bookmarks and user-granted directories: resolved exclusively via macOS security-scoped bookmarks.
  - Keychain items (API keys, account tokens): stored exclusively in Apple Keychain Services with access controls tied to the app bundle identifier.
- **On-Device Search & Vector Memory**:
  - Vector embeddings, SQLite databases, and Lucene/keyword indexes execute completely on-device without phoning home.

---

## 2. External Provider Boundaries (Data Leaving Mac)

ApexAgent does not transmit any user data, prompt contents, or file data to external servers by default. Data leaves the user's Mac **only** when an external cloud model provider is explicitly configured and invoked by the user:

- **Configured Model Providers**:
  - **Ollama**: 100% on-device / local network (`http://localhost:11434` or custom LAN address). Zero data leaves your machine or local network.
  - **Google Gemini**: Prompts, tool results, and multimodal attachments are transmitted directly to Google's Gemini API endpoints using user-provided API credentials. No intermediary telemetry or proxy services are used.
  - **Anthropic Claude**: Prompts and tool payloads are sent directly to Anthropic API endpoints using user-provided API credentials.
  - **OpenAI / Custom Compatible**: Transmitted directly to configured API base URLs with user-supplied API keys.
- **Direct Client-to-API Architecture**:
  - ApexAgent operates with direct client-to-API communication. There are no proprietary relays, middlebox servers, or user-data harvesting proxies between the Mac client and the configured model provider.

---

## 3. Telemetry, MetricKit, and Field Diagnostics

ApexAgent has a **zero-telemetry default**:

- **No Remote Telemetry**:
  - ApexAgent does **not** include remote analytics SDKs, advertising trackers, user identity brokers, or third-party behavioral monitors.
  - `NSPrivacyTracking` in `PrivacyInfo.xcprivacy` is set to `false`.
  - `NSPrivacyTrackingDomains` is empty (`[]`).
- **MetricKit Local Diagnostics**:
  - Diagnostic observations (crash reports, CPU exceptions, hang reports, disk writes) delivered by macOS `MetricKit` are processed on-device by `MetricDiagnosticsCenter`.
  - All stack traces and memory payload strings are sanitized and PII-scrubbed locally (`CrashReportPackager`) before being written to local diagnostic files in Application Support.
  - Diagnostic dumps are exported only on explicit user request via the `ApexAgent diagnostics` CLI command or the in-app Diagnostics View.

---

## 4. Hardware & System Resource Permissions (TCC)

ApexAgent requests macOS privacy permissions only when strictly necessary to fulfill user-directed actions. All permissions include descriptive strings in `ApexAgent/Info.plist`:

| Permission / Key | Purpose | Default State |
| :--- | :--- | :--- |
| **Calendars** (`NSCalendarsUsageDescription`) | Read and create calendar events per user request. | Opt-in / System prompt |
| **Reminders** (`NSRemindersUsageDescription`) | Read and manage task reminders per user request. | Opt-in / System prompt |
| **Contacts** (`NSContactsUsageDescription`) | Access contacts for address resolution and event scheduling. | **Disabled by default** (`ContactsOptInManager`, opt-in required) |
| **Microphone** (`NSMicrophoneUsageDescription`) | Real-time speech input for voice conversation sessions. | System prompt on voice activation |
| **Speech Recognition** (`NSSpeechRecognitionUsageDescription`) | Speech-to-text processing for voice commands. | System prompt on voice activation |
| **Screen Recording** (`NSScreenCaptureDescription`) | Screen analysis for computer-use and visual context tools. | User-granted in System Settings |
| **Accessibility** | Computer-use input automation (synthetic key and mouse events). | User-granted in System Settings |
| **Local Network** (`NSLocalNetworkUsageDescription`) | Connect to local LLM engines (Ollama) and local team servers. | System prompt on local network dial |

---

## 5. Apple Privacy Manifest Declaration Summary

In compliance with Apple's developer privacy guidelines, `ApexAgent/Resources/PrivacyInfo.xcprivacy` explicitly declares:

1. **`NSPrivacyTracking`**: `false`
2. **`NSPrivacyTrackingDomains`**: Empty
3. **`NSPrivacyCollectedDataTypes`**:
   - `NSPrivacyCollectedDataTypeOtherUserContent`: Local user prompt context and workspace interaction.
   - `NSPrivacyCollectedDataTypeAudioData`: On-device voice input for voice interaction mode.
   - `NSPrivacyCollectedDataTypeCrashData`: On-device MetricKit crash reports.
   - `NSPrivacyCollectedDataTypePerformanceData`: On-device MetricKit launch and responsiveness metrics.
   - `NSPrivacyCollectedDataTypeContacts`: Address book details accessed only after explicit user opt-in.
4. **`NSPrivacyAccessedAPITypes`**:
   - `NSPrivacyAccessedAPICategoryUserDefaults`: Preferences and feature toggles (`CA92.1`, `1C8F.1`).
   - `NSPrivacyAccessedAPICategoryFileTimestamp`: File modification checks for cache freshness (`C617.1`, `0A2A.1`).
   - `NSPrivacyAccessedAPICategoryDiskSpace`: Volume capacity checks before disk-intensive operations (`E174.1`, `85F4.1`).
