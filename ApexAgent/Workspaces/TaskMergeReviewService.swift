import Foundation

// MARK: - Task Merge Review Service

public actor TaskMergeReviewService {
    public static let shared = TaskMergeReviewService()

    public init() {}

    // MARK: - Proposal Generation

    /// Generates a structured review proposal showing all changes made by a task before landing.
    public func createReviewProposal(for taskID: String) async throws -> TaskReviewProposal {
        guard let workspace = await TaskWorkspaceManager.shared.workspace(for: taskID) else {
            throw TaskWorkspaceError.workspaceNotFound(taskID)
        }

        var changedFiles: [TaskChangedFile] = []
        var diffSummary = ""

        let gitStatus = await ProcessRunner.runProcessSafely(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", workspace.workspacePath, "status", "--porcelain"],
            timeoutSeconds: 15
        )

        if gitStatus.exitCode == 0 && !gitStatus.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let lines = gitStatus.stdout.components(separatedBy: .newlines)
            for line in lines where !line.isEmpty {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.count >= 3 else { continue }
                let statusPrefix = String(trimmed.prefix(2)).trimmingCharacters(in: .whitespaces)
                let filePath = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)

                let changeType: TaskChangedFile.ChangeType
                switch statusPrefix {
                case "M": changeType = .modified
                case "D": changeType = .deleted
                default: changeType = .added
                }

                let fullPath = (workspace.workspacePath as NSString).appendingPathComponent(filePath)
                let size = (try? FileManager.default.attributesOfItem(atPath: fullPath)[.size] as? Int) ?? 0
                changedFiles.append(TaskChangedFile(path: filePath, changeType: changeType, byteCount: size))
            }

            let gitDiff = await ProcessRunner.runProcessSafely(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["-C", workspace.workspacePath, "diff", "HEAD"],
                timeoutSeconds: 20
            )
            diffSummary = gitDiff.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if diffSummary.isEmpty {
                diffSummary = "Status:\n" + gitStatus.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else {
            // Filesystem-based diff against base directory
            let files = (try? workspace.listFiles()) ?? []
            for file in files {
                let targetFile = (workspace.baseDirectory as NSString).appendingPathComponent(file)
                let wsFile = (workspace.workspacePath as NSString).appendingPathComponent(file)

                let wsContent = (try? String(contentsOfFile: wsFile, encoding: .utf8)) ?? ""
                let targetContent = (try? String(contentsOfFile: targetFile, encoding: .utf8)) ?? ""

                if !FileManager.default.fileExists(atPath: targetFile) {
                    changedFiles.append(TaskChangedFile(path: file, changeType: .added, byteCount: wsContent.count))
                } else if wsContent != targetContent {
                    changedFiles.append(TaskChangedFile(path: file, changeType: .modified, byteCount: wsContent.count))
                }
            }

            if !changedFiles.isEmpty {
                var diffLines: [String] = ["Review Summary for Task '\(taskID)':"]
                for cf in changedFiles {
                    diffLines.append("- \(cf.changeType.rawValue.uppercased()): \(cf.path) (\(cf.byteCount) bytes)")
                }
                diffSummary = diffLines.joined(separator: "\n")
            } else {
                diffSummary = "No changes detected in task workspace."
            }
        }

        workspace.updateState(.reviewing)

        return TaskReviewProposal(
            taskID: taskID,
            workspacePath: workspace.workspacePath,
            changedFiles: changedFiles,
            diffSummary: diffSummary,
            proposedAt: Date(),
            isEligibleForLanding: !changedFiles.isEmpty
        )
    }

    // MARK: - Merge & Land with Review Gating

    /// Evaluates reviewer approval and either lands changes into the target workspace or rejects them fail-closed.
    public func land(
        taskID: String,
        reviewerApproval: Bool,
        reviewerNotes: String? = nil,
        targetWorkspacePath: String? = nil
    ) async throws -> TaskLandingResult {
        guard let workspace = await TaskWorkspaceManager.shared.workspace(for: taskID) else {
            throw TaskWorkspaceError.workspaceNotFound(taskID)
        }

        let targetDir = targetWorkspacePath ?? workspace.baseDirectory

        // FAIL-CLOSED: If review does not pass, immediately refuse to land changes!
        guard reviewerApproval else {
            workspace.updateState(.rejected)
            return TaskLandingResult(
                succeeded: false,
                taskID: taskID,
                reason: "Merge/review rejected by reviewer: \(reviewerNotes ?? "Changes failed review standards")",
                landedFiles: []
            )
        }

        // Generate proposal to get the list of changes to land
        let proposal = try await createReviewProposal(for: taskID)
        guard !proposal.changedFiles.isEmpty else {
            workspace.updateState(.landed)
            return TaskLandingResult(
                succeeded: true,
                taskID: taskID,
                reason: "Workspace had no changes to land",
                landedFiles: []
            )
        }

        var landed: [String] = []
        for file in proposal.changedFiles {
            let srcPath = (workspace.workspacePath as NSString).appendingPathComponent(file.path)
            let dstPath = (targetDir as NSString).appendingPathComponent(file.path)

            switch file.changeType {
            case .deleted:
                if FileManager.default.fileExists(atPath: dstPath) {
                    try? FileManager.default.removeItem(atPath: dstPath)
                    landed.append(file.path)
                }
            case .added, .modified:
                if FileManager.default.fileExists(atPath: srcPath) {
                    let parent = URL(fileURLWithPath: dstPath).deletingLastPathComponent().path
                    try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
                    if FileManager.default.fileExists(atPath: dstPath) {
                        try? FileManager.default.removeItem(atPath: dstPath)
                    }
                    try FileManager.default.copyItem(atPath: srcPath, toPath: dstPath)
                    landed.append(file.path)
                }
            }
        }

        workspace.updateState(.landed)
        return TaskLandingResult(
            succeeded: true,
            taskID: taskID,
            reason: "Changes reviewed and landed successfully",
            landedFiles: landed
        )
    }
}
