import Testing
import Foundation
import Carbon
@testable import ApexAgentCore

@Suite("ShortcutRegistryTests", .serialized)
struct ShortcutRegistryTests {

    private func makeIsolatedRegistry() -> (ShortcutRegistry, UserDefaults, String) {
        let suiteName = "com.apexagent.tests.shortcuts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let registry = ShortcutRegistry(userDefaults: defaults, storageKey: "test.shortcuts")
        return (registry, defaults, suiteName)
    }

    @Test func defaultsExistForEveryActionWithNoConflicts() {
        let (registry, defaults, suiteName) = makeIsolatedRegistry()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for action in AppCommandAction.allCases {
            let binding = registry.binding(for: action)
            #expect(!binding.key.isEmpty)
            #expect(!binding.modifiers.isEmpty)
            #expect(!binding.displayString.isEmpty)
        }

        #expect(registry.binding(for: .newChat).displayString == "⌘N")
        #expect(registry.binding(for: .commandPalette).displayString == "⌘K")
        #expect(registry.binding(for: .globalPaletteHotKey).displayString == "⌥Space")
        #expect(registry.binding(for: .globalPaletteHotKey).carbonKeyCode == 49)
        #expect(registry.binding(for: .globalPaletteHotKey).carbonModifierFlags == UInt32(optionKey))
        #expect(registry.binding(for: .showDiagnostics).displayString == "⇧⌘D")
        #expect(registry.binding(for: .goRoutines).displayString == "⌘1")
        #expect(registry.binding(for: .goSkills).displayString == "⌘2")
        #expect(registry.binding(for: .goSettings).displayString == "⌘,")

        #expect(registry.conflicts().isEmpty)
    }

    @Test func persistenceRoundTripAcrossInstancesViaRealUserDefaultsSuite() {
        let (writer, defaults, suiteName) = makeIsolatedRegistry()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let custom = ShortcutBinding(key: "p", modifiers: [.command, .shift], carbonKeyCode: 35)
        writer.setBinding(custom, for: .commandPalette)
        #expect(writer.binding(for: .commandPalette) == custom)

        let reader = ShortcutRegistry(userDefaults: defaults, storageKey: "test.shortcuts")
        #expect(reader.binding(for: .commandPalette) == custom)
        #expect(reader.binding(for: .commandPalette).displayString == "⇧⌘P")

        reader.resetToDefaults()
        let resetReader = ShortcutRegistry(userDefaults: defaults, storageKey: "test.shortcuts")
        #expect(resetReader.binding(for: .commandPalette) == ShortcutRegistry.defaultBindings[.commandPalette])
    }

    @Test func conflictDetectionFindsCollidingBindings() {
        let (registry, defaults, suiteName) = makeIsolatedRegistry()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Assign ⌘N to commandPalette so it collides with newChat (⌘N).
        let duplicateCmdN = ShortcutBinding(key: "n", modifiers: [.command], carbonKeyCode: 45)
        registry.setBinding(duplicateCmdN, for: .commandPalette)

        let conflicts = registry.conflicts()
        #expect(conflicts.count == 1)
        #expect(conflicts.first?.key == "n")
        #expect(conflicts.first?.modifiers == [.command])
        #expect(conflicts.first?.actions == [.commandPalette, .newChat])
    }

    @Test @MainActor func dispatchUpdatesNavigationStateAndRecordsAction() {
        let (registry, defaults, suiteName) = makeIsolatedRegistry()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        DeepLinkNavigationState.shared.reset()

        registry.dispatch(.showDiagnostics)
        #expect(registry.lastDispatchedAction == .showDiagnostics)
        #expect(DeepLinkNavigationState.shared.showDiagnostics == true)

        registry.dispatch(.goRoutines)
        #expect(registry.lastDispatchedAction == .goRoutines)
        #expect(DeepLinkNavigationState.shared.selectedRoutineId == "all")
        #expect(DeepLinkNavigationState.shared.showSettings == true)

        DeepLinkNavigationState.shared.reset()

        registry.dispatch(.goSkills)
        #expect(registry.lastDispatchedAction == .goSkills)
        #expect(DeepLinkNavigationState.shared.selectedSkillName == "all")
        #expect(DeepLinkNavigationState.shared.showSettings == true)

        DeepLinkNavigationState.shared.reset()

        registry.dispatch(.goSettings)
        #expect(registry.lastDispatchedAction == .goSettings)
        #expect(DeepLinkNavigationState.shared.showSettings == true)

        DeepLinkNavigationState.shared.reset()
    }
}
