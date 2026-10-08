import Foundation
import Carbon
import SwiftUI

// MARK: - Menu Commands & Keyboard Shortcut Registry (Batch 25)

/// Canonical menu/hotkey actions supported by ApexAgent.
public enum AppCommandAction: String, CaseIterable, Codable, Sendable {
    case newChat
    case commandPalette
    case globalPaletteHotKey
    case showDiagnostics
    case goRoutines
    case goSkills
    case goSettings

    public var title: String {
        switch self {
        case .newChat: return "New Conversation"
        case .commandPalette: return "Command Palette…"
        case .globalPaletteHotKey: return "Global Command Palette"
        case .showDiagnostics: return "System Diagnostics…"
        case .goRoutines: return "Routines"
        case .goSkills: return "Skills"
        case .goSettings: return "Settings…"
        }
    }
}

/// Modifier keys for a `ShortcutBinding`.
public enum ShortcutModifier: String, Codable, Hashable, CaseIterable, Sendable {
    case command
    case shift
    case option
    case control
}

/// Key + modifier combination with both SwiftUI and Carbon representations.
public struct ShortcutBinding: Codable, Equatable, Hashable, Sendable {
    public let key: String
    public let modifiers: Set<ShortcutModifier>
    public let carbonKeyCode: UInt32

    public init(
        key: String,
        modifiers: Set<ShortcutModifier>,
        carbonKeyCode: UInt32 = 0
    ) {
        self.key = key.lowercased()
        self.modifiers = modifiers
        self.carbonKeyCode = carbonKeyCode
    }

    /// Carbon modifier mask (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`).
    public var carbonModifierFlags: UInt32 {
        var mask: UInt32 = 0
        if modifiers.contains(.command) { mask |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { mask |= UInt32(shiftKey) }
        if modifiers.contains(.option) { mask |= UInt32(optionKey) }
        if modifiers.contains(.control) { mask |= UInt32(controlKey) }
        return mask
    }

    /// SwiftUI `EventModifiers` equivalent.
    public var swiftUIModifiers: SwiftUI.EventModifiers {
        var result: SwiftUI.EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.control) { result.insert(.control) }
        return result
    }

    /// Human-readable shortcut badge (e.g. `⌘N`, `⌥Space`, `⌘⇧D`).
    public var displayString: String {
        var parts = ""
        if modifiers.contains(.control) { parts += "⌃" }
        if modifiers.contains(.option) { parts += "⌥" }
        if modifiers.contains(.shift) { parts += "⇧" }
        if modifiers.contains(.command) { parts += "⌘" }
        let keyLabel = key == "space" || key == " " ? "Space" : key.uppercased()
        return parts + keyLabel
    }
}

/// Represents a collision where two or more actions share the same key and modifiers.
public struct ShortcutConflict: Sendable, Equatable {
    public let actions: [AppCommandAction]
    public let key: String
    public let modifiers: Set<ShortcutModifier>

    public init(actions: [AppCommandAction], key: String, modifiers: Set<ShortcutModifier>) {
        self.actions = actions
        self.key = key
        self.modifiers = modifiers
    }
}

/// Manages default and user-customized keyboard shortcuts with `UserDefaults`
/// persistence, pure conflict detection, and command dispatch.
public final class ShortcutRegistry: @unchecked Sendable {
    public static let shared = ShortcutRegistry()

    public static let defaultStorageKey = "apex.shortcutBindings.v1"

    public static let defaultBindings: [AppCommandAction: ShortcutBinding] = [
        .newChat: ShortcutBinding(key: "n", modifiers: [.command], carbonKeyCode: 45),
        .commandPalette: ShortcutBinding(key: "k", modifiers: [.command], carbonKeyCode: 40),
        .globalPaletteHotKey: ShortcutBinding(key: "space", modifiers: [.option], carbonKeyCode: 49),
        .showDiagnostics: ShortcutBinding(key: "d", modifiers: [.command, .shift], carbonKeyCode: 2),
        .goRoutines: ShortcutBinding(key: "1", modifiers: [.command], carbonKeyCode: 18),
        .goSkills: ShortcutBinding(key: "2", modifiers: [.command], carbonKeyCode: 19),
        .goSettings: ShortcutBinding(key: ",", modifiers: [.command], carbonKeyCode: 43)
    ]

    private let lock = NSLock()
    private let userDefaults: UserDefaults
    private let storageKey: String
    private var bindings: [AppCommandAction: ShortcutBinding]
    public private(set) var lastDispatchedAction: AppCommandAction?

    public init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = ShortcutRegistry.defaultStorageKey
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        self.bindings = Self.defaultBindings
        loadFromDefaults()
    }

    public func binding(for action: AppCommandAction) -> ShortcutBinding {
        lock.lock()
        defer { lock.unlock() }
        return bindings[action] ?? Self.defaultBindings[action]!
    }

    public func allBindings() -> [AppCommandAction: ShortcutBinding] {
        lock.lock()
        defer { lock.unlock() }
        return bindings
    }

    public func setBinding(_ binding: ShortcutBinding, for action: AppCommandAction) {
        lock.lock()
        bindings[action] = binding
        let snapshot = bindings
        lock.unlock()
        saveToDefaults(snapshot)
    }

    public func resetToDefaults() {
        lock.lock()
        bindings = Self.defaultBindings
        lock.unlock()
        userDefaults.removeObject(forKey: storageKey)
    }

    /// Pure conflict detector over any action-to-binding map.
    public static func detectConflicts(
        in map: [AppCommandAction: ShortcutBinding]
    ) -> [ShortcutConflict] {
        struct KeyCombo: Hashable {
            let key: String
            let modifiers: Set<ShortcutModifier>
        }
        var grouped: [KeyCombo: [AppCommandAction]] = [:]
        for (action, binding) in map {
            let normalizedKey = (binding.key == " " ? "space" : binding.key.lowercased())
            let combo = KeyCombo(key: normalizedKey, modifiers: binding.modifiers)
            grouped[combo, default: []].append(action)
        }

        return grouped.compactMap { combo, actions in
            guard actions.count > 1 else { return nil }
            let sorted = actions.sorted { $0.rawValue < $1.rawValue }
            return ShortcutConflict(actions: sorted, key: combo.key, modifiers: combo.modifiers)
        }
        .sorted { ($0.actions.first?.rawValue ?? "") < ($1.actions.first?.rawValue ?? "") }
    }

    public func conflicts() -> [ShortcutConflict] {
        Self.detectConflicts(in: allBindings())
    }

    /// Dispatches a menu or keyboard command action on the main actor.
    @MainActor
    public func dispatch(_ action: AppCommandAction, orchestrator: AgentOrchestrator? = nil) {
        lock.lock()
        lastDispatchedAction = action
        lock.unlock()

        switch action {
        case .newChat:
            let targetOrchestrator = orchestrator ?? AppDelegate.sharedOrchestrator
            targetOrchestrator.botManager?.activeBotId = nil
            SpaceManager.shared.activeSpaceId = nil
            targetOrchestrator.startNewConversation()
            NotificationCenter.default.post(name: NSNotification.Name("ApexAgent.focusChatInput"), object: nil)
        case .commandPalette, .globalPaletteHotKey:
            GlobalCommandPaletteController.shared.toggle()
        case .showDiagnostics:
            DeepLinkNavigationState.shared.apply(.diagnostics)
        case .goRoutines:
            DeepLinkNavigationState.shared.apply(.routine(id: "all"))
        case .goSkills:
            DeepLinkNavigationState.shared.apply(.skill(name: "all"))
        case .goSettings:
            DeepLinkNavigationState.shared.apply(.settings)
        }
        AppLog.info(.ui, "Dispatched command action: \(action.rawValue)")
    }

    // MARK: - Persistence

    private func loadFromDefaults() {
        guard let data = userDefaults.data(forKey: storageKey),
              let rawMap = try? JSONDecoder().decode([String: ShortcutBinding].self, from: data) else {
            return
        }
        lock.lock()
        for (rawKey, value) in rawMap {
            if let action = AppCommandAction(rawValue: rawKey) {
                bindings[action] = value
            }
        }
        lock.unlock()
    }

    private func saveToDefaults(_ snapshot: [AppCommandAction: ShortcutBinding]) {
        var rawMap: [String: ShortcutBinding] = [:]
        for (action, value) in snapshot {
            rawMap[action.rawValue] = value
        }
        if let data = try? JSONEncoder().encode(rawMap) {
            userDefaults.set(data, forKey: storageKey)
        }
    }
}
