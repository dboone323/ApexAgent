import SwiftUI
import SwiftData

// MARK: - SkillsSection: persisted skill registry UI for Settings

/// Renders the list of dynamically-created and user-defined skills, mirroring
/// the ~/.apex/skills on-disk registry in a SwiftData-backed UI.  Each row
/// exposes the skill name, prompt preview, tool list, and enable/disable +
/// delete actions.
struct SkillsSection: View {
    /// The skill manager that bridges the SwiftData store and the toolbox.
    @Environment(SkillManager.self) private var managerskills: SkillManager

    /// View-model mirror of the currently-persisted skills (refreshed by the
    /// manager on every run).
    @Query(sort: \Skill.name) private var skills: [Skill]

    /// Tracking state for the two confirmation dialogs.
    @State private var isConfirmingDelete: Bool = false
    @State private var isConfirmingDisable: Bool = false
    @State private var isAddingSkill: Bool = false

    /// The skill currently being operated on (nil = none / cancelled).
    @State private var pendingSkill: Skill?

    var body: some View {
        Section("Skills") {
            if skills.isEmpty {
                EmptyView()
            } else {
                ForEach(skills) { skill in
                    SkillRow(skill: skill)
                }
            }

            Button("Add Custom Skill") {
                isAddingSkill = true
            }
        }
        .confirmationDialog(
            "Delete this skill?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Skill", role: .destructive) {
                if let skill = pendingSkill {
                    managerskills.disable(skill)
                    pendingSkill = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingSkill = nil
            }
        } message: {
            Text("This permanently removes the skill from the registry and all bots. This cannot be undone.")
        }
        .sheet(isPresented: $isAddingSkill) {
            CreateSkillSheet()
        }
    }
}

// MARK: - SkillRow: one persisted skill

struct SkillRow: View {
    let skill: Skill

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(skill.name)
                .font(.headline)

            if !skill.descriptionText.isEmpty {
                Text(skill.descriptionText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack {
                Spacer()

                Toggle(isOn: Binding(
                    get: { skill.enabled },
                    set: { newValue in
                        if newValue {
                            SkillManager.shared.enable(skill)
                        } else {
                            SkillManager.shared.disable(skill)
                        }
                    }
                )) {
                    EmptyView()
                }
                .labelsHidden()
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - SkillManager env key + accessors

private struct SkillManagerEnvironmentKey: EnvironmentKey {
    static var defaultValue: SkillManager {
        MainActor.assumeIsolated { SkillManager() }
    }
}

extension EnvironmentValues {
    var skillManager: SkillManager {
        get { self[SkillManagerEnvironmentKey.self] }
        set { self[SkillManagerEnvironmentKey.self] = newValue }
    }
}
