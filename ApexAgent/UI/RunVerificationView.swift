import SwiftUI
import Accessibility

// MARK: - Run Verification View Model

@MainActor
public final class RunVerificationViewModel: ObservableObject {
    @Published public var selectedRunId: String = ""
    @Published public var availableRunIds: [String] = []
    @Published public var currentTrace: RunTrace?
    @Published public var artifacts: [VerificationArtifact] = []
    @Published public var newCommentTexts: [String: String] = [:]
    @Published public var commentAuthor: String = "User"
    @Published public var statusMessage: String?
    @Published public var isLoading: Bool = false

    public let workspacePath: String?

    public init(workspacePath: String? = nil, initialRunId: String? = nil) {
        self.workspacePath = workspacePath
        loadAvailableRuns(selectRunId: initialRunId)
    }

    /// Discovers all available run traces on disk and selects a target run.
    public func loadAvailableRuns(selectRunId: String? = nil) {
        let traceURLs = RunTraceStorage.listTraces(workspacePath: workspacePath, limit: 100)
        let discovered = traceURLs.map { $0.deletingPathExtension().lastPathComponent }
        self.availableRunIds = discovered

        let targetId = selectRunId ?? discovered.first ?? ""
        if !targetId.isEmpty {
            selectRun(runId: targetId)
        }
    }

    /// Selects and loads a run trace from disk into the verification UI.
    public func selectRun(runId: String) {
        self.selectedRunId = runId
        self.isLoading = true
        defer { self.isLoading = false }

        do {
            if let trace = try RunTraceStorage.loadTrace(for: runId, workspacePath: workspacePath) {
                self.currentTrace = trace
                if !trace.artifacts.isEmpty {
                    self.artifacts = trace.artifacts
                } else {
                    self.artifacts = VerificationArtifactExtractor.extractArtifacts(from: trace)
                }
                self.statusMessage = "Loaded \(self.artifacts.count) artifact(s) for run \(runId)"
            } else {
                self.currentTrace = nil
                self.artifacts = []
                self.statusMessage = "Trace not found on disk for \(runId)"
            }
        } catch {
            self.statusMessage = "Error loading trace: \(error.localizedDescription)"
        }
    }

    /// Reloads the active run trace from disk to verify persistence across reloads.
    public func reload() {
        guard !selectedRunId.isEmpty else { return }
        selectRun(runId: selectedRunId)
    }

    /// Attaches a comment to a verification artifact and persists it immediately with the run's trace.
    public func attachComment(to artifactId: String) {
        let text = (newCommentTexts[artifactId] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !selectedRunId.isEmpty else { return }

        let comment = VerificationComment(
            author: commentAuthor.isEmpty ? "User" : commentAuthor,
            text: text,
            timestamp: Date()
        )

        do {
            let updatedArtifact = try RunTraceManager.shared.attachComment(
                to: artifactId,
                runId: selectedRunId,
                comment: comment,
                workspacePath: workspacePath
            )
            // Update in-memory state
            if let idx = artifacts.firstIndex(where: { $0.id == artifactId }) {
                artifacts[idx] = updatedArtifact
            }
            newCommentTexts[artifactId] = ""
            statusMessage = "Comment attached to \(updatedArtifact.kind.displayName)"
        } catch {
            statusMessage = "Failed to attach comment: \(error.localizedDescription)"
        }
    }
}

// MARK: - Run Verification View (Issue #114)

public struct RunVerificationView: View {
    @StateObject private var viewModel: RunVerificationViewModel
    @Environment(\.dismiss) private var dismiss

    public init(workspacePath: String? = nil, runId: String? = nil) {
        _viewModel = StateObject(wrappedValue: RunVerificationViewModel(workspacePath: workspacePath, initialRunId: runId))
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header bar
            headerBar
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(AppTheme.Palette.windowBackground)

            Divider()

            // Summary metrics
            summaryBar
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Artifact List
            if viewModel.artifacts.isEmpty {
                emptyStateView
            } else {
                artifactListView
            }

            if let status = viewModel.statusMessage {
                Divider()
                HStack {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(AppTheme.Palette.windowBackground)
            }
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 480, idealHeight: 560)
        .background(AppTheme.Palette.windowBackground)
        .accessibilityIdentifier("runVerificationView")
        .accessibilityLabel("Run verification view")
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 20))
                .foregroundStyle(AppTheme.Palette.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text("Verification Artifacts")
                    .font(.headline)
                    .foregroundStyle(AppTheme.Palette.textPrimary)

                if !viewModel.availableRunIds.isEmpty {
                    Picker("Run", selection: $viewModel.selectedRunId) {
                        ForEach(viewModel.availableRunIds, id: \.self) { id in
                            Text(id).tag(id)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 320)
                    .accessibilityIdentifier("runIdPicker")
                    .onChange(of: viewModel.selectedRunId) { _, newRunId in
                        viewModel.selectRun(runId: newRunId)
                    }
                } else {
                    Text("No run traces available")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                }
            }

            Spacer()

            Button {
                viewModel.reload()
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("verificationReloadButton")
            .accessibilityLabel("Reload verification artifacts")
            .help("Reload artifacts and comments from disk trace")

            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Summary Bar

    private var summaryBar: some View {
        HStack(spacing: 16) {
            let total = viewModel.artifacts.count
            let passed = viewModel.artifacts.filter { $0.effectiveStatus == .passed }.count
            let failed = viewModel.artifacts.filter { $0.effectiveStatus == .failed }.count
            let missing = viewModel.artifacts.filter { $0.effectiveStatus == .missing }.count

            HStack(spacing: 4) {
                Text("Total:")
                    .fontWeight(.medium)
                Text("\(total)")
            }
            .font(.subheadline)

            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Passed: \(passed)")
            }
            .font(.subheadline)

            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text("Failed: \(failed)")
            }
            .font(.subheadline)

            if missing > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Missing: \(missing)")
                }
                .font(.subheadline)
            }

            Spacer()

            if let trace = viewModel.currentTrace {
                Text("Status: \(trace.status)")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(trace.status == "completed" ? Color.green.opacity(0.15) : Color.red.opacity(0.15))
                    .foregroundStyle(trace.status == "completed" ? Color.green : Color.red)
                    .clipShape(Capsule())
            }
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 44))
                .foregroundStyle(AppTheme.Palette.textTertiary)
            Text("No Artifacts Available")
                .font(.headline)
                .foregroundStyle(AppTheme.Palette.textSecondary)
            Text("This run does not contain any plans, diffs, recordings, or checklists.")
                .font(.caption)
                .foregroundStyle(AppTheme.Palette.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Artifact List

    private var artifactListView: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(viewModel.artifacts) { artifact in
                    artifactCard(for: artifact)
                        .accessibilityIdentifier("artifactRow_\(artifact.id)")
                }
            }
            .padding(16)
        }
    }

    // MARK: - Artifact Card

    private func artifactCard(for artifact: VerificationArtifact) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Card header
            HStack {
                Label(artifact.kind.displayName, systemImage: artifact.kind.systemImage)
                    .font(.headline)
                    .foregroundStyle(AppTheme.Palette.textPrimary)
                    .accessibilityIdentifier("artifactKind_\(artifact.kind.rawValue)")

                if let trialId = artifact.trialId {
                    Text("Trial: \(trialId)")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                Spacer()

                statusBadge(for: artifact.effectiveStatus)
                    .accessibilityIdentifier("artifactStatus_\(artifact.id)")
            }

            // Path information if present
            if let path = artifact.path, !path.isEmpty {
                HStack(spacing: 4) {
                    Text("File Path:")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                    Text(path)
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .foregroundStyle(AppTheme.Palette.textPrimary)
                }
            }

            // Content preview
            if let content = artifact.content, !content.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(content)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(AppTheme.Palette.textPrimary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
            } else if artifact.path == nil || artifact.path?.isEmpty == true {
                Text("Artifact content missing")
                    .font(.caption)
                    .italic()
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    .padding(.vertical, 4)
            }

            Divider()

            // Comments section
            commentsSection(for: artifact)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1))
    }

    // MARK: - Status Badge

    private func statusBadge(for status: VerificationArtifactStatus) -> some View {
        HStack(spacing: 4) {
            switch status {
            case .passed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Passed")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.green)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text("Failed")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.red)
            case .missing:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Missing")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            (status == .passed ? Color.green : (status == .failed ? Color.red : Color.orange)).opacity(0.12)
        )
        .clipShape(Capsule())
    }

    // MARK: - Comments Section

    private func commentsSection(for artifact: VerificationArtifact) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Comments (\(artifact.comments.count))")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(AppTheme.Palette.textSecondary)

            if !artifact.comments.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(artifact.comments) { comment in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(comment.author)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(AppTheme.Palette.textPrimary)
                                Spacer()
                                Text(comment.timestamp, style: .time)
                                    .font(.caption2)
                                    .foregroundStyle(AppTheme.Palette.textTertiary)
                            }
                            Text(comment.text)
                                .font(.caption)
                                .foregroundStyle(AppTheme.Palette.textPrimary)
                        }
                        .padding(6)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
                .accessibilityIdentifier("commentList_\(artifact.id)")
            }

            // Input row for new comment
            HStack(spacing: 8) {
                let textBinding = Binding<String>(
                    get: { viewModel.newCommentTexts[artifact.id] ?? "" },
                    set: { viewModel.newCommentTexts[artifact.id] = $0 }
                )

                TextField("Attach a comment...", text: textBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .accessibilityIdentifier("commentInput_\(artifact.id)")

                Button("Attach") {
                    viewModel.attachComment(to: artifact.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled((viewModel.newCommentTexts[artifact.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("addCommentButton_\(artifact.id)")
            }
        }
    }
}
