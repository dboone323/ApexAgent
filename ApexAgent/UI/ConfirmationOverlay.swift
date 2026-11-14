import SwiftUI

struct ConfirmationOverlay: View {
    @Environment(AgentOrchestrator.self) private var orchestrator
    @State private var timeRemaining = 60

    var body: some View {
        ZStack {
            // Dimmed backdrop
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { /* Prevent dismissal by tapping backdrop */ }

            // Modal card
            VStack(spacing: 0) {
                // Warning header
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(Color.orange.opacity(0.15))
                            .frame(width: 42, height: 42)
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.orange)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Action Requires Approval")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Apex wants to perform a potentially risky operation")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(20)
                .background(Color.orange.opacity(0.06))

                Divider()

                // Details
                if let request = orchestrator.pendingConfirmation {
                    VStack(alignment: .leading, spacing: 14) {
                        // Tool name
                        HStack(spacing: 8) {
                            Text("Tool:")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .trailing)
                            Text(request.toolName)
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                        }

                        // Directory (if any)
                        if let dir = request.directory {
                            HStack(spacing: 8) {
                                Text("Directory:")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 70, alignment: .trailing)
                                Text(dir)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }

                        // File Path (if any)
                        if let filePath = request.filePath {
                            HStack(spacing: 8) {
                                Text("File:")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 70, alignment: .trailing)
                                Text(filePath)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }

                        // Arguments (only show if no diff to save vertical space)
                        if request.oldContent == nil {
                            HStack(alignment: .top, spacing: 8) {
                                Text("Arguments:")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 70, alignment: .trailing)
                                ScrollView {
                                    Text(request.arguments)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.primary)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: 100)
                            }
                        }

                        // Risk description
                        HStack(alignment: .top, spacing: 8) {
                            Text("Risk:")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .trailing)
                            Text(request.riskDescription)
                                .font(.system(size: 12))
                                .foregroundStyle(.orange)
                        }

                        // Code Diff View (if any)
                        if let old = request.oldContent, let new = request.newContent {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Proposed Diff:")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                
                                DiffView(oldContent: old, newContent: new)
                                    .frame(height: 280)
                            }
                        }
                    }
                    .padding(20)
                }

                Divider()

                // Timeout bar + buttons
                VStack(spacing: 14) {
                    // Auto-deny countdown
                    HStack(spacing: 8) {
                        Image(systemName: "clock")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text("Auto-denied in \(timeRemaining)s")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        ProgressView(value: Double(timeRemaining), total: 60)
                            .progressViewStyle(.linear)
                            .tint(.orange.opacity(0.6))
                            .frame(width: 100)
                    }

                    HStack(spacing: 10) {
                        Button {
                            stopTimer()
                            orchestrator.resolveConfirmation(approved: false)
                        } label: {
                            Text("Deny (Esc)")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color(nsColor: .quaternaryLabelColor).opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("confirmationDeny")
                        .accessibilityLabel("Deny action")
                        .keyboardShortcut(.escape, modifiers: [])

                        Button {
                            stopTimer()
                            orchestrator.resolveConfirmation(approved: true, alwaysAllowInDirectory: false)
                        } label: {
                            Text("Allow Once")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color(nsColor: .tertiaryLabelColor).opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("confirmationAllowOnce")
                        .accessibilityLabel("Allow once without remembering")

                        Button {
                            stopTimer()
                            orchestrator.resolveConfirmation(approved: true, alwaysAllowInDirectory: true)
                        } label: {
                            Text("Always in Dir (⌘↩)")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(
                                    LinearGradient(colors: [.orange, .red], startPoint: .leading, endPoint: .trailing),
                                    in: RoundedRectangle(cornerRadius: 10)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("confirmationApprove")
                        .accessibilityLabel("Allow this exact command in this directory always")
                        .keyboardShortcut(.return, modifiers: .command)
                    }
                }
                .padding(20)
            }
            .frame(width: orchestrator.pendingConfirmation?.oldContent != nil ? 680 : 480)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.orange.opacity(0.3), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 40, y: 20)
        }
        .onAppear { startTimer() }
        .onDisappear { stopTimer() }
        .onChange(of: orchestrator.pendingConfirmation?.id) { _, newId in
            stopTimer()
            if newId != nil {
                startTimer()
            }
        }
        .accessibilityIdentifier("confirmationOverlay")
    }

    @State private var timerTask: Task<Void, Never>?

    private func startTimer() {
        timeRemaining = 60
        timerTask = Task { @MainActor in
            while !Task.isCancelled && timeRemaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                if !Task.isCancelled {
                    timeRemaining -= 1
                }
            }
            if !Task.isCancelled && timeRemaining == 0 {
                orchestrator.resolveConfirmation(approved: false)
            }
        }
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
    }
}
