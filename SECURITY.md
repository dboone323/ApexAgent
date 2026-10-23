# Credential Storage and CLI Safety

## Credential storage

Provider secrets are stored as generic-password items in the macOS Keychain using
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. `KeychainManager.save` returns
the Keychain write result and does not mirror values to `UserDefaults`. If Keychain
access fails, a value saved during the current process may remain available in
memory only; it is not persisted as a fallback.

Gemini's current Keychain account is `geminiAPIKey`. On first production lookup,
`ModelRegistry` attempts to migrate legacy values in this order:

1. The old Keychain account `apex.geminiKey`.
2. The legacy `UserDefaults` keys `apex.model.geminiAPIKey`, `apex.geminiKey`,
   and `geminiAPIKey`.
3. The legacy file `~/.apex/gemini_key`.

The destination is written before legacy values are removed. If the Keychain write
fails, the source is retained and a diagnostic is emitted. When a current Gemini
Keychain item already exists, duplicate legacy preferences and the legacy file are
removed without replacing the current item. Empty values delete the Keychain item.
The `GEMINI_API_KEY` environment variable remains an explicit runtime override.

Legacy file removal uses ordinary filesystem deletion. **It is not forensic secure
erasure**: APFS copy-on-write, snapshots, backups, and SSD wear-leveling prevent
software from guaranteeing physical removal of prior file contents. Users who
previously stored credentials in plaintext should rotate those credentials.

Legacy `secure.*` `UserDefaults` entries used by `KeychainManager` are migrated
lazily into the Keychain and removed only after a successful Keychain write.
Test processes use a PID-scoped Keychain service and a PID-scoped temporary
`.apex` data root for skills, memory, audit records, sandbox files, and related
state. Restricted MCP test clients also receive distinct temporary home
directories, preventing concurrent `npx` server launches from sharing mutable
package-install state. Automatic legacy migrations are disabled in test
processes, preventing tests from reading or modifying a developer's real
credential and app-data stores.

## CLI tool policy

`ApexAgent --cli <prompt>` runs without tools by default. Dynamic scripts are
disabled in that mode. Use `--allow-tools` only when tool execution is intentional;
`--no-tools` explicitly overrides it. CLI tool execution does not grant broad
filesystem access or automatically approve confirmations.

Example:

```bash
ApexAgent.app/Contents/MacOS/ApexAgent --cli "Summarize this text: ..."
ApexAgent.app/Contents/MacOS/ApexAgent --cli --allow-tools "List files in ~/Documents"
```

An empty CLI prompt is a usage error and exits with status 64 rather than opening
the graphical application.

## Relevant implementation and tests

- `ApexAgent/Models/KeychainManager.swift` — Keychain operations, in-memory-only
  fallback, legacy `secure.*` migration, and isolated legacy-file migration helper.
- `ApexAgent/Models/ModelRegistry.swift` — Gemini legacy migration and retrieval.
- `ApexAgent/Models/DynamicToolbox.swift` — central production/test storage paths;
  tests load and execute real script fixtures only from temporary directories.
- `ApexAgentIntelligenceTests/RuntimeContractTests.swift` — migration and A2A
  tests use isolated storage and do not access the user's credential account.

## Spaces-on-VM sandbox (Phase 4, 2026-10-23)

Spaces run in per-Space Tart VMs (`apex-space-<spaceID>`, softnet networking) cloned from the pristine `apex-base` image. No host credentials or Keychain enter the guest; the real repo enters as a read-only git bundle and results leave as a git bundle. The guest's allowlist egress proxy (`proxy.py`/`allowlist.txt`) is retired as of 2026-10-23 — the app flow does not reference it, and the files are archived at `~/ApexSandbox/archive-2026-10-23/`. Work lands only through the host-side landing gate (in-VM gate → additions-only test-integrity check → bundle verify → quarantine branch → host pristine re-run → manual merge).
