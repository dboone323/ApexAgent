# APEXAGENT_PLAINTEXT_TOKEN_FIX_2026-10-26

## What changed

### 1. GitHub Copilot token migrated to Keychain
- `ApexAgent/Models/ModelRegistry.swift`: `copilotToken()` / `setCopilotToken()` now back onto `KeychainManager` account `githubToken`. `setCopilotToken` deletes the legacy UserDefaults key `apex.model.copilotToken`. `migrateCopilotTokenIfNeeded()` moves any pre-existing plaintext value into the Keychain and removes the plaintext copy on first read.
- `ApexAgent/Models/GitHubCopilotLanguageModel.swift`: `resolveGitHubToken()` first step now reads via `ModelRegistry.copilotToken()` (Keychain) instead of UserDefaults directly. Rest of chain unchanged (env, hosts.json, gh auth token).

### 2. Collaboration token migrated to Keychain
- `ApexAgent/Models/ModelRegistry.swift`: added `collabToken()` / `setCollabToken()` backed by Keychain account `collabToken`, with `migrateCollabTokenIfNeeded()` (legacy key `apex.collabToken`).
- `ApexAgent/UI/SettingsView.swift`: replaced both `@AppStorage("apex.collabToken")` declarations with `@State` backed by `ModelRegistry.collabToken()` / `setCollabToken()`, with onAppear load + onChange persist. UI field and behaviour unchanged.

### 3. GitHub tool token leak removed
- `ApexAgent/Tools/GitHubTool.swift`: the `auth` action's `token` sub-action no longer runs `gh auth token` or returns a raw token; it now throws "disabled to prevent token leakage". Default error message updated to `status, login`. No other callers requested the sub-action.

### 4. Tests (add-only)
- `ApexAgentTests/PlaintextTokenFixTests.swift`: asserts migration removes plaintext from UserDefaults for both tokens, resolves from Keychain, and setCopilotToken leaves no plaintext.

## Migration pattern used
Follows the existing C1 pattern: if a value exists in the legacy store (UserDefaults) and none in the Keychain, save it to the Keychain, then delete the plaintext copy; if a Keychain value already exists, just delete the plaintext copy. No plaintext copy is retained.

## Gate
- Lint solo: ✅ 23 changed .swift files passed.
- Full unit test plan: test target did not build due to a pre-existing uncommitted file `ApexAgentTests/VMRoutingLiveTests.swift` referencing `TestLog` out of scope (unrelated to this change; VM/seed code untouched). App target builds successfully (`** BUILD SUCCEEDED **`).
- No commit or push performed.

## Verification of plaintext copies gone
- New tests assert `UserDefaults.standard.string(forKey:)` returns nil after migration and `KeychainManager.get(key:)` returns the value.
- `setCopilotToken` / `setCollabToken` remove the legacy UserDefaults keys on every write.
