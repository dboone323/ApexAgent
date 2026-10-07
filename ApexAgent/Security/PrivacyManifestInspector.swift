import Foundation

// MARK: - App Privacy Manifest Inspector (Batch 23)

/// One required-reason API declaration inside `PrivacyInfo.xcprivacy`.
public struct PrivacyAccessedAPIDeclaration: Sendable, Equatable {
    public let apiType: String
    public let reasons: [String]

    public init(apiType: String, reasons: [String]) {
        self.apiType = apiType
        self.reasons = reasons
    }
}

/// One collected data type declaration inside `PrivacyInfo.xcprivacy`.
public struct PrivacyCollectedDataDeclaration: Sendable, Equatable {
    public let dataType: String
    public let linked: Bool
    public let tracking: Bool
    public let purposes: [String]

    public init(dataType: String, linked: Bool, tracking: Bool, purposes: [String]) {
        self.dataType = dataType
        self.linked = linked
        self.tracking = tracking
        self.purposes = purposes
    }
}

/// Parsed representation of the app's `PrivacyInfo.xcprivacy` manifest.
public struct PrivacyManifestReport: Sendable, Equatable {
    public let trackingEnabled: Bool
    public let trackingDomains: [String]
    public let accessedAPITypes: [PrivacyAccessedAPIDeclaration]
    public let collectedDataTypes: [PrivacyCollectedDataDeclaration]

    public init(
        trackingEnabled: Bool,
        trackingDomains: [String],
        accessedAPITypes: [PrivacyAccessedAPIDeclaration],
        collectedDataTypes: [PrivacyCollectedDataDeclaration]
    ) {
        self.trackingEnabled = trackingEnabled
        self.trackingDomains = trackingDomains
        self.accessedAPITypes = accessedAPITypes
        self.collectedDataTypes = collectedDataTypes
    }

    /// Returns true if the given `NSPrivacyAccessedAPIType` category is present
    /// and (when `reason` is provided) includes the specified reason code.
    public func declaresAccessedAPI(_ category: String, reason: String? = nil) -> Bool {
        guard let entry = accessedAPITypes.first(where: { $0.apiType == category }) else {
            return false
        }
        guard let reason else {
            return !entry.reasons.isEmpty
        }
        return entry.reasons.contains(reason)
    }

    /// Audits a set of required-reason API categories detected in source code
    /// against the manifest's `NSPrivacyAccessedAPITypes`, returning any missing categories.
    public func missingCategories(for requiredCategories: Set<String>) -> [String] {
        let declared = Set(accessedAPITypes.filter { !$0.reasons.isEmpty }.map(\.apiType))
        return requiredCategories.subtracting(declared).sorted()
    }
}

public enum PrivacyManifestError: Error, LocalizedError, Equatable {
    case manifestNotFound
    case invalidPropertyList

    public var errorDescription: String? {
        switch self {
        case .manifestNotFound:
            return "PrivacyInfo.xcprivacy was not found in the bundle."
        case .invalidPropertyList:
            return "PrivacyInfo.xcprivacy is not a valid dictionary property list."
        }
    }
}

private final class PrivacyManifestBundleAnchor {}

public enum PrivacyManifestInspector {
    public static let userDefaultsCategory = "NSPrivacyAccessedAPICategoryUserDefaults"
    public static let fileTimestampCategory = "NSPrivacyAccessedAPICategoryFileTimestamp"
    public static let diskSpaceCategory = "NSPrivacyAccessedAPICategoryDiskSpace"
    public static let systemBootTimeCategory = "NSPrivacyAccessedAPICategorySystemBootTime"

    /// Locates `PrivacyInfo.xcprivacy` in the `ApexAgentCore` framework bundle or main bundle.
    public static func bundledManifestURL() -> URL? {
        let frameworkBundle = Bundle(for: PrivacyManifestBundleAnchor.self)
        if let url = frameworkBundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy") {
            return url
        }
        if let url = Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy") {
            return url
        }
        for bundle in Bundle.allBundles {
            if let url = bundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy") {
                return url
            }
        }
        return nil
    }

    /// Loads and parses the shipped `PrivacyInfo.xcprivacy` from the bundle.
    public static func loadBundledManifest() throws -> PrivacyManifestReport {
        guard let url = bundledManifestURL() else {
            throw PrivacyManifestError.manifestNotFound
        }
        let data = try Data(contentsOf: url)
        return try parse(data: data)
    }

    /// Parses raw `PrivacyInfo.xcprivacy` property-list XML data.
    public static func parse(data: Data) throws -> PrivacyManifestReport {
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dict = plist as? [String: Any] else {
            throw PrivacyManifestError.invalidPropertyList
        }

        let tracking = (dict["NSPrivacyTracking"] as? Bool) ?? false
        let domains = (dict["NSPrivacyTrackingDomains"] as? [String]) ?? []

        var apiDeclarations: [PrivacyAccessedAPIDeclaration] = []
        if let rawAPIs = dict["NSPrivacyAccessedAPITypes"] as? [[String: Any]] {
            for item in rawAPIs {
                if let apiType = item["NSPrivacyAccessedAPIType"] as? String {
                    let reasons = (item["NSPrivacyAccessedAPITypeReasons"] as? [String]) ?? []
                    apiDeclarations.append(PrivacyAccessedAPIDeclaration(apiType: apiType, reasons: reasons))
                }
            }
        }

        var collectedDeclarations: [PrivacyCollectedDataDeclaration] = []
        if let rawCollected = dict["NSPrivacyCollectedDataTypes"] as? [[String: Any]] {
            for item in rawCollected {
                if let dataType = item["NSPrivacyCollectedDataType"] as? String {
                    let linked = (item["NSPrivacyCollectedDataTypeLinked"] as? Bool) ?? false
                    let isTracking = (item["NSPrivacyCollectedDataTypeTracking"] as? Bool) ?? false
                    let purposes = (item["NSPrivacyCollectedDataTypePurposes"] as? [String]) ?? []
                    collectedDeclarations.append(PrivacyCollectedDataDeclaration(
                        dataType: dataType,
                        linked: linked,
                        tracking: isTracking,
                        purposes: purposes
                    ))
                }
            }
        }

        return PrivacyManifestReport(
            trackingEnabled: tracking,
            trackingDomains: domains,
            accessedAPITypes: apiDeclarations,
            collectedDataTypes: collectedDeclarations
        )
    }

    /// Scans Swift source text to detect which Apple Required-Reason API categories it uses.
    public static func detectRequiredCategories(inSwiftSource source: String) -> Set<String> {
        var categories: Set<String> = []
        if source.contains("UserDefaults") || source.contains("@AppStorage") {
            categories.insert(userDefaultsCategory)
        }
        if source.contains("attributesOfItem(")
            || source.contains(".creationDate")
            || source.contains(".contentModificationDateKey") {
            categories.insert(fileTimestampCategory)
        }
        if source.contains("volumeAvailableCapacity")
            || source.contains("volumeTotalCapacityKey")
            || source.contains(".systemFreeSize")
            || source.contains(".systemSize") {
            categories.insert(diskSpaceCategory)
        }
        if source.contains(".systemUptime") {
            categories.insert(systemBootTimeCategory)
        }
        return categories
    }
}
