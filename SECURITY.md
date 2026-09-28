# Security: Gemini API Key Migration & Secure Deletion

## Overview

ApexAgent stores the Gemini API key in the macOS Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). Prior versions stored it in plaintext locations. When a user upgrades to the Keychain-backed version, legacy plaintext keys are migrated and the originals are securely deleted.

## Legacy Storage Locations

| Location | Key | Risk |
|---|---|---|
| `~/.apex/gemini_key` | Plaintext file | High — readable by any process with file access |
| `UserDefaults` | `apex.geminiKey` / `geminiAPIKey` | Medium — stored in plist, no encryption |

## Migration Flow

### On `geminiAPIKey()` lookup

1. Check Keychain for `geminiAPIKey` → return if found
2. Check Keychain for `apex.geminiKey` → return if found
3. Check `GEMINI_API_KEY` env var → return if set (no migration, env takes priority)
4. Check `~/.apex/gemini_key` file → if found, treat as legacy key
5. Check `UserDefaults` for `apex.geminiKey` / `geminiAPIKey` → if found, treat as legacy key
6. If a legacy key was found:
   - **File source**: securely delete the file (overwrites with random data, then removes) before using the key
   - **UserDefaults source**: purge the entries
   - Save the key to Keychain under both `geminiAPIKey` and `apex.geminiKey`
7. Return the key

### On `saveGeminiAPIKey(_:)`

- Saves to Keychain under both key names
- Purges UserDefaults entries
- Securely deletes any existing `~/.apex/gemini_key` file

### One-time cleanup (`performLegacyKeyCleanupIfNeeded`)

Called on first access to `geminiAPIKey()`. If a legacy file exists but no migration was triggered (e.g., the user upgraded without configuring Gemini yet), the file is securely deleted anyway. Guarded by `UserDefaults` flag `apex.legacyKeyCleanupDone` so it runs exactly once.

## Secure Deletion Implementation

`KeychainManager.secureDeleteFile(at:passes:)`

- Reads the file size
- Generates cryptographically secure random data of the same size
- Writes it over the file (single pass by default — sufficient for SSDs)
- Optionally repeats for additional passes (for HDD compatibility)
- Removes the file via `FileManager.default.removeItem(at:)`

**Why single-pass:** SSDs use wear-leveling and TRIM, making multi-pass overwriting unreliable (the physical blocks being overwritten may differ from the logical blocks the filesystem sees). A single-pass random overwrite followed by removal is the recommended approach for SSDs. On HDDs, callers can increase `passes`.

**Fallback:** If the overwrite fails (e.g., permissions), `removeItem` is attempted as a best-effort cleanup. The caller can check the `Bool` return value if forensic certainty matters.

## Code Location

- `Models/KeychainManager.swift` — `secureDeleteFile(at:passes:)` helper
- `Models/ModelRegistry.swift`:
  - `geminiAPIKey()` — migration on lookup (lines ~110-167)
  - `saveGeminiAPIKey(_:)` — cleanup on save (lines ~169-195)
  - `performLegacyKeyCleanupIfNeeded()` — one-time orphan cleanup (lines ~169-183)

## Threat Model

| Threat | Mitigation |
|---|---|
| Forensic recovery of plaintext file after upgrade | Secure overwrite + remove |
| Legacy file sitting dormant after upgrade (no Gemini configured) | One-time cleanup on first `geminiAPIKey()` call |
| Race condition during migration | `geminiKeyMutex` serializes read-migrate-write in `geminiAPIKey()` and delete in `saveGeminiAPIKey()` |
| Key left in UserDefaults after migration | Explicitly purged in both paths |

## 2026-09-24 — Keychain Plaintext-Mirror Issue (Audit C1)

The 2026-09-24 project audit (AUDIT_2026-09-24.md, finding C1) found that `KeychainManager.save(key:value:)` was writing every secret to the Keychain **and then unconditionally mirroring it into plaintext `UserDefaults`** (keys `secure.<key>`), while `get(key:)` preferred the in-memory fallback, then the **plaintext** UserDefaults value, and only then the Keychain — and `save` reported Keychain success even when the Keychain write failed. This silently undermined the Keychain narrative above: every "keychained" secret (Gemini/Tavily/Brave keys, tokens) sat in cleartext in `~/Library/Preferences/…`.

**Remediation (fix session, 2026-09-24):** the `UserDefaults` mirror was removed from `KeychainManager`; `save` now reports the real Keychain result; any pre-existing `secure.*` plaintext values found in `UserDefaults` are migrated into the Keychain and the plaintext entries deleted.

**Verification pending:** the code fix is part of the concurrent 2026-09-24 fix session (see KeychainManager.swift after it lands). Do not treat C1 as closed until a green `swift build` + `swift test` confirms the new behavior.
