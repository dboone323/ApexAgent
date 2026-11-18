import SwiftUI
import SwiftData

// MARK: - CreateSkillSheet: Creation & Validation Sheet for Skills (Issue #88 & #107)

public struct CreateSkillSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    public enum AuthoringMode: Equatable, Sendable {
        case create
        case edit(skillName: String)
    }

    public var skillName: String
    public var skillDescription: String
    public var parameterSchemaJSON: String
    public var scriptContent: String
    public var instructionsContent: String
    public var permissions: SkillPermissions
    public var authoringMode: AuthoringMode

    @State private var nameInput: String
    @State private var descInput: String
    @State private var schemaInput: String
    @State private var scriptInput: String
    @State private var instructionsInput: String
    @State private var allowNetwork: Bool
    @State private var allowShell: Bool
    @State private var toolsInput: String
    @State private var pathsInput: String
    @State private var errorMessage: String?

    public init(
        skillName: String = "",
        skillDescription: String = "",
        parameterSchemaJSON: String = "{\n  \"type\": \"object\"\n}",
        scriptContent: String = "#!/bin/zsh\n"
    ) {
        self.init(
            skillName: skillName,
            skillDescription: skillDescription,
            instructionsContent: "",
            parameterSchemaJSON: parameterSchemaJSON,
            scriptContent: scriptContent,
            permissions: SkillPermissions(),
            authoringMode: .create
        )
    }

    public init(
        skillName: String = "",
        skillDescription: String = "",
        instructionsContent: String = "",
        parameterSchemaJSON: String = "{\n  \"type\": \"object\"\n}",
        scriptContent: String = "#!/bin/zsh\n",
        permissions: SkillPermissions = SkillPermissions(),
        authoringMode: AuthoringMode = .create
    ) {
        self.skillName = skillName
        self.skillDescription = skillDescription
        self.instructionsContent = instructionsContent
        self.parameterSchemaJSON = parameterSchemaJSON
        self.scriptContent = scriptContent
        self.permissions = permissions
        self.authoringMode = authoringMode

        _nameInput = State(initialValue: skillName)
        _descInput = State(initialValue: skillDescription)
        _schemaInput = State(initialValue: parameterSchemaJSON)
        _scriptInput = State(initialValue: scriptContent)
        _instructionsInput = State(initialValue: instructionsContent.isEmpty ? "# \(skillName.isEmpty ? "Skill" : skillName)\n" : instructionsContent)
        _allowNetwork = State(initialValue: permissions.allowNetwork)
        _allowShell = State(initialValue: permissions.allowShell)
        _toolsInput = State(initialValue: permissions.tools.joined(separator: ", "))
        _pathsInput = State(initialValue: permissions.filesystemPaths.joined(separator: ", "))
    }

    init(editing skill: Skill) {
        let manifest = SkillSecurityManager.shared.permissionManifest(for: skill.name)
        let resolvedScript = URL(fileURLWithPath: (skill.scriptPath as NSString).expandingTildeInPath)
        let scriptText = (try? String(contentsOf: resolvedScript, encoding: .utf8)) ?? "#!/bin/zsh\n"

        let skillMdPath = ApexAgentStoragePaths.skills.appendingPathComponent(skill.name).appendingPathComponent("SKILL.md")
        let instructionsText = (try? String(contentsOf: skillMdPath, encoding: .utf8)) ?? "# \(skill.name)\n\(skill.descriptionText)"

        self.init(
            skillName: skill.name,
            skillDescription: skill.descriptionText,
            instructionsContent: instructionsText,
            parameterSchemaJSON: skill.parameterSchemaJSON,
            scriptContent: scriptText,
            permissions: manifest?.permissions ?? SkillPermissions(),
            authoringMode: .edit(skillName: skill.name)
        )
    }

    public var isNameValid: Bool {
        let trimmed = (nameInput.isEmpty ? skillName : nameInput).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let regex = try? NSRegularExpression(pattern: "^[a-zA-Z0-9_-]+$") else { return false }
        let range = NSRange(location: 0, length: trimmed.utf16.count)
        return regex.firstMatch(in: trimmed, range: range) != nil
    }

    public var isSchemaValid: Bool {
        Self.isStrictlyValidSchema(schemaInput.isEmpty ? parameterSchemaJSON : schemaInput)
    }

    public var canSave: Bool {
        let effectiveDesc = descInput.isEmpty ? skillDescription : descInput
        let effectiveScript = scriptInput.isEmpty ? scriptContent : scriptInput
        return isNameValid &&
            !effectiveDesc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !effectiveScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            isSchemaValid
    }

    /// Pre-flight security scan and manifest validation for authoring.
    public func preflightValidation() -> (manifest: SkillPermissionManifest?, passed: Bool, message: String?) {
        let trimmedName = (nameInput.isEmpty ? skillName : nameInput).trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDesc = (descInput.isEmpty ? skillDescription : descInput).trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedScript = (scriptInput.isEmpty ? scriptContent : scriptInput).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty else {
            return (nil, false, "Skill name cannot be empty")
        }

        let parsedTools = toolsInput.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let parsedPaths = pathsInput.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

        let perms = SkillPermissions(
            tools: parsedTools.isEmpty ? permissions.tools : parsedTools,
            allowNetwork: allowNetwork,
            filesystemPaths: parsedPaths.isEmpty ? permissions.filesystemPaths : parsedPaths,
            allowShell: allowShell
        )

        let manifest = SkillPermissionManifest(
            name: trimmedName,
            version: "1.0.0",
            description: trimmedDesc,
            scriptPath: ApexAgentStoragePaths.skillScriptReference(for: trimmedName),
            permissions: perms
        )

        let scan = SkillSecurityScanner.scan(manifest: manifest, scriptContent: trimmedScript)
        if !scan.passed {
            let summary = scan.findings.map { "[\($0.severity.rawValue)] \($0.ruleId): \($0.message)" }.joined(separator: "\n")
            return (manifest, false, summary)
        }

        return (manifest, true, nil)
    }

    /// UI Save-button gate. Internal so unit tests can assert the exact gate.
    var uiCanSave: Bool {
        let trimmedName = (nameInput.isEmpty ? skillName : nameInput).trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDesc = (descInput.isEmpty ? skillDescription : descInput).trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedScript = (scriptInput.isEmpty ? scriptContent : scriptInput).trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveSchema = schemaInput.isEmpty ? parameterSchemaJSON : schemaInput
        guard !trimmedName.isEmpty, !trimmedDesc.isEmpty, !trimmedScript.isEmpty else { return false }

        guard let regex = try? NSRegularExpression(pattern: "^[a-zA-Z0-9_-]+$") else { return false }
        let nameRange = NSRange(location: 0, length: trimmedName.utf16.count)
        guard regex.firstMatch(in: trimmedName, range: nameRange) != nil else { return false }

        // Strict schema validation — a bare {} must not be savable (H9).
        guard Self.isStrictlyValidSchema(effectiveSchema) else { return false }

        // Issue #88: Authoring validation requires clean manifest and passed security scan.
        let validation = preflightValidation()
        guard validation.passed else { return false }

        return true
    }

    /// Strict schema validation shared by the Save button (`uiCanSave`) and `saveSkill()`.
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
                        .disabled(authoringMode != .create)

                    TextField("Description", text: $descInput)
                        .accessibilityLabel("Skill Description")
                }

                Section("Skill Instructions (SKILL.md)") {
                    TextEditor(text: $instructionsInput)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 120)
                        .accessibilityLabel("Skill Instructions")
                }

                Section("Declared Permissions (Manifest)") {
                    Toggle("Allow Outbound Network", isOn: $allowNetwork)
                    Toggle("Allow Shell Execution", isOn: $allowShell)
                    TextField("Authorized Tools (comma-separated)", text: $toolsInput)
                    TextField("Authorized Filesystem Paths (comma-separated)", text: $pathsInput)
                }

                Section("JSON Schema Parameters") {
                    TextEditor(text: $schemaInput)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 80)
                        .accessibilityLabel("Parameters Schema JSON")
                }

                Section("Script (zsh / bash)") {
                    TextEditor(text: $scriptInput)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 100)
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

                let validation = preflightValidation()
                if !validation.passed, let msg = validation.message {
                    Section("Validation & Security Status") {
                        Label(msg, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                } else {
                    Section("Validation & Security Status") {
                        Label("Manifest verified & security scan clean", systemImage: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
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
            .navigationTitle(authoringMode == .create ? "New Custom Skill" : "Edit Skill '\(nameInput)'")
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
        .frame(minWidth: 550, minHeight: 650)
    }

    private func saveSkill() {
        let trimmedName = (nameInput.isEmpty ? skillName : nameInput).trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDesc = (descInput.isEmpty ? skillDescription : descInput).trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedScript = (scriptInput.isEmpty ? scriptContent : scriptInput).trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSchema = (schemaInput.isEmpty ? parameterSchemaJSON : schemaInput).trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInstructions = instructionsInput.trimmingCharacters(in: .whitespacesAndNewlines)

        guard Self.isStrictlyValidSchema(trimmedSchema) else {
            errorMessage = "Invalid parameter schema: it must be a JSON object containing a \"type\" or \"properties\" key."
            return
        }

        let preflight = preflightValidation()
        guard let manifest = preflight.manifest, preflight.passed else {
            errorMessage = preflight.message ?? "Security validation failed. Cannot save skill without verified manifest."
            return
        }

        let verifyResult: Result<SkillPermissionManifest, SkillSecurityError>
        switch authoringMode {
        case .create:
            verifyResult = SkillSecurityManager.shared.verifyInstall(manifest: manifest, scriptContent: trimmedScript)
        case .edit:
            verifyResult = SkillSecurityManager.shared.verifyUpdate(name: trimmedName, updatedManifest: manifest, updatedScript: trimmedScript)
        }

        guard case .success = verifyResult else {
            if case .failure(let err) = verifyResult {
                errorMessage = err.findings.map { "\($0.ruleId): \($0.message)" }.joined(separator: "\n")
            }
            return
        }

        let fileManager = FileManager.default
        let skillsDir = ApexAgentStoragePaths.skills
        let skillFolder = skillsDir.appendingPathComponent(trimmedName, isDirectory: true)

        do {
            try fileManager.createDirectory(at: skillsDir, withIntermediateDirectories: true, attributes: nil)
            try fileManager.createDirectory(at: skillFolder, withIntermediateDirectories: true, attributes: nil)

            let scriptPath = skillsDir.appendingPathComponent("\(trimmedName).sh")
            let manifestPath = skillsDir.appendingPathComponent("\(trimmedName).json")
            let skillMdPath = skillFolder.appendingPathComponent("SKILL.md")
            let folderManifestPath = skillFolder.appendingPathComponent("manifest.json")

            try trimmedScript.write(to: scriptPath, atomically: true, encoding: .utf8)

            // chmod 0755
            let chmodProcess = Process()
            chmodProcess.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmodProcess.arguments = ["0755", scriptPath.path]
            try chmodProcess.run()
            chmodProcess.waitUntilExit()

            // Save SKILL.md
            let finalInstructions = trimmedInstructions.isEmpty ? "# \(trimmedName)\n\(trimmedDesc)\n" : trimmedInstructions
            try finalInstructions.write(to: skillMdPath, atomically: true, encoding: .utf8)

            // Manifest JSON
            let parsedSchema = ((try? JSONSerialization.jsonObject(with: trimmedSchema.data(using: .utf8) ?? Data())) as? [String: Any]) ?? ["type": "object"]
            let manifestDict = manifest.toDictionary(parameterSchema: parsedSchema)
            let manifestData = try JSONSerialization.data(withJSONObject: manifestDict, options: .prettyPrinted)
            try manifestData.write(to: manifestPath)
            try manifestData.write(to: folderManifestPath)

            // SwiftData record
            switch authoringMode {
            case .create:
                let descriptor = FetchDescriptor<Skill>(predicate: #Predicate { $0.name == trimmedName })
                if let existing = try? modelContext.fetch(descriptor).first {
                    existing.descriptionText = trimmedDesc
                    existing.parameterSchemaJSON = trimmedSchema
                    existing.updatedAt = Date()
                } else {
                    let skill = Skill(
                        name: trimmedName,
                        descriptionText: trimmedDesc,
                        scriptPath: ApexAgentStoragePaths.skillScriptReference(for: trimmedName),
                        parameterSchemaJSON: trimmedSchema,
                        category: "custom",
                        enabled: true
                    )
                    modelContext.insert(skill)
                }
            case .edit(let existingName):
                let descriptor = FetchDescriptor<Skill>(predicate: #Predicate { $0.name == existingName })
                if let existing = try? modelContext.fetch(descriptor).first {
                    existing.descriptionText = trimmedDesc
                    existing.parameterSchemaJSON = trimmedSchema
                    existing.updatedAt = Date()
                }
            }
            try? modelContext.save()

            DynamicToolbox.shared.loadTools()
            dismiss()
        } catch {
            errorMessage = "Failed to save skill: \(error.localizedDescription)"
        }
    }
}
