import SwiftUI
import AppKit
import Combine

struct RoutineRecordingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(RoutineManager.self) private var routineManager
    
    @State private var recorder = RoutineRecorder.shared
    @State private var noteText: String = ""
    @State private var isAddingNote = false
    @State private var isFinishing = false
    @State private var routineName: String = ""
    @State private var targetBot: String = ""
    
    @State private var startTime: Date = Date()
    @State private var elapsedSeconds: Int = 0
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Circle()
                    .fill(Color.red)
                    .frame(width: 12, height: 12)
                    .opacity(elapsedSeconds % 2 == 0 ? 1.0 : 0.5)
                    .animation(.easeInOut(duration: 0.5), value: elapsedSeconds)
                
                Text("Recording Routine...")
                    .font(.headline)
                
                Spacer()
                
                Text(timeString(from: elapsedSeconds))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
            
            Divider()
            
            // Timeline
            List {
                ForEach(Array(recorder.steps.enumerated()), id: \.element.id) { index, step in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 20, alignment: .trailing)
                            .padding(.top, 4)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: iconFor(action: step.action))
                                    .foregroundStyle(colorFor(action: step.action))
                                Text(step.summaryLine)
                                    .font(.system(.body, design: .monospaced))
                            }
                            
                            if let img = step.screenshotImage {
                                Image(nsImage: img)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxHeight: 100)
                                    .cornerRadius(6)
                            }
                            
                            if let ocr = step.ocrSummary {
                                Text("OCR: \(ocr)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(minHeight: 250)
            
            Divider()
            
            // Controls
            HStack(spacing: 12) {
                Button(action: {
                    recorder.undo()
                }) {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(recorder.steps.isEmpty)
                
                Button(action: {
                    recorder.captureSnapshot()
                }) {
                    Label("Take Snapshot", systemImage: "camera")
                }
                
                Button(action: {
                    isAddingNote = true
                }) {
                    Label("Add Note", systemImage: "note.text")
                }
                .popover(isPresented: $isAddingNote) {
                    VStack(spacing: 12) {
                        TextField("Enter note...", text: $noteText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                        
                        Button("Save Note") {
                            if !noteText.isEmpty {
                                recorder.captureNote(noteText)
                                noteText = ""
                            }
                            isAddingNote = false
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                    .padding()
                }
                
                Spacer()
                
                Button("Cancel") {
                    recorder.stop()
                    dismiss()
                }
                
                Button("Finish & Save...") {
                    isFinishing = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(recorder.steps.isEmpty)
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 500, height: 450)
        .onReceive(timer) { _ in
            elapsedSeconds = Int(Date().timeIntervalSince(startTime))
        }
        .onAppear {
            recorder.start()
            startTime = Date()
        }
        .sheet(isPresented: $isFinishing) {
            VStack(spacing: 20) {
                Text("Save Routine")
                    .font(.headline)
                
                Form {
                    TextField("Routine Name", text: $routineName)
                    TextField("Target Bot (optional)", text: $targetBot)
                }
                
                HStack {
                    Button("Cancel") {
                        isFinishing = false
                    }
                    Button("Save") {
                        if let routine = recorder.makeRoutine(named: routineName, targetBot: targetBot.isEmpty ? nil : targetBot) {
                            routineManager.save(routine)
                            recorder.stop()
                            dismiss()
                        }
                    }
                    .disabled(routineName.isEmpty)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .frame(width: 300)
        }
    }
    
    private func timeString(from seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%02d:%02d", m, s)
    }
    
    private func iconFor(action: String) -> String {
        switch action {
        case "open_app": return "app.window"
        case "shell": return "terminal"
        case "applescript": return "applescript"
        case "note": return "note.text"
        case "snapshot": return "camera.viewfinder"
        default: return "circle"
        }
    }
    
    private func colorFor(action: String) -> Color {
        switch action {
        case "open_app": return .blue
        case "shell": return .green
        case "applescript": return .purple
        case "snapshot": return .orange
        default: return .primary
        }
    }
}
