import Foundation

/// Global, app-wide tool allowlist (WS5.6).
///
/// `SpecializedAgentProfile` already gates tools per-agent via `allowedTools`.
/// `ToolPolicy` adds a second, independent layer: a user/settings-controlled
/// global kill-switch that can disable a tool for *every* agent at once (e.g.
/// forbid `run_shell_command` app-wide). A tool is only available when BOTH
/// the per-agent allowlist and this global policy permit it.
///
/// Backed by `UserDefaults` (`apex.deniedTools` — the single key shared with
/// `AgentSecurity`'s runtime deny list; unified per AUDIT_2026-09-28 §3.4.35)
/// so a Settings UI can toggle
/// individual tools at runtime without a rebuild. Defaults to "all tools
/// enabled" so existing behavior is unchanged.
///
/// Implemented as a `final class` with `nonisolated` accessors: the policy is a
/// pure in-memory set mirrored to UserDefaults, so it can be consulted
/// synchronously from profile construction (no actor hop required).
public final class ToolPolicy: @unchecked Sendable {
    public static let shared = ToolPolicy()

    private static let userDefaultsKey = "apex.deniedTools"

    private let lock = NSLock()
    private var disabledTools: Set<String>

    private init() {
        if let saved = UserDefaults.standard.array(forKey: Self.userDefaultsKey) as? [String] {
            self.disabledTools = Set(saved)
        } else {
            self.disabledTools = []
        }
    }

    /// Whether a tool is permitted app-wide (true unless explicitly disabled).
    @discardableResult
    public nonisolated func isGloballyAllowed(_ toolName: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !disabledTools.contains(toolName)
    }

    /// Enable or disable a tool app-wide. Updates the persisted set.
    public nonisolated func setToolEnabled(_ toolName: String, enabled: Bool) {
        lock.lock()
        if enabled {
            disabledTools.remove(toolName)
        } else {
            disabledTools.insert(toolName)
        }
        let snapshot = Array(disabledTools)
        lock.unlock()
        UserDefaults.standard.set(snapshot, forKey: Self.userDefaultsKey)
    }

    /// Currently disabled tool names (for Settings UI display).
    public nonisolated func disabledToolNames() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(disabledTools).sorted()
    }

    /// Test helper: reset to the default (all enabled) state.
    public nonisolated func reset() {
        lock.lock()
        disabledTools.removeAll()
        lock.unlock()
        UserDefaults.standard.removeObject(forKey: Self.userDefaultsKey)
    }
}
