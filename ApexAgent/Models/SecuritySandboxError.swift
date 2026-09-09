import Foundation

public enum SecuritySandboxError: Error, CustomStringConvertible, Equatable {
    case pathViolation(String)
    case symlinkTraversal(String)
    case desktopFolderRestricted
    case documentsFolderRestricted
    case downloadsFolderRestricted
    case musicFolderRestricted
    
    public var description: String {
        switch self {
        case .pathViolation(let path):
            return "Security sandbox violation: path '\(path)' is outside the allowed workspace or temporary directories."
        case .symlinkTraversal(let path):
            return "Security sandbox violation: path '\(path)' contains symlinks resolving outside the allowed sandbox prefix."
        case .desktopFolderRestricted:
            return "Security sandbox violation: Desktop folder access is restricted by user settings."
        case .documentsFolderRestricted:
            return "Security sandbox violation: Documents folder access is restricted by user settings."
        case .downloadsFolderRestricted:
            return "Security sandbox violation: Downloads folder access is restricted by user settings."
        case .musicFolderRestricted:
            return "Security sandbox violation: Music folder access is restricted by user settings."
        }
    }
}
