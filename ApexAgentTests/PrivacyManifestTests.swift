import Testing
import Foundation
@testable import ApexAgentCore

@Suite("PrivacyManifestTests")
struct PrivacyManifestTests {

    @Test func bundledManifestExistsAndDisablesTracking() throws {
        let report = try PrivacyManifestInspector.loadBundledManifest()
        #expect(report.trackingEnabled == false)
        #expect(report.trackingDomains.isEmpty)
        #expect(!report.collectedDataTypes.isEmpty)
        for item in report.collectedDataTypes {
            #expect(item.tracking == false)
            #expect(item.linked == false)
            #expect(!item.purposes.isEmpty)
        }
    }

    @Test func bundledManifestDeclaresUserDefaultsFileTimestampAndDiskSpaceReasons() throws {
        let report = try PrivacyManifestInspector.loadBundledManifest()

        // UserDefaults: CA92.1 (same-app) and 1C8F.1 (app group suite)
        #expect(report.declaresAccessedAPI(
            PrivacyManifestInspector.userDefaultsCategory,
            reason: "CA92.1"
        ))
        #expect(report.declaresAccessedAPI(
            PrivacyManifestInspector.userDefaultsCategory,
            reason: "1C8F.1"
        ))

        // File timestamps: C617.1 (app container) and 0A2A.1 (user-granted files)
        #expect(report.declaresAccessedAPI(
            PrivacyManifestInspector.fileTimestampCategory,
            reason: "C617.1"
        ))
        #expect(report.declaresAccessedAPI(
            PrivacyManifestInspector.fileTimestampCategory,
            reason: "0A2A.1"
        ))

        // Disk space: E174.1 and 85F4.1
        #expect(report.declaresAccessedAPI(
            PrivacyManifestInspector.diskSpaceCategory,
            reason: "E174.1"
        ))
        #expect(report.declaresAccessedAPI(
            PrivacyManifestInspector.diskSpaceCategory,
            reason: "85F4.1"
        ))
    }

    @Test func sourceAuditCrossCheckMatchesShippedPrivacyManifest() throws {
        let report = try PrivacyManifestInspector.loadBundledManifest()

        // Walk the real ApexAgent source directory relative to this test file
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = testFileURL.deletingLastPathComponent().deletingLastPathComponent()
        let appSourceDir = repoRoot.appendingPathComponent("ApexAgent", isDirectory: true)

        var detectedCategories: Set<String> = []
        var userDefaultsFileCount = 0

        if let enumerator = FileManager.default.enumerator(
            at: appSourceDir,
            includingPropertiesForKeys: nil
        ) {
            for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
                // Skip the inspector itself so its string literals don't self-trigger
                if fileURL.lastPathComponent == "PrivacyManifestInspector.swift" { continue }
                if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
                    let cats = PrivacyManifestInspector.detectRequiredCategories(inSwiftSource: text)
                    if cats.contains(PrivacyManifestInspector.userDefaultsCategory) {
                        userDefaultsFileCount += 1
                    }
                    detectedCategories.formUnion(cats)
                }
            }
        }

        #expect(userDefaultsFileCount >= 25)
        #expect(detectedCategories.contains(PrivacyManifestInspector.userDefaultsCategory))
        #expect(detectedCategories.contains(PrivacyManifestInspector.fileTimestampCategory))
        #expect(detectedCategories.contains(PrivacyManifestInspector.diskSpaceCategory))

        // Every category detected across the shipping Swift codebase must be declared
        let missing = report.missingCategories(for: detectedCategories)
        #expect(missing.isEmpty)
    }

    @Test func missingCategoriesDetectsUndeclaredAPITypes() throws {
        let minimalXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>NSPrivacyTracking</key>
            <false/>
            <key>NSPrivacyTrackingDomains</key>
            <array/>
            <key>NSPrivacyAccessedAPITypes</key>
            <array/>
        </dict>
        </plist>
        """
        let parsed = try PrivacyManifestInspector.parse(data: Data(minimalXML.utf8))
        let missing = parsed.missingCategories(for: [PrivacyManifestInspector.userDefaultsCategory])
        #expect(missing == [PrivacyManifestInspector.userDefaultsCategory])
    }
}
