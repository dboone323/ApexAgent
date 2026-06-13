import Foundation

struct ProjectAuditReport: Identifiable, Codable {
    var id: String { name }
    let name: String
    let path: String
    let swiftVersion: String
    let strictConcurrency: String
    let deploymentTarget: String
    let fileCount: Int
    let todoCount: Int
    let brokenReferences: [String]
    let warnings: [String]
}

@MainActor
class ProjectAuditor {
    static let shared = ProjectAuditor()
    
    private(set) var cachedReports: [ProjectAuditReport] = []
    private let queue = DispatchQueue(label: "com.apexagent.project.auditor")
    
    func getCachedReports() -> [ProjectAuditReport] {
        return cachedReports
    }
    
    func runWorkspaceAudit(at path: String) async -> [ProjectAuditReport] {
        let reports = await Task.detached(priority: .userInitiated) {
            return self.performAudit(at: path)
        }.value
        
        self.cachedReports = reports
        return reports
    }
    
    nonisolated private func performAudit(at workspacePath: String) -> [ProjectAuditReport] {
        let fm = FileManager.default
        let resolvedPath = (workspacePath as NSString).expandingTildeInPath
        let standardized = URL(fileURLWithPath: resolvedPath).standardized.path
        
        guard standardized != "/" && !standardized.isEmpty else {
            return []
        }
        
        var reports: [ProjectAuditReport] = []
        
        guard fm.fileExists(atPath: resolvedPath) else {
            return []
        }
        
        // Locate all .xcodeproj directories in the workspace (up to depth 4)
        let rootURL = URL(fileURLWithPath: resolvedPath)
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        guard let enumerator = fm.enumerator(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: options) else {
            return []
        }
        
        var projectURLs: [URL] = []
        for case let url as URL in enumerator {
            let lastComponent = url.lastPathComponent
            if lastComponent == ".build" || lastComponent == "build" || lastComponent == "DerivedData" || lastComponent == ".git" || lastComponent == ".antigravity" {
                enumerator.skipDescendants()
                continue
            }
            if url.pathExtension == "xcodeproj" {
                projectURLs.append(url)
                enumerator.skipDescendants() // No need to scan inside xcodeproj bundle
            }
        }
        
        for projectURL in projectURLs {
            let report = auditProject(at: projectURL)
            reports.append(report)
        }
        
        return reports
    }
    
    nonisolated private func auditProject(at projectURL: URL) -> ProjectAuditReport {
        let fm = FileManager.default
        let name = projectURL.deletingPathExtension().lastPathComponent
        let projectDir = projectURL.deletingLastPathComponent()
        let pbxprojURL = projectURL.appendingPathComponent("project.pbxproj")
        
        var swiftVersion = "Unknown"
        var strictConcurrency = "minimal"
        var deploymentTarget = "Unknown"
        var warnings: [String] = []
        var fileReferences: [String] = []
        
        // 1. Read and parse project.pbxproj
        if let pbxContent = try? String(contentsOf: pbxprojURL, encoding: .utf8) {
            let lines = pbxContent.components(separatedBy: .newlines)
            
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                
                // Parse Swift version
                if trimmed.hasPrefix("SWIFT_VERSION"), let val = extractValue(from: trimmed) {
                    swiftVersion = val
                }
                
                // Parse Swift strict concurrency
                if trimmed.hasPrefix("SWIFT_STRICT_CONCURRENCY"), let val = extractValue(from: trimmed) {
                    strictConcurrency = val
                }
                
                // Parse deployment target (macOS or iOS)
                if (trimmed.hasPrefix("MACOSX_DEPLOYMENT_TARGET") || trimmed.hasPrefix("IPHONEOS_DEPLOYMENT_TARGET")),
                   let val = extractValue(from: trimmed) {
                    deploymentTarget = val
                }
                
                // Extract file references for broken references check
                if trimmed.contains("isa = PBXFileReference;"), trimmed.contains("path = ") {
                    if let pathVal = extractFileRefPath(from: trimmed) {
                        fileReferences.append(pathVal)
                    }
                }
            }
        } else {
            warnings.append("Could not open project.pbxproj file.")
        }
        
        // 2. Scan project files recursively
        var swiftFilesCount = 0
        var todoCount = 0
        var foundFilePaths: Set<String> = []
        
        let fileEnumerator = fm.enumerator(at: projectDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        if let enumerator = fileEnumerator {
            for case let url as URL in enumerator {
                let lastComponent = url.lastPathComponent
                if lastComponent == ".build" || lastComponent == "build" || lastComponent == "DerivedData" || lastComponent == ".git" || lastComponent == ".antigravity" {
                    enumerator.skipDescendants()
                    continue
                }
                
                if url.pathExtension == "swift" {
                    swiftFilesCount += 1
                    foundFilePaths.insert(url.lastPathComponent)
                    
                    // Count TODOs/FIXMEs
                    if let contents = try? String(contentsOf: url, encoding: .utf8) {
                        let lines = contents.components(separatedBy: .newlines)
                        for line in lines {
                            let upper = line.uppercased()
                            if upper.contains("TODO:") || upper.contains("TODO ") || upper.contains("FIXME:") || upper.contains("FIXME ") {
                                todoCount += 1
                            }
                        }
                    }
                } else if !url.pathExtension.isEmpty {
                    foundFilePaths.insert(url.lastPathComponent)
                }
            }
        }
        
        // 3. Find broken file references (referenced in project settings but missing on disk)
        var brokenRefs: [String] = []
        for fileRef in fileReferences {
            // Check if last path component exists anywhere in our found files
            let fileName = (fileRef as NSString).lastPathComponent
            
            // Exclude directories, pods, system libraries, SPM build artifacts or checkouts, and build products (like .xctest)
            if fileName.isEmpty || fileRef.contains(".framework") || fileRef.contains(".tbd") || fileRef.contains(".a") || fileRef.hasPrefix("Packages/") || fileRef.contains(".build") || fileRef.contains(".xctest") {
                continue
            }
            
            if !foundFilePaths.contains(fileName) {
                // Double check if file exists directly at absolute path in project dir
                let directURL = projectDir.appendingPathComponent(fileRef)
                if !fm.fileExists(atPath: directURL.path) {
                    brokenRefs.append(fileRef)
                }
            }
        }
        
        // 4. Formulate warnings based on compliance standards
        if swiftVersion == "Unknown" {
            warnings.append("Swift version is not explicitly defined in build settings.")
        } else if let versionDouble = Double(swiftVersion), versionDouble < 6.0 {
            warnings.append("Target Swift version is \(swiftVersion). Recommended: Swift 6.0+")
        }
        
        if strictConcurrency != "complete" {
            warnings.append("Strict Concurrency is '\(strictConcurrency)'. Recommended: 'complete' (strict check).")
        }
        
        if !brokenRefs.isEmpty {
            warnings.append("Found \(brokenRefs.count) broken file reference(s) (missing on disk).")
        }
        
        return ProjectAuditReport(
            name: name,
            path: projectURL.path,
            swiftVersion: swiftVersion,
            strictConcurrency: strictConcurrency,
            deploymentTarget: deploymentTarget,
            fileCount: swiftFilesCount,
            todoCount: todoCount,
            brokenReferences: brokenRefs,
            warnings: warnings
        )
    }
    
    nonisolated private func extractValue(from line: String) -> String? {
        let parts = line.components(separatedBy: "=")
        guard parts.count == 2 else { return nil }
        var val = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " ;\"'"))
        return val.isEmpty ? nil : val
    }
    
    nonisolated private func extractFileRefPath(from line: String) -> String? {
        // Extract path value from string e.g. "... path = MainView.swift; ..."
        guard let pathRange = line.range(of: "path = ") else { return nil }
        let sub = line[pathRange.upperBound...]
        guard let semiRange = sub.range(of: ";") else { return nil }
        let val = sub[..<semiRange.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        return val.isEmpty ? nil : val
    }
}
