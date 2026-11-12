import Foundation
import Darwin

/// Engine that performs a judgement pass over a checklist file, evaluates each item,
/// and durably records the outcome in both structured receipts and the checklist file itself.
public actor HeartbeatJudgementPass {
    public static let shared = HeartbeatJudgementPass()

    public private(set) var recentReports: [JudgementPassReport] = []
    private var heartbeatTask: Task<Void, Never>?
    private var isHeartbeatActive: Bool = false

    public init() {}

    deinit {
        heartbeatTask?.cancel()
    }

    /// Parses a checklist file into structured ``ChecklistItem`` models.
    public func parseChecklist(from content: String) -> [ChecklistItem] {
        let lines = content.components(separatedBy: .newlines)
        var items: [ChecklistItem] = []

        for (idx, line) in lines.enumerated() {
            let lineNumber = idx + 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            let isChecklistLine: Bool
            let status: ChecklistItemStatus
            let markerPrefix: String

            if trimmed.hasPrefix("- [ ]") {
                isChecklistLine = true
                status = .pending
                markerPrefix = "- [ ]"
            } else if trimmed.hasPrefix("- [x]") || trimmed.hasPrefix("- [X]") {
                isChecklistLine = true
                status = .passed
                markerPrefix = trimmed.hasPrefix("- [x]") ? "- [x]" : "- [X]"
            } else if trimmed.hasPrefix("- [!]") {
                isChecklistLine = true
                status = .failed
                markerPrefix = "- [!]"
            } else if trimmed.hasPrefix("- [-]") {
                isChecklistLine = true
                status = .skipped
                markerPrefix = "- [-]"
            } else {
                isChecklistLine = false
                status = .pending
                markerPrefix = ""
            }

            guard isChecklistLine else { continue }

            let titlePart = String(trimmed.dropFirst(markerPrefix.count)).trimmingCharacters(in: .whitespaces)
            let rule = parseRule(from: titlePart)

            let item = ChecklistItem(
                lineNumber: lineNumber,
                rawLine: line,
                title: titlePart,
                status: status,
                rule: rule
            )
            items.append(item)
        }

        return items
    }

    private func parseRule(from title: String) -> ChecklistRule {
        let cleanTitle = title.components(separatedBy: "<!--").first?.trimmingCharacters(in: .whitespaces) ?? title

        if cleanTitle.lowercased().hasPrefix("command:") {
            let cmd = String(cleanTitle.dropFirst("command:".count)).trimmingCharacters(in: .whitespaces)
            return .command(cmd: cmd, expectedExit: 0)
        } else if cleanTitle.lowercased().hasPrefix("file exists:") {
            let path = String(cleanTitle.dropFirst("file exists:".count)).trimmingCharacters(in: .whitespaces)
            return .fileExists(path: path)
        } else if cleanTitle.lowercased().hasPrefix("file not exists:") || cleanTitle.lowercased().hasPrefix("file absent:") {
            let path = String(cleanTitle.dropFirst("file not exists:".count)).trimmingCharacters(in: .whitespaces)
            return .fileNotExists(path: path)
        } else if cleanTitle.lowercased().hasPrefix("file contains") {
            // format: "File contains <path>: <text>"
            let remainder = String(cleanTitle.dropFirst("file contains".count)).trimmingCharacters(in: .whitespaces)
            if let colonIdx = remainder.firstIndex(of: ":") {
                let path = String(remainder[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let text = String(remainder[remainder.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                return .fileContains(path: path, substring: text)
            }
        } else if cleanTitle.lowercased().hasPrefix("lock not stale:") {
            let path = String(cleanTitle.dropFirst("lock not stale:".count)).trimmingCharacters(in: .whitespaces)
            return .lockNotStale(path: path, maxAgeSeconds: 3600)
        } else if cleanTitle.lowercased().hasPrefix("disk free:") {
            // format: "Disk free: 10% on /"
            let remainder = String(cleanTitle.dropFirst("disk free:".count)).trimmingCharacters(in: .whitespaces)
            let parts = remainder.components(separatedBy: " on ")
            let percentStr = parts.first?.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces) ?? "10"
            let percent = Double(percentStr) ?? 10.0
            let mount = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "/"
            return .diskFree(minPercent: percent, mount: mount)
        }

        return .manual
    }

    /// Evaluates a single checklist item using real system inspection.
    public func evaluate(item: ChecklistItem) async -> JudgementItemResult {
        let start = Date()

        // If already passed and no rule to re-evaluate, retain passed status
        if item.status == .passed && item.rule == nil {
            return JudgementItemResult(
                id: item.id,
                lineNumber: item.lineNumber,
                title: item.title,
                passed: true,
                status: .passed,
                reason: "Pre-marked completed",
                duration: 0.0
            )
        }

        guard let rule = item.rule else {
            return JudgementItemResult(
                id: item.id,
                lineNumber: item.lineNumber,
                title: item.title,
                passed: item.status == .passed,
                status: item.status,
                reason: item.status == .passed ? "Completed" : "Manual item without evaluation rule",
                duration: Date().timeIntervalSince(start)
            )
        }

        switch rule {
        case .command(let cmd, let expectedExit):
            let res = await executeShellCommand(cmd)
            let passed = (res.exitCode == expectedExit)
            let reason = passed ? "Command exited with \(res.exitCode)" : "Command failed (exit \(res.exitCode)): \(res.output.trimmingCharacters(in: .whitespacesAndNewlines))"
            return JudgementItemResult(
                id: item.id,
                lineNumber: item.lineNumber,
                title: item.title,
                passed: passed,
                status: passed ? .passed : .failed,
                reason: reason,
                duration: Date().timeIntervalSince(start)
            )

        case .fileExists(let path):
            let resolved = (path as NSString).expandingTildeInPath
            let exists = FileManager.default.fileExists(atPath: resolved)
            let reason = exists ? "File exists at '\(resolved)'" : "File missing at '\(resolved)'"
            return JudgementItemResult(
                id: item.id,
                lineNumber: item.lineNumber,
                title: item.title,
                passed: exists,
                status: exists ? .passed : .failed,
                reason: reason,
                duration: Date().timeIntervalSince(start)
            )

        case .fileNotExists(let path):
            let resolved = (path as NSString).expandingTildeInPath
            let absent = !FileManager.default.fileExists(atPath: resolved)
            let reason = absent ? "File correctly absent at '\(resolved)'" : "File exists unexpectedly at '\(resolved)'"
            return JudgementItemResult(
                id: item.id,
                lineNumber: item.lineNumber,
                title: item.title,
                passed: absent,
                status: absent ? .passed : .failed,
                reason: reason,
                duration: Date().timeIntervalSince(start)
            )

        case .fileContains(let path, let substring):
            let resolved = (path as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: resolved) else {
                return JudgementItemResult(
                    id: item.id,
                    lineNumber: item.lineNumber,
                    title: item.title,
                    passed: false,
                    status: .failed,
                    reason: "File not found at '\(resolved)'",
                    duration: Date().timeIntervalSince(start)
                )
            }
            guard let content = try? String(contentsOfFile: resolved, encoding: .utf8) else {
                return JudgementItemResult(
                    id: item.id,
                    lineNumber: item.lineNumber,
                    title: item.title,
                    passed: false,
                    status: .failed,
                    reason: "Failed to read file as UTF-8",
                    duration: Date().timeIntervalSince(start)
                )
            }
            let contains = content.contains(substring)
            let reason = contains ? "Found substring '\(substring)' in file" : "Substring '\(substring)' not found in file"
            return JudgementItemResult(
                id: item.id,
                lineNumber: item.lineNumber,
                title: item.title,
                passed: contains,
                status: contains ? .passed : .failed,
                reason: reason,
                duration: Date().timeIntervalSince(start)
            )

        case .lockNotStale(let path, let maxAgeSeconds):
            let resolved = (path as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: resolved) else {
                return JudgementItemResult(
                    id: item.id,
                    lineNumber: item.lineNumber,
                    title: item.title,
                    passed: true,
                    status: .passed,
                    reason: "Lock does not exist (unlocked)",
                    duration: Date().timeIntervalSince(start)
                )
            }
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: resolved)
                let modDate = attrs[.modificationDate] as? Date ?? Date()
                let age = Date().timeIntervalSince(modDate)
                let notStale = age <= maxAgeSeconds
                let reason = notStale ? "Lock age \(Int(age))s <= \(Int(maxAgeSeconds))s threshold" : "Lock STALE: age \(Int(age))s > \(Int(maxAgeSeconds))s"
                return JudgementItemResult(
                    id: item.id,
                    lineNumber: item.lineNumber,
                    title: item.title,
                    passed: notStale,
                    status: notStale ? .passed : .failed,
                    reason: reason,
                    duration: Date().timeIntervalSince(start)
                )
            } catch {
                return JudgementItemResult(
                    id: item.id,
                    lineNumber: item.lineNumber,
                    title: item.title,
                    passed: false,
                    status: .failed,
                    reason: "Failed to inspect lock attributes: \(error.localizedDescription)",
                    duration: Date().timeIntervalSince(start)
                )
            }

        case .diskFree(let minPercent, let mount):
            let resolved = (mount as NSString).expandingTildeInPath
            do {
                let attrs = try FileManager.default.attributesOfFileSystem(forPath: resolved)
                let freeBytes = (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
                let totalBytes = (attrs[.systemSize] as? NSNumber)?.int64Value ?? 1
                let freePercent = (Double(freeBytes) / Double(totalBytes)) * 100.0
                let passed = freePercent >= minPercent
                let reason = passed ? String(format: "Disk free %.1f%% >= %.1f%% threshold", freePercent, minPercent) : String(format: "Insufficient disk space: %.1f%% < %.1f%% threshold", freePercent, minPercent)
                return JudgementItemResult(
                    id: item.id,
                    lineNumber: item.lineNumber,
                    title: item.title,
                    passed: passed,
                    status: passed ? .passed : .failed,
                    reason: reason,
                    duration: Date().timeIntervalSince(start)
                )
            } catch {
                return JudgementItemResult(
                    id: item.id,
                    lineNumber: item.lineNumber,
                    title: item.title,
                    passed: false,
                    status: .failed,
                    reason: "Failed to query filesystem stats: \(error.localizedDescription)",
                    duration: Date().timeIntervalSince(start)
                )
            }

        case .manual:
            let passed = (item.status == .passed)
            return JudgementItemResult(
                id: item.id,
                lineNumber: item.lineNumber,
                title: item.title,
                passed: passed,
                status: item.status,
                reason: passed ? "Manually verified" : "Pending manual sign-off",
                duration: Date().timeIntervalSince(start)
            )
        }
    }

    /// Executes a full judgement pass over the checklist file.
    public func runPass(
        checklistURL: URL,
        updateInPlace: Bool = true
    ) async throws -> JudgementPassReport {
        let start = Date()
        let fileData = try Data(contentsOf: checklistURL)
        guard let content = String(data: fileData, encoding: .utf8) else {
            throw NSError(domain: "HeartbeatJudgementPass", code: 1, userInfo: [NSLocalizedDescriptionKey: "Checklist file is not valid UTF-8"])
        }

        let items = parseChecklist(from: content)
        var itemResults: [JudgementItemResult] = []

        for item in items {
            let result = await evaluate(item: item)
            itemResults.append(result)
        }

        let totalDuration = Date().timeIntervalSince(start)
        let passedCount = itemResults.filter { $0.passed }.count
        let failedCount = itemResults.filter { $0.status == .failed }.count
        let skippedCount = itemResults.filter { $0.status == .skipped }.count

        let report = JudgementPassReport(
            checklistPath: checklistURL.path,
            timestamp: start,
            duration: totalDuration,
            totalItems: itemResults.count,
            passedCount: passedCount,
            failedCount: failedCount,
            skippedCount: skippedCount,
            items: itemResults
        )

        recentReports.insert(report, at: 0)
        if recentReports.count > 50 {
            recentReports.removeLast(recentReports.count - 50)
        }

        // Record receipts
        let dir = checklistURL.deletingLastPathComponent()
        let baseName = checklistURL.deletingPathExtension().lastPathComponent
        let jsonReceiptURL = dir.appendingPathComponent("\(baseName).judgement.json")
        let mdReceiptURL = dir.appendingPathComponent("\(baseName).judgement.md")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let jsonData = try? encoder.encode(report) {
            try? jsonData.write(to: jsonReceiptURL, options: [.atomic])
        }
        try? report.formatAsMarkdown().write(to: mdReceiptURL, atomically: true, encoding: .utf8)

        // If requested, update original checklist file in place
        if updateInPlace {
            let updatedContent = updateChecklistContent(original: content, items: items, results: itemResults)
            try? updatedContent.write(to: checklistURL, atomically: true, encoding: .utf8)
        }

        AppLog.info(.routine, "HeartbeatJudgementPass: Completed pass for '\(checklistURL.lastPathComponent)' in \(String(format: "%.3f", totalDuration))s (\(passedCount)/\(items.count) passed)")

        return report
    }

    private func updateChecklistContent(
        original: String,
        items: [ChecklistItem],
        results: [JudgementItemResult]
    ) -> String {
        var lines = original.components(separatedBy: .newlines)
        let resultMap = Dictionary(uniqueKeysWithValues: results.map { ($0.lineNumber, $0) })

        for item in items {
            let lineIdx = item.lineNumber - 1
            guard lineIdx >= 0 && lineIdx < lines.count else { continue }
            guard let res = resultMap[item.lineNumber] else { continue }

            let currentLine = lines[lineIdx]
            let marker = res.passed ? "- [x]" : (res.status == .failed ? "- [!]" : "- [ ]")

            // Remove existing marker
            var lineRemainder = currentLine.trimmingCharacters(in: .whitespaces)
            for m in ["- [ ]", "- [x]", "- [X]", "- [!]", "- [-]"] {
                if lineRemainder.hasPrefix(m) {
                    lineRemainder = String(lineRemainder.dropFirst(m.count)).trimmingCharacters(in: .whitespaces)
                    break
                }
            }

            // Strip out older judgement timestamp comment if present
            if let commentRange = lineRemainder.range(of: "<!-- judged:") {
                lineRemainder = String(lineRemainder[..<commentRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            }

            let timestamp = ISO8601DateFormatter().string(from: Date())
            let newLine = "\(marker) \(lineRemainder) <!-- judged: \(res.passed ? "PASSED" : "FAILED") at \(timestamp) -->"
            lines[lineIdx] = newLine
        }

        return lines.joined(separator: "\n")
    }

    /// Starts a recurring heartbeat judgement pass loop.
    public func startHeartbeat(
        checklistURL: URL,
        intervalSeconds: TimeInterval = 60.0,
        updateInPlace: Bool = true
    ) {
        guard !isHeartbeatActive else { return }
        isHeartbeatActive = true

        heartbeatTask = Task { [weak self] in
            guard let self = self else { return }
            while !Task.isCancelled {
                _ = try? await self.runPass(checklistURL: checklistURL, updateInPlace: updateInPlace)
                let nanos = UInt64(intervalSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
        AppLog.info(.routine, "HeartbeatJudgementPass: Started recurring heartbeat on '\(checklistURL.lastPathComponent)' every \(intervalSeconds)s")
    }

    /// Stops recurring heartbeat judgement pass.
    public func stopHeartbeat() {
        isHeartbeatActive = false
        heartbeatTask?.cancel()
        heartbeatTask = nil
        AppLog.info(.routine, "HeartbeatJudgementPass: Stopped recurring heartbeat.")
    }

    private func executeShellCommand(_ cmd: String) async -> (exitCode: Int32, output: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", cmd]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let outStr = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: (process.terminationStatus, outStr))
            } catch {
                continuation.resume(returning: (-1, error.localizedDescription))
            }
        }
    }
}
