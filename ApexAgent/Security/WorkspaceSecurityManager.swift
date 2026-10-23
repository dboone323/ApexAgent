import Foundation
import AppKit

/// Manages security-scoped folder access and persistent bookmarks for ApexAgent workspaces.
/// Ensures folder permissions are requested cleanly via standard macOS dialogs once and remembered
/// across launches without triggering sudden TCC prompts during startup.
@MainActor
public final class WorkspaceSecurityManager: ObservableObject {
    public static let shared = WorkspaceSecurityManager()

    public static let bookmarkDefaultsKey = "apex.workspaceBookmark"
    public static let pathDefaultsKey = "apex.workspacePath"

    @Published public private(set) var activeWorkspaceURL: URL?
    @Published public private(set) var activeWorkspacePath: String?

    private var isAccessingResource = false

    private init() {
        _ = resolveActiveWorkspace()
    }

    /// Stops accessing the current security-scoped URL if active.
    public func stopAccessingCurrentWorkspace() {
        if isAccessingResource, let url = activeWorkspaceURL {
            url.stopAccessingSecurityScopedResource()
            isAccessingResource = false
        }
    }

    /// Resolves the saved security-scoped bookmark from UserDefaults.
    /// Returns the URL and begins accessing the security-scoped resource if valid.
    @discardableResult
    public func resolveActiveWorkspace() -> URL? {
        if let existing = activeWorkspaceURL, isAccessingResource {
            return existing
        }

        guard let bookmarkData = UserDefaults.standard.data(forKey: Self.bookmarkDefaultsKey) else {
            // Check if a path exists from explicit environment or stored defaults
            if let envPath = ProcessInfo.processInfo.environment["APEX_WORKSPACE"],
               !envPath.isEmpty,
               FileManager.default.fileExists(atPath: envPath) {
                let url = URL(fileURLWithPath: envPath)
                self.activeWorkspaceURL = url
                self.activeWorkspacePath = envPath
                return url
            }
            if let savedPath = UserDefaults.standard.string(forKey: Self.pathDefaultsKey),
               !savedPath.isEmpty,
               FileManager.default.fileExists(atPath: savedPath) {
                let url = URL(fileURLWithPath: savedPath)
                self.activeWorkspaceURL = url
                self.activeWorkspacePath = savedPath
                return url
            }
            return nil
        }

        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                _ = saveWorkspaceURL(url)
            }

            if url.startAccessingSecurityScopedResource() {
                isAccessingResource = true
            }

            self.activeWorkspaceURL = url
            self.activeWorkspacePath = url.path
            return url
        } catch {
            AppLog.error(.security, "Failed to resolve workspace security bookmark: \(error.localizedDescription)")
            return nil
        }
    }

    /// Saves a security-scoped bookmark for the given folder URL.
    /// Remembers the user's selection permanently in UserDefaults.
    @discardableResult
    public func saveWorkspaceURL(_ url: URL) -> Bool {
        stopAccessingCurrentWorkspace()

        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )

            UserDefaults.standard.set(bookmarkData, forKey: Self.bookmarkDefaultsKey)
            UserDefaults.standard.set(url.path, forKey: Self.pathDefaultsKey)

            if url.startAccessingSecurityScopedResource() {
                isAccessingResource = true
            }

            self.activeWorkspaceURL = url
            self.activeWorkspacePath = url.path
            AppLog.info(.security, "Workspace security-scoped bookmark saved successfully for \(url.path)")
            return true
        } catch {
            UserDefaults.standard.set(url.path, forKey: Self.pathDefaultsKey)
            self.activeWorkspaceURL = url
            self.activeWorkspacePath = url.path
            AppLog.notice(.security, "Stored workspace path without security-scoped bookmark: \(error.localizedDescription)")
            return true
        }
    }

    /// Prompts the user with a standard macOS open panel to select a workspace folder.
    @discardableResult
    public func promptUserForWorkspace(window: NSWindow? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Workspace"
        panel.message = "Choose a working directory for ApexAgent projects and tools."
        if let currentPath = activeWorkspacePath {
            panel.directoryURL = URL(fileURLWithPath: currentPath)
        }

        let response: NSApplication.ModalResponse
        if let window {
            let group = DispatchGroup()
            group.enter()
            var res: NSApplication.ModalResponse = .cancel
            panel.beginSheetModal(for: window) { modalResponse in
                res = modalResponse
                group.leave()
            }
            group.wait()
            response = res
        } else {
            response = panel.runModal()
        }

        if response == .OK, let selectedURL = panel.url {
            _ = saveWorkspaceURL(selectedURL)
            return selectedURL
        }
        return nil
    }

    public var hasWorkspaceConfigured: Bool {
        activeWorkspaceURL != nil || UserDefaults.standard.data(forKey: Self.bookmarkDefaultsKey) != nil || UserDefaults.standard.string(forKey: Self.pathDefaultsKey) != nil
    }
}
