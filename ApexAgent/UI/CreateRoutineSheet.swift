import SwiftUI
import SwiftData

// MARK: - CreateRoutineSheet: Creation & Validation Sheet for Routines

public struct CreateRoutineSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(RoutineManager.self) private var routineManager: RoutineManager?
    @Environment(\.modelContext) private var modelContext

    public var routineName: String
    public var prompt: String
    public var selectedTrigger: RoutineTrigger
    public var selectedBotName: String
    public var scheduledMinutes: Int
    public var cronExpression: String
    public var messageFilter: String

    @State private var nameInput: String
    @State private var promptInput: String
    @State private var triggerInput: RoutineTrigger
    @State private var botNameInput: String
    @State private var minutesInput: Int
    @State private var cronInput: String
    @State private var filterInput: String

    public init(
        routineName: String = "",
        prompt: String = "",
        selectedTrigger: RoutineTrigger = .manual,
        scheduledMinutes: Int = 15,
        cronExpression: String = "0 9 * * *",
        messageFilter: String = "",
        selectedBotName: String = "Apex"
    ) {
        self.routineName = routineName
        self.prompt = prompt
        self.selectedTrigger = selectedTrigger
        self.scheduledMinutes = scheduledMinutes
        self.cronExpression = cronExpression
        self.messageFilter = messageFilter
        self.selectedBotName = selectedBotName

        _nameInput = State(initialValue: routineName)
        _promptInput = State(initialValue: prompt)
        _triggerInput = State(initialValue: selectedTrigger)
        _botNameInput = State(initialValue: selectedBotName)
        _minutesInput = State(initialValue: scheduledMinutes)
        _cronInput = State(initialValue: cronExpression)
        _filterInput = State(initialValue: messageFilter)
    }

    public init(
        routineName: String,
        prompt: String,
        selectedBotName: String,
        selectedTrigger: RoutineTrigger,
        cronExpression: String? = nil,
        messageFilter: String = "",
        scheduledMinutes: Int = 15
    ) {
        self.routineName = routineName
        self.prompt = prompt
        self.selectedBotName = selectedBotName
        self.selectedTrigger = selectedTrigger
        self.cronExpression = cronExpression ?? "0 9 * * *"
        self.messageFilter = messageFilter
        self.scheduledMinutes = scheduledMinutes

        _nameInput = State(initialValue: routineName)
        _promptInput = State(initialValue: prompt)
        _botNameInput = State(initialValue: selectedBotName)
        _triggerInput = State(initialValue: selectedTrigger)
        _minutesInput = State(initialValue: scheduledMinutes)
        _cronInput = State(initialValue: cronExpression ?? "0 9 * * *")
        _filterInput = State(initialValue: messageFilter)
    }

    public var isCronValid: Bool {
        CronSchedule.isValid(cronExpression)
    }

    public var cronDescription: String {
        if isCronValid {
            return (try? CronSchedule(expression: cronExpression).humanReadableDescription) ?? "Cron: \(cronExpression)"
        } else {
            return "Invalid cron syntax"
        }
    }

    public var webhookPathPreview: String {
        let slug = routineName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()
        let namePart = slug.isEmpty ? ":routineName" : slug
        return "http://localhost:8800/api/v1/webhook/\(namePart)"
    }

    public var canSave: Bool {
        let trimmedName = routineName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedPrompt.isEmpty else { return false }

        switch selectedTrigger {
        case .timeInterval:
            return scheduledMinutes > 0
        case .cron:
            return isCronValid
        default:
            return true
        }
    }

    private var uiCanSave: Bool {
        let trimmedName = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = promptInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedPrompt.isEmpty else { return false }

        switch triggerInput {
        case .timeInterval:
            return minutesInput > 0
        case .cron:
            return CronSchedule.isValid(cronInput)
        default:
            return true
        }
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Routine Details") {
                    TextField("Routine Name", text: $nameInput)
                        .accessibilityLabel("Routine Name")

                    TextField("Target Bot (default: Apex)", text: $botNameInput)
                        .accessibilityLabel("Target Bot")

                    TextEditor(text: $promptInput)
                        .frame(minHeight: 80)
                        .accessibilityLabel("Routine Prompt")

                    HStack {
                        if DemoRecorder.shared.isRecording {
                            Button(role: .destructive) {
                                DemoRecorder.shared.stopRecording()
                                promptInput = DemoRecorder.shared.synthesizeRoutinePrompt(routineName: nameInput.isEmpty ? "My Workflow" : nameInput)
                            } label: {
                                Label("Stop Recording (\(DemoRecorder.shared.recordedActions.count) steps)", systemImage: "stop.circle.fill")
                            }
                        } else {
                            Button {
                                DemoRecorder.shared.startRecording()
                            } label: {
                                Label("Record Desktop Workflow", systemImage: "record.circle")
                            }
                        }
                        Spacer()
                    }
                }

                Section("Trigger") {
                    Picker("Trigger Type", selection: $triggerInput) {
                        Text("Manual").tag(RoutineTrigger.manual)
                        Text("Time Interval").tag(RoutineTrigger.timeInterval)
                        Text("Cron Schedule").tag(RoutineTrigger.cron)
                        Text("On Error").tag(RoutineTrigger.onError)
                        Text("On Success").tag(RoutineTrigger.onSuccess)
                        Text("On Message").tag(RoutineTrigger.onMessage)
                        Text("Webhook").tag(RoutineTrigger.webhook)
                    }

                    if triggerInput == .timeInterval {
                        Stepper("Every \(minutesInput) minutes", value: $minutesInput, in: 1...1440)
                    } else if triggerInput == .cron {
                        TextField("Cron Expression (e.g. 0 9 * * *)", text: $cronInput)
                        let isValid = CronSchedule.isValid(cronInput)
                        Text(isValid ? ((try? CronSchedule(expression: cronInput).humanReadableDescription) ?? "Cron: \(cronInput)") : "Invalid cron syntax")
                            .font(.caption)
                            .foregroundStyle(isValid ? Color.secondary : Color.red)
                    } else if triggerInput == .onMessage {
                        TextField("Message Filter Keyword (leave empty to trigger on any)", text: $filterInput)
                            .accessibilityLabel("Message Filter")
                        Text("This routine will fire whenever an incoming chat message matches this filter.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if triggerInput == .webhook {
                        let slug = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            .replacingOccurrences(of: " ", with: "-")
                            .lowercased()
                        let path = "http://localhost:8800/api/v1/webhook/\(slug.isEmpty ? ":routineName" : slug)"
                        Text("Webhook URL: \(path)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("New Routine")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveRoutine() }
                        .disabled(!uiCanSave)
                }
            }
        }
        .frame(minWidth: 450, minHeight: 400)
    }

    private func saveRoutine() {
        let targetBot = botNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawPrompt = promptInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveDesc: String
        if targetBot.isEmpty || targetBot == "Apex" {
            effectiveDesc = rawPrompt
        } else {
            effectiveDesc = "\(targetBot): \(rawPrompt)"
        }

        let routine = Routine(
            name: nameInput.trimmingCharacters(in: .whitespacesAndNewlines),
            descriptionText: effectiveDesc,
            trigger: triggerInput,
            scheduledMinutes: triggerInput == .timeInterval ? minutesInput : 0,
            cronExpression: triggerInput == .cron ? cronInput : nil,
            messageFilter: triggerInput == .onMessage ? filterInput.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            enabled: true
        )

        if let rm = routineManager {
            rm.save(routine)
        } else {
            modelContext.insert(routine)
            try? modelContext.save()
        }
        dismiss()
    }
}
