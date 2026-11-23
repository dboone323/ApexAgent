import Foundation
import Testing
@preconcurrency import EventKit
import Contacts
import CryptoKit
@testable import ApexAgentCore

@Suite("Personal Context Index Tests (Issue #85)")
struct PersonalContextIndexTests {

    private func createTempWorkspace(prefix: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func computeFileHash(url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 1. Toggling a source off excludes its hits

    @Test("Toggling a source off excludes its hits and marks it in toggledOffSources")
    func testTogglingSourceOffExcludesHits() async throws {
        let tempDir = try createTempWorkspace(prefix: "test-toggle-off")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let docURL = tempDir.appendingPathComponent("ProjectPlan.md")
        try "Project Apollo launch milestones and deliverables.".write(to: docURL, atomically: true, encoding: .utf8)

        let toggleStore = PersonalContextToggleStore(inMemory: true)
        let filesAdapter = FilesContextAdapter(searchRoot: tempDir)
        let index = PersonalContextIndex(
            toggleStore: toggleStore,
            adapters: [.files: filesAdapter]
        )

        // When toggled ON, query returns the hit
        #expect(index.isSourceEnabled(.files) == true)
        let initialResult = await index.query(text: "Apollo")
        #expect(initialResult.hits.count == 1)
        #expect(initialResult.hits.first?.source == .files)
        #expect(initialResult.toggledOffSources.isEmpty)

        // When toggled OFF, query excludes all hits and cites the source
        index.setSourceEnabled(.files, enabled: false)
        #expect(index.isSourceEnabled(.files) == false)
        let disabledResult = await index.query(text: "Apollo")
        #expect(disabledResult.hits.isEmpty)
        #expect(disabledResult.toggledOffSources.contains(.files))
    }

    // MARK: - 2. Denied source degrades gracefully with a reason

    @Test("A denied source degrades gracefully with an explicit reason without crashing or silently emptying")
    func testDeniedSourceDegradesGracefullyWithReason() async throws {
        let toggleStore = PersonalContextToggleStore(inMemory: true)
        let deniedCalendar = CalendarContextAdapter(simulatedStatus: .denied(reason: "Calendar access was denied in System Settings."))
        let deniedPhotos = PhotosContextAdapter(simulatedStatus: .denied(reason: "Photos library access was restricted by administrator."))

        let index = PersonalContextIndex(
            toggleStore: toggleStore,
            adapters: [
                .calendar: deniedCalendar,
                .photos: deniedPhotos
            ]
        )

        let result = await index.query(text: "Meeting")

        // Must not crash, must report explicit reasons, and must not silently drop the error
        #expect(result.hits.isEmpty)
        #expect(result.unavailableSources[.calendar] == "Calendar access was denied in System Settings.")
        #expect(result.unavailableSources[.photos] == "Photos library access was restricted by administrator.")
        #expect(result.sourceStatuses[.calendar] == .denied(reason: "Calendar access was denied in System Settings."))
        #expect(result.sourceStatuses[.photos] == .denied(reason: "Photos library access was restricted by administrator."))
    }

    // MARK: - 3. Mail adapter reports unavailable without private-API use

    @Test("Mail adapter reports unavailable with clear reason and never fabricates messages")
    func testMailAdapterReportsUnavailableWithoutPrivateAPI() async {
        let mailAdapter = MailContextAdapter()
        let status = await mailAdapter.checkStatus()

        #expect(!status.isAvailable)
        #expect(status.reason?.contains("Apple Mail does not provide a public read API on macOS") == true)
        #expect(status.reason?.contains("privacy") == true)

        let searchHits = await mailAdapter.search(query: "important invoice", limit: 10)
        #expect(searchHits.isEmpty, "Mail adapter must never fabricate messages or read private stores")

        // Query through index also reports unavailable and zero hits
        let toggleStore = PersonalContextToggleStore(inMemory: true)
        let index = PersonalContextIndex(
            toggleStore: toggleStore,
            adapters: [.mail: mailAdapter]
        )
        let result = await index.query(text: "invoice")
        #expect(result.hits.isEmpty)
        #expect(result.unavailableSources[.mail]?.contains("Apple Mail does not provide a public read API on macOS") == true)
    }

    // MARK: - 4. Query results cite their source

    @Test("Query results strictly cite their source across multi-source queries")
    func testQueryResultsCiteSource() async throws {
        let tempDir = try createTempWorkspace(prefix: "test-cite-source")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // File fixture
        let fileURL = tempDir.appendingPathComponent("SprintGoals.txt")
        try "Sprint 42 Goals: Ship Personal Context Indexing".write(to: fileURL, atomically: true, encoding: .utf8)

        // Contact fixture
        let contact = CNMutableContact()
        contact.givenName = "Sarah"
        contact.familyName = "Connor"
        contact.organizationName = "Cyberdyne Systems"
        contact.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: "sarah@cyberdyne.example" as NSString)]

        // Calendar fixture
        let eventStore = EKEventStore()
        let event = EKEvent(eventStore: eventStore)
        event.title = "Sprint Planning Sync"
        event.notes = "Sprint 42 roadmap discussion"
        event.startDate = Date()

        let toggleStore = PersonalContextToggleStore(inMemory: true)
        let index = PersonalContextIndex(
            toggleStore: toggleStore,
            adapters: [
                .files: FilesContextAdapter(searchRoot: tempDir),
                .contacts: ContactsContextAdapter(syntheticContacts: [contact]),
                .calendar: CalendarContextAdapter(syntheticEvents: [event])
            ]
        )

        let sprintResult = await index.query(text: "Sprint")
        #expect(sprintResult.hits.count >= 2)

        let fileHits = sprintResult.hits.filter { $0.source == .files }
        let calendarHits = sprintResult.hits.filter { $0.source == .calendar }

        #expect(!fileHits.isEmpty)
        #expect(fileHits.allSatisfy { $0.source == .files && $0.title == "SprintGoals.txt" })

        #expect(!calendarHits.isEmpty)
        #expect(calendarHits.allSatisfy { $0.source == .calendar && $0.title == "Sprint Planning Sync" })

        let contactResult = await index.query(text: "Sarah")
        #expect(contactResult.hits.count == 1)
        #expect(contactResult.hits.first?.source == .contacts)
        #expect(contactResult.hits.first?.title.contains("Sarah") == true)
    }

    // MARK: - 5. The index never writes to a source (read-only invariant & live verifier)

    @Test("Index never writes to, modifies, moves, or deletes source data (read-only invariant)")
    func testIndexNeverModifiesSourceData() async throws {
        let tempDir = try createTempWorkspace(prefix: "test-read-only")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("ReadMe.txt")
        let content = "Immutable reference document content for testing read-only safety."
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let initialHash = computeFileHash(url: fileURL)
        let initialAttrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let initialModDate = initialAttrs[.modificationDate] as? Date
        let initialSize = initialAttrs[.size] as? Int64

        let toggleStore = PersonalContextToggleStore(inMemory: true)
        let filesAdapter = FilesContextAdapter(searchRoot: tempDir)
        let index = PersonalContextIndex(
            toggleStore: toggleStore,
            adapters: [.files: filesAdapter]
        )

        // Perform multiple queries
        _ = await index.query(text: "Immutable")
        _ = await index.query(text: "reference")
        _ = await index.query(text: "document")
        _ = await index.query(text: "safety")

        // Verify the file was completely unmodified
        let finalHash = computeFileHash(url: fileURL)
        let finalAttrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let finalModDate = finalAttrs[.modificationDate] as? Date
        let finalSize = finalAttrs[.size] as? Int64

        #expect(initialHash == finalHash, "File hash must be identical after indexing queries")
        #expect(initialModDate == finalModDate, "Modification date must not change during read-only indexing")
        #expect(initialSize == finalSize, "File size must not change during read-only indexing")

        // Execute live verifier against runtime with synthetic fixtures
        let verifierResult = await PersonalContextIndexLiveVerifier.runVerification(writeLogTo: "runs/issue85/live-verify.log")
        #expect(verifierResult.passed, "Live verifier must pass all 5 verdicts")
    }
}
