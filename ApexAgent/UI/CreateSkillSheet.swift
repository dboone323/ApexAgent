import SwiftUI
import SwiftData

// MARK: - CreateSkillSheet: Creation & Validation Sheet for Skills

public struct CreateSkillSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SkillManager.self) private var skillManager: SkillManager?
    @Environment(\.modelContext) private var modelContext

    public var skillName: String
    public var skillDescription: String
    public var parameterSchemaJSON: String
    public var scriptContent: String

    @State private var nameInput: String
    @State private var descInput: String
    @State private var schemaInput: String
    @State private var scriptInput: String
    @State private var errorMessage: String?

    public init(
        skillName: String = "",
        skillDescription: String = "",
        parameterSchemaJSON: String = "{\n  \"type\": \"object\"\n}",
        scriptContent: String = "#!/bin/zsh\n"
    ) {
        self.skillName = skillName
        self.skillDescription = skillDescription
        self.parameterSchemaJSON = parameterSchemaJSON
        self.scriptContent = scriptContent

        _nameInput = State(initialValue: skillName)
        _descInput = State(initialValue: skillDescription)
        _schemaInput = State(initialValue: parameterSchemaJSON)
        _scriptInput = State(initialValue: scriptContent)
    }

    public var isNameValid: Bool {
        let trimmed = skillName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let regex = try? NSRegularExpression(pattern: "^[a-zA-Z0-9_-]+$") else { return false }
        let range = NSRange(location: 0, length: trimmed.utf16.count)
        return regex.firstMatch(in: trimmed, range: range) != nil
    }

    public var isSchemaValid: Bool {
        Self.isStrictlyValidSchema(parameterSchemaJSON)
    }

    public var canSave: Bool {
        isNameValid &&
        !skillDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !scriptContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        isSchemaValid
    }

    /// UI Save-button gate. Internal (not private) so unit tests can assert
    /// the exact gate the Save button uses (H9: bare {} must not be savable).
    var uiCanSave: Bool {
        let trimmedName = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDesc = descInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedScript = scriptInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedDesc.isEmpty, !trimmedScript.isEmpty else { return false }

        guard let regex = try? NSRegularExpression(pattern: "^[a-zA-Z0-9_-]+$") else { return false }
        let nameRange = NSRange(location: 0, length: trimmedName.utf16.count)
        guard regex.firstMatch(in: trimmedName, range: nameRange) != nil else { return false }

        // Strict schema validation — a bare {} must not be savable (H9).
        guard Self.isStrictlyValidSchema(schemaInput) else { return false }

        return true
    }

    /// Strict schema validation shared by the Save button (`uiCanSave`) and
    /// `saveSkill()`. A schema must parse to a JSON dictionary containing a
    /// "type" or "properties" key — a bare `{}` is invalid.
    private static func isStrictlyValidSchema(_ json: String) -> Bool {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let data = trimmed.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return false
        }
        return dict.keys.contains("type") || dict.keys.contains("properties")
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Skill Definition") {
                    TextField("Skill Name (e.g. deploy_preview)", text: $nameInput)
                        .accessibilityLabel("Skill Name")

                    TextField("Description", text: $descInput)
                        .accessibilityLabel("Skill Description")
                }

                Section("JSON Schema Parameters") {
                    TextEditor(text: $schemaInput)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 100)
                        .accessibilityLabel("Parameters Schema JSON")
                }

                Section("Script (zsh / bash)") {
                    TextEditor(text: $scriptInput)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 120)
                        .accessibilityLabel("Script Content")

                    HStack {
                        if DemoRecorder.shared.isRecording {
                            Button(role: .destructive) {
                                DemoRecorder.shared.stopRecording()
                                scriptInput = DemoRecorder.shared.synthesizeShellScript(skillName: nameInput.isEmpty ? "custom_skill" : nameInput)
                            } label: {
                                Label("Stop Recording (\(DemoRecorder.shared.recordedActions.count) steps)", systemImage: "stop.circle.fill")
                            }
                        } else {
                            Button {
                                DemoRecorder.shared.startRecording()
                            } label: {
                                Label("Record Desktop Workflow to Script", systemImage: "record.circle")
                            }
                        }
                        Spacer()
                    }
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("New Custom Skill")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveSkill() }
                        .disabled(!uiCanSave)
                }
            }
        }
        .frame(minWidth: 500, minHeight: 500)
    }

    private func saveSkill() {
        let name = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let desc = descInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let script = scriptInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let schema = schemaInput.trimmingCharacters(in: .whitespacesAndNewlines)

        // Defensive: direct invocation must not bypass the Save-button gate —
        // a bare {} schema is invalid even if uiCanSave was circumvented (H9).
        guard Self.isStrictlyValidSchema(schema) else {
            errorMessage = "Invalid parameter schema: it must be a JSON object containing a \"type\" or \"properties\" key."
            return
        }

        let fileManager = FileManager.default
        let homeDir = fileManager.homeDirectoryForCurrentUser
        let skillsDir = homeDir.appendingPathComponent(".apex/skills")

        do {
            try fileManager.createDirectory(at: skillsDir, withIntermediateDirectories: true, attributes: nil)

            let scriptPath = skillsDir.appendingPathComponent("\(name).sh")
            let manifestPath = skillsDir.appendingPathComponent("\(name).json")

            try script.write(to: scriptPath, atomically: true, encoding: .utf8)

            // chmod 0755
            let chmodProcess = Process()
            chmodProcess.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmodProcess.arguments = ["0755", scriptPath.path]
            try chmodProcess.run()
            chmodProcess.waitUntilExit()

            // Manifest JSON
            let parsedSchema = (try? JSONSerialization.jsonObject(with: schema.data(using: .utf8) ?? Data())) ?? ["type": "object"]
            let manifest: [String: Any] = [
                "name": name,
                "description": desc,
                "script_path": "~/.apex/skills/\(name).sh",
                "parameters": parsedSchema
            ]
            let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: .prettyPrinted)
            try manifestData.write(to: manifestPath)

            // SwiftData record
            let skill = Skill(
                name: name,
                descriptionText: desc,
                scriptPath: "~/.apex/skills/\(name).sh",
                parameterSchemaJSON: schema,
                category: "custom",
                enabled: true
            )

            modelContext.insert(skill)
            try? modelContext.save()

            DynamicToolbox.shared.loadTools()
            dismiss()
        } catch {
            errorMessage = "Failed to save skill: \(error.localizedDescription)"
        }
    }
}
