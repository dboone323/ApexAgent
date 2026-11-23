import Foundation
@preconcurrency import EventKit
import Contacts
import Photos

// MARK: - Personal Context Source Adapter Protocol (Issue #85)

public protocol PersonalContextSourceAdapter: Sendable {
    var source: PersonalContextSource { get }
    func checkStatus() async -> PersonalContextSourceStatus
    func search(query: String, limit: Int) async -> [PersonalContextHit]
}

// MARK: - 1. Mail Adapter
// Hard rule: Apple Mail has NO public read API on macOS.
// Mail adapter reports unavailable with a clear reason; never accesses private data stores or fakes messages.

public final class MailContextAdapter: PersonalContextSourceAdapter, @unchecked Sendable {
    public let source: PersonalContextSource = .mail

    public static let unavailableReason = "Apple Mail does not provide a public read API on macOS. Direct access to private mail databases or scripting Mail.app without public API is disabled for user privacy."

    public init() {}

    public func checkStatus() async -> PersonalContextSourceStatus {
        return .unavailable(reason: Self.unavailableReason)
    }

    public func search(query: String, limit: Int) async -> [PersonalContextHit] {
        // Mail is unavailable; no messages are ever fabricated
        return []
    }
}

// MARK: - 2. Calendar Adapter (EventKit)

public final class CalendarContextAdapter: PersonalContextSourceAdapter, @unchecked Sendable {
    public let source: PersonalContextSource = .calendar

    private let simulatedStatus: PersonalContextSourceStatus?
    private let syntheticEvents: [EKEvent]?

    public init(
        simulatedStatus: PersonalContextSourceStatus? = nil,
        syntheticEvents: [EKEvent]? = nil
    ) {
        self.simulatedStatus = simulatedStatus
        self.syntheticEvents = syntheticEvents
    }

    public func checkStatus() async -> PersonalContextSourceStatus {
        if let sim = simulatedStatus {
            return sim
        }

        // If synthetic events are provided for test fixtures, treat as available
        if syntheticEvents != nil {
            return .available
        }

        // Headless test mode check
        if ContactsOptInManager.shared.isTestMode && !ContactsOptInManager.shared.isOptedIn {
            return .denied(reason: "Calendar access is disabled in test mode without explicit opt-in.")
        }

        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .authorized:
            return .available
        case .denied:
            return .denied(reason: "Calendar access was denied in macOS System Settings > Privacy & Security > Calendars.")
        case .restricted:
            return .restricted(reason: "Calendar access is restricted by device policy.")
        case .notDetermined:
            return .notDetermined(reason: "Calendar permission has not yet been granted.")
        case .fullAccess:
            return .available
        case .writeOnly:
            return .restricted(reason: "Calendar access is write-only; reading events is not permitted.")
        @unknown default:
            return .unavailable(reason: "Unknown calendar authorization status.")
        }
    }

    public func search(query: String, limit: Int) async -> [PersonalContextHit] {
        let status = await checkStatus()
        guard status.isAvailable else { return [] }

        let normalizedQuery = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedQuery.isEmpty { return [] }

        // If synthetic events are provided, search them directly (Read-Only)
        if let events = syntheticEvents {
            return events.compactMap { event -> PersonalContextHit? in
                let title = event.title ?? ""
                let notes = event.notes ?? ""
                let location = event.location ?? ""
                let matches = title.localizedCaseInsensitiveContains(normalizedQuery) ||
                              notes.localizedCaseInsensitiveContains(normalizedQuery) ||
                              location.localizedCaseInsensitiveContains(normalizedQuery)
                guard matches else { return nil }

                let snippetParts = [title, location.isEmpty ? nil : "📍 \(location)", notes.isEmpty ? nil : notes].compactMap { $0 }
                let snippet = snippetParts.joined(separator: " — ")

                return PersonalContextHit(
                    id: event.eventIdentifier ?? UUID().uuidString,
                    source: .calendar,
                    title: title.isEmpty ? "Untitled Event" : title,
                    snippet: snippet,
                    timestamp: event.startDate,
                    metadata: [
                        "location": location,
                        "startDate": event.startDate != nil ? ISO8601DateFormatter().string(from: event.startDate) : "",
                        "endDate": event.endDate != nil ? ISO8601DateFormatter().string(from: event.endDate) : ""
                    ]
                )
            }.prefix(limit).map { $0 }
        }

        // Live EventKit search (Read-Only)
        let store = EKEventStore()
        let now = Date()
        let startDate = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now
        let endDate = Calendar.current.date(byAdding: .day, value: 90, to: now) ?? now
        let predicate = store.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
        let events = store.events(matching: predicate)

        var hits: [PersonalContextHit] = []
        for event in events {
            let title = event.title ?? ""
            let notes = event.notes ?? ""
            let location = event.location ?? ""
            if title.localizedCaseInsensitiveContains(normalizedQuery) ||
               notes.localizedCaseInsensitiveContains(normalizedQuery) ||
               location.localizedCaseInsensitiveContains(normalizedQuery) {
                let snippetParts = [title, location.isEmpty ? nil : "📍 \(location)", notes.isEmpty ? nil : notes].compactMap { $0 }
                hits.append(PersonalContextHit(
                    id: event.eventIdentifier ?? UUID().uuidString,
                    source: .calendar,
                    title: title.isEmpty ? "Untitled Event" : title,
                    snippet: snippetParts.joined(separator: " — "),
                    timestamp: event.startDate,
                    metadata: [
                        "location": location,
                        "startDate": event.startDate != nil ? ISO8601DateFormatter().string(from: event.startDate) : "",
                        "endDate": event.endDate != nil ? ISO8601DateFormatter().string(from: event.endDate) : ""
                    ]
                ))
                if hits.count >= limit { break }
            }
        }
        return hits
    }
}

// MARK: - 3. Contacts Adapter (Contacts Framework via ContactsOptInManager)

public final class ContactsContextAdapter: PersonalContextSourceAdapter, @unchecked Sendable {
    public let source: PersonalContextSource = .contacts

    private let simulatedStatus: PersonalContextSourceStatus?
    private let syntheticContacts: [CNContact]?

    public init(
        simulatedStatus: PersonalContextSourceStatus? = nil,
        syntheticContacts: [CNContact]? = nil
    ) {
        self.simulatedStatus = simulatedStatus
        self.syntheticContacts = syntheticContacts
    }

    public func checkStatus() async -> PersonalContextSourceStatus {
        if let sim = simulatedStatus {
            return sim
        }

        // If synthetic contacts are provided for test fixtures, treat as available
        if syntheticContacts != nil {
            return .available
        }

        // Contacts Privacy Fence: MUST respect ContactsOptInManager
        if !ContactsOptInManager.shared.isOptedIn {
            return .unavailable(reason: "Contacts access is disabled. Enable contacts opt-in via ContactsOptInManager.")
        }

        if ContactsOptInManager.shared.isTestMode {
            return .denied(reason: "Contacts access is safely disabled in test mode to protect user privacy.")
        }

        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized:
            return .available
        case .denied:
            return .denied(reason: "Contacts access was denied in macOS System Settings > Privacy & Security > Contacts.")
        case .restricted:
            return .restricted(reason: "Contacts access is restricted by device policy.")
        case .notDetermined:
            return .notDetermined(reason: "Contacts permission has not yet been granted.")
        @unknown default:
            return .unavailable(reason: "Unknown contacts authorization status.")
        }
    }

    public func search(query: String, limit: Int) async -> [PersonalContextHit] {
        let status = await checkStatus()
        guard status.isAvailable else { return [] }

        let normalizedQuery = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedQuery.isEmpty { return [] }

        // If synthetic contacts are provided, search them (Read-Only)
        if let contacts = syntheticContacts {
            return contacts.compactMap { contact -> PersonalContextHit? in
                let fullName = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
                let emails = contact.emailAddresses.map { $0.value as String }
                let phones = contact.phoneNumbers.map { $0.value.stringValue }
                let org = contact.organizationName

                let matches = fullName.localizedCaseInsensitiveContains(normalizedQuery) ||
                              org.localizedCaseInsensitiveContains(normalizedQuery) ||
                              emails.contains { $0.localizedCaseInsensitiveContains(normalizedQuery) } ||
                              phones.contains { $0.localizedCaseInsensitiveContains(normalizedQuery) }

                guard matches else { return nil }

                let snippetParts = [
                    fullName.isEmpty ? nil : fullName,
                    org.isEmpty ? nil : "🏢 \(org)",
                    emails.first.map { "✉️ \($0)" },
                    phones.first.map { "📞 \($0)" }
                ].compactMap { $0 }

                return PersonalContextHit(
                    id: contact.identifier,
                    source: .contacts,
                    title: fullName.isEmpty ? (org.isEmpty ? "Unnamed Contact" : org) : fullName,
                    snippet: snippetParts.joined(separator: " — "),
                    timestamp: nil,
                    metadata: [
                        "organization": org,
                        "email": emails.first ?? "",
                        "phone": phones.first ?? ""
                    ]
                )
            }.prefix(limit).map { $0 }
        }

        // Live Contacts Search (Read-Only via ContactsOptInManager gate)
        guard ContactsOptInManager.shared.isOptedIn && !ContactsOptInManager.shared.isTestMode else {
            return []
        }

        let store = CNContactStore()
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactJobTitleKey as CNKeyDescriptor
        ]

        let predicate = CNContact.predicateForContacts(matchingName: normalizedQuery)
        do {
            let matched = try store.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)
            return matched.prefix(limit).map { contact in
                let fullName = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
                let emails = contact.emailAddresses.map { $0.value as String }
                let phones = contact.phoneNumbers.map { $0.value.stringValue }
                let org = contact.organizationName

                let snippetParts = [
                    fullName.isEmpty ? nil : fullName,
                    org.isEmpty ? nil : "🏢 \(org)",
                    emails.first.map { "✉️ \($0)" },
                    phones.first.map { "📞 \($0)" }
                ].compactMap { $0 }

                return PersonalContextHit(
                    id: contact.identifier,
                    source: .contacts,
                    title: fullName.isEmpty ? (org.isEmpty ? "Unnamed Contact" : org) : fullName,
                    snippet: snippetParts.joined(separator: " — "),
                    timestamp: nil,
                    metadata: [
                        "organization": org,
                        "email": emails.first ?? "",
                        "phone": phones.first ?? ""
                    ]
                )
            }
        } catch {
            return []
        }
    }
}

// MARK: - 4. Files Adapter (Foundation FileManager)

public final class FilesContextAdapter: PersonalContextSourceAdapter, @unchecked Sendable {
    public let source: PersonalContextSource = .files

    private let searchRoot: URL
    private let simulatedStatus: PersonalContextSourceStatus?

    public init(
        searchRoot: URL? = nil,
        simulatedStatus: PersonalContextSourceStatus? = nil
    ) {
        self.searchRoot = searchRoot ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        self.simulatedStatus = simulatedStatus
    }

    public func checkStatus() async -> PersonalContextSourceStatus {
        if let sim = simulatedStatus {
            return sim
        }

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: searchRoot.path, isDirectory: &isDir)
        guard exists else {
            return .unavailable(reason: "Search directory does not exist: \(searchRoot.path)")
        }

        guard FileManager.default.isReadableFile(atPath: searchRoot.path) else {
            return .denied(reason: "Directory is not readable: \(searchRoot.path)")
        }

        return .available
    }

    public func search(query: String, limit: Int) async -> [PersonalContextHit] {
        let status = await checkStatus()
        guard status.isAvailable else { return [] }

        let normalizedQuery = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedQuery.isEmpty { return [] }

        let fm = FileManager.default
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = fm.enumerator(
            at: searchRoot,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var hits: [PersonalContextHit] = []
        let textExtensions: Set<String> = ["txt", "md", "json", "swift", "csv", "log", "yaml", "yml", "xml", "html"]

        while let fileURL = enumerator.nextObject() as? URL {
            guard let values = try? fileURL.resourceValues(forKeys: Set(resourceKeys)),
                  values.isRegularFile == true else {
                continue
            }

            let fileName = fileURL.lastPathComponent
            let ext = fileURL.pathExtension.lowercased()
            let modDate = values.contentModificationDate

            // Check filename match
            var isMatch = fileName.localizedCaseInsensitiveContains(normalizedQuery)
            var snippet = "File: \(fileURL.path)"

            // Check file text contents (read-only)
            if !isMatch && textExtensions.contains(ext) {
                if let size = values.fileSize, size <= 1_000_000 { // Max 1MB scan per file
                    if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                        if let range = content.range(of: normalizedQuery, options: .caseInsensitive) {
                            isMatch = true
                            let start = content.index(range.lowerBound, offsetBy: -40, limitedBy: content.startIndex) ?? content.startIndex
                            let end = content.index(range.upperBound, offsetBy: 80, limitedBy: content.endIndex) ?? content.endIndex
                            let extracted = content[start..<end].replacingOccurrences(of: "\n", with: " ")
                            snippet = "...\(extracted)..."
                        }
                    }
                }
            }

            if isMatch {
                hits.append(PersonalContextHit(
                    id: fileURL.path,
                    source: .files,
                    title: fileName,
                    snippet: snippet,
                    timestamp: modDate,
                    metadata: [
                        "path": fileURL.path,
                        "extension": ext
                    ]
                ))
                if hits.count >= limit { break }
            }
        }

        return hits
    }
}

// MARK: - 5. Photos Adapter (PhotoKit / Synthetic Asset Reader)

public final class PhotosContextAdapter: PersonalContextSourceAdapter, @unchecked Sendable {
    public let source: PersonalContextSource = .photos

    private let simulatedStatus: PersonalContextSourceStatus?
    private let syntheticPhotosDirectory: URL?

    public init(
        simulatedStatus: PersonalContextSourceStatus? = nil,
        syntheticPhotosDirectory: URL? = nil
    ) {
        self.simulatedStatus = simulatedStatus
        self.syntheticPhotosDirectory = syntheticPhotosDirectory
    }

    public func checkStatus() async -> PersonalContextSourceStatus {
        if let sim = simulatedStatus {
            return sim
        }

        // If synthetic directory provided for test fixtures, check directory readability
        if let dir = syntheticPhotosDirectory {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir)
            if exists && isDir.boolValue && FileManager.default.isReadableFile(atPath: dir.path) {
                return .available
            } else {
                return .unavailable(reason: "Synthetic photos directory is not accessible: \(dir.path)")
            }
        }

        // In test mode without opt-in, safely degrade
        if ContactsOptInManager.shared.isTestMode && !ContactsOptInManager.shared.isOptedIn {
            return .denied(reason: "Photos library access is disabled in test mode without opt-in.")
        }

        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            return .available
        case .denied:
            return .denied(reason: "Photos library access was denied in macOS System Settings > Privacy & Security > Photos.")
        case .restricted:
            return .restricted(reason: "Photos library access is restricted by device policy.")
        case .notDetermined:
            return .notDetermined(reason: "Photos library permission has not yet been granted.")
        @unknown default:
            return .unavailable(reason: "Unknown Photos authorization status.")
        }
    }

    public func search(query: String, limit: Int) async -> [PersonalContextHit] {
        let status = await checkStatus()
        guard status.isAvailable else { return [] }

        let normalizedQuery = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedQuery.isEmpty { return [] }

        // If synthetic photos directory is provided, search image files and metadata (Read-Only)
        if let dir = syntheticPhotosDirectory {
            let fm = FileManager.default
            let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "tiff", "gif"]
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else {
                return []
            }

            var hits: [PersonalContextHit] = []
            for fileURL in files {
                let ext = fileURL.pathExtension.lowercased()
                guard imageExtensions.contains(ext) else { continue }

                let fileName = fileURL.lastPathComponent
                if fileName.localizedCaseInsensitiveContains(normalizedQuery) {
                    let attrs = try? fm.attributesOfItem(atPath: fileURL.path)
                    let modDate = attrs?[.modificationDate] as? Date
                    let size = attrs?[.size] as? Int64 ?? 0

                    hits.append(PersonalContextHit(
                        id: fileURL.path,
                        source: .photos,
                        title: fileName,
                        snippet: "Photo asset (\(ext.uppercased()), \(size) bytes) at \(fileURL.lastPathComponent)",
                        timestamp: modDate,
                        metadata: [
                            "path": fileURL.path,
                            "fileSize": "\(size)"
                        ]
                    ))
                    if hits.count >= limit { break }
                }
            }
            return hits
        }

        // Live PhotoKit search (Read-Only)
        let fetchOptions = PHFetchOptions()
        fetchOptions.fetchLimit = limit
        let fetchResult = PHAsset.fetchAssets(with: .image, options: fetchOptions)

        var hits: [PersonalContextHit] = []
        fetchResult.enumerateObjects { asset, _, stop in
            let id = asset.localIdentifier
            if id.localizedCaseInsensitiveContains(normalizedQuery) {
                hits.append(PersonalContextHit(
                    id: id,
                    source: .photos,
                    title: "Photo \(id)",
                    snippet: "Photo asset \(asset.pixelWidth)x\(asset.pixelHeight) created \(asset.creationDate?.description ?? "unknown")",
                    timestamp: asset.creationDate,
                    metadata: [
                        "pixelWidth": "\(asset.pixelWidth)",
                        "pixelHeight": "\(asset.pixelHeight)"
                    ]
                ))
                if hits.count >= limit {
                    stop.pointee = true
                }
            }
        }
        return hits
    }
}
