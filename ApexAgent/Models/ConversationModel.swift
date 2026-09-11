import Foundation
import SwiftData
import AppKit

// MARK: - Conversation

@Model
final class Conversation {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var botProfileId: UUID?

    @Relationship(deleteRule: .cascade)
    var messages: [Message]

    init(title: String = "New Conversation", botProfileId: UUID? = nil) {
        self.id = UUID()
        self.title = title
        self.createdAt = Date()
        self.updatedAt = Date()
        self.botProfileId = botProfileId
        self.messages = []
    }
}

// MARK: - Message

@Model
final class Message {
    var id: UUID
    var roleRaw: String
    var content: String
    var timestamp: Date
    var conversation: Conversation?
    
    @Attribute(.externalStorage)
    var attachmentsData: [Data]?

    var role: MessageRole {
        get {
            switch roleRaw {
            case "user": return .user
            case "assistant": return .assistant
            default: return .system
            }
        }
        set {
            switch newValue {
            case .user: roleRaw = "user"
            case .assistant: roleRaw = "assistant"
            case .system: roleRaw = "system"
            }
        }
    }

    var attachments: [NSImage] {
        guard let dataArray = attachmentsData else { return [] }
        return dataArray.compactMap { NSImage(data: $0) }
    }

    init(role: MessageRole, content: String, attachmentsData: [Data]? = nil) {
        self.id = UUID()
        self.roleRaw = {
            switch role {
            case .user: return "user"
            case .assistant: return "assistant"
            case .system: return "system"
            }
        }()
        self.content = content
        self.timestamp = Date()
        self.attachmentsData = attachmentsData
    }
}

// MARK: - NSImage Extensions

extension NSImage {
    var pngData: Data? {
        guard let tiff = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

// MARK: - Agent Memory

@Model
final class AgentMemory {
    var id: UUID
    var key: String
    var val: String
    var category: String
    var timestamp: Date
    var embeddingData: Data?

    init(key: String, val: String, category: String = "general") {
        self.id = UUID()
        self.key = key
        self.val = val
        self.category = category
        self.timestamp = Date()
    }
}

// MARK: - App Permissions

@Model
final class AppPermissions {
    var id: UUID
    var accessibilityAllowed: Bool
    var screenRecordingAllowed: Bool
    var systemAudioRecordingAllowed: Bool
    var musicFolderAllowed: Bool
    var desktopFolderAllowed: Bool
    var documentsFolderAllowed: Bool
    var downloadsFolderAllowed: Bool

    init(
        accessibilityAllowed: Bool = false,
        screenRecordingAllowed: Bool = false,
        systemAudioRecordingAllowed: Bool = false,
        musicFolderAllowed: Bool = false,
        desktopFolderAllowed: Bool = false,
        documentsFolderAllowed: Bool = false,
        downloadsFolderAllowed: Bool = false
    ) {
        self.id = UUID()
        self.accessibilityAllowed = accessibilityAllowed
        self.screenRecordingAllowed = screenRecordingAllowed
        self.systemAudioRecordingAllowed = systemAudioRecordingAllowed
        self.musicFolderAllowed = musicFolderAllowed
        self.desktopFolderAllowed = desktopFolderAllowed
        self.documentsFolderAllowed = documentsFolderAllowed
        self.downloadsFolderAllowed = downloadsFolderAllowed
    }
}
