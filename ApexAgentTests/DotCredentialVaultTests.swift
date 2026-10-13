// DotCredentialVaultTests.swift
// Batch 126: Functional tests for DotCredentialVault Keychain integration and audit logging.

import XCTest
@testable import ApexAgentCore

final class DotCredentialVaultTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        await DotCredentialVault.shared.resetAll()
    }

    override func tearDown() async throws {
        await DotCredentialVault.shared.resetAll()
        try await super.tearDown()
    }

    // MARK: - 1. Custom Secret Tests

    func testStoreAndRetrieveCustomSecret() async throws {
        let vault = DotCredentialVault()
        let key = "dot.custom.test.\(UUID().uuidString)"
        let secret = "secret_custom_val_\(UUID().uuidString)"
        let dotId = UUID()

        try await vault.storeSecret(
            key: key,
            value: secret,
            dotId: dotId,
            type: .customDotSecret,
            description: "Test custom secret"
        )

        let retrieved = try await vault.retrieveSecret(key: key)
        XCTAssertEqual(retrieved, secret)

        let metadata = await vault.getMetadata(key: key)
        XCTAssertNotNil(metadata)
        XCTAssertEqual(metadata?.key, key)
        XCTAssertEqual(metadata?.dotId, dotId)
        XCTAssertEqual(metadata?.credentialType, .customDotSecret)
        XCTAssertEqual(metadata?.description, "Test custom secret")

        try await vault.deleteSecret(key: key)
    }

    // MARK: - 2. Provider Key Tests (GitHub Copilot)

    func testStoreAndRetrieveProviderKeyForCopilot() async throws {
        let vault = DotCredentialVault()
        let token = "ghu_copilot_test_token_\(UUID().uuidString)"

        try await vault.storeProviderKey(provider: .gitHubCopilotToken, secret: token)
        let retrieved = try await vault.retrieveProviderKey(provider: .gitHubCopilotToken)
        XCTAssertEqual(retrieved, token)

        let retrievedDirect = try await vault.retrieveSecret(key: DotCredentialType.gitHubCopilotToken.rawValue)
        XCTAssertEqual(retrievedDirect, token)

        let hasKey = await vault.hasProviderKey(provider: .gitHubCopilotToken)
        XCTAssertTrue(hasKey)

        try await vault.deleteProviderKey(provider: .gitHubCopilotToken)
        let hasKeyAfterDelete = await vault.hasProviderKey(provider: .gitHubCopilotToken)
        XCTAssertFalse(hasKeyAfterDelete)
    }

    // MARK: - 3. Provider Key Tests (Google Gemini)

    func testStoreAndRetrieveProviderKeyForGemini() async throws {
        let vault = DotCredentialVault()
        let apiKey = "AIzaSyTestGeminiKey_\(UUID().uuidString)"

        try await vault.storeProviderKey(provider: .geminiApiKey, secret: apiKey)
        let retrieved = try await vault.retrieveProviderKey(provider: .geminiApiKey)
        XCTAssertEqual(retrieved, apiKey)

        let retrievedDirect = try await vault.retrieveSecret(key: DotCredentialType.geminiApiKey.rawValue)
        XCTAssertEqual(retrievedDirect, apiKey)

        try await vault.deleteProviderKey(provider: .geminiApiKey)
        let retrievedAfterDelete = try await vault.retrieveProviderKey(provider: .geminiApiKey)
        XCTAssertNil(retrievedAfterDelete)
    }

    // MARK: - 4. Overwrite Existing Secret

    func testOverwriteExistingSecretUpdatesValue() async throws {
        let vault = DotCredentialVault()
        let key = "overwrite.key.\(UUID().uuidString)"
        let initialValue = "val_initial_123"
        let updatedValue = "val_updated_456"

        try await vault.storeSecret(key: key, value: initialValue, description: "Initial description")
        let retrievedInitial = try await vault.retrieveSecret(key: key)
        XCTAssertEqual(retrievedInitial, initialValue)

        try await vault.storeSecret(key: key, value: updatedValue, description: "Updated description")
        let retrievedUpdated = try await vault.retrieveSecret(key: key)
        XCTAssertEqual(retrievedUpdated, updatedValue)

        let meta = await vault.getMetadata(key: key)
        XCTAssertEqual(meta?.description, "Updated description")

        try await vault.deleteSecret(key: key)
    }

    // MARK: - 5. Delete Secret

    func testDeleteSecretRemovesValue() async throws {
        let vault = DotCredentialVault()
        let key = "delete.key.\(UUID().uuidString)"
        let value = "val_to_delete"

        try await vault.storeSecret(key: key, value: value)
        let hasBefore = await vault.hasSecret(key: key)
        XCTAssertTrue(hasBefore)

        try await vault.deleteSecret(key: key)
        let retrieved = try await vault.retrieveSecret(key: key)
        XCTAssertNil(retrieved)
        let hasAfter = await vault.hasSecret(key: key)
        XCTAssertFalse(hasAfter)
        let metaAfter = await vault.getMetadata(key: key)
        XCTAssertNil(metaAfter)
    }

    // MARK: - 6. Has Secret Check

    func testHasSecretReturnsTrueWhenPresentAndFalseWhenMissing() async throws {
        let vault = DotCredentialVault()
        let key = "presence.key.\(UUID().uuidString)"

        let hasBefore = await vault.hasSecret(key: key)
        XCTAssertFalse(hasBefore)

        try await vault.storeSecret(key: key, value: "something_present")
        let hasStored = await vault.hasSecret(key: key)
        XCTAssertTrue(hasStored)

        try await vault.deleteSecret(key: key)
        let hasDeleted = await vault.hasSecret(key: key)
        XCTAssertFalse(hasDeleted)
    }

    // MARK: - 7. Audit Log Records Write, Read, Delete Events

    func testAuditLogRecordsWriteReadDeleteEvents() async throws {
        let vault = DotCredentialVault()
        await vault.clearAuditLog()
        let key = "audit.key.\(UUID().uuidString)"
        let value = "audit_secret_value"

        try await vault.storeSecret(key: key, value: value)
        _ = try await vault.retrieveSecret(key: key)
        try await vault.deleteSecret(key: key)

        let logs = await vault.getAuditLog()
        let keyLogs = logs.filter { $0.key == key }
        XCTAssertEqual(keyLogs.count, 3)

        XCTAssertEqual(keyLogs[0].action, "write")
        XCTAssertTrue(keyLogs[0].success)

        XCTAssertEqual(keyLogs[1].action, "read")
        XCTAssertTrue(keyLogs[1].success)

        XCTAssertEqual(keyLogs[2].action, "delete")
        XCTAssertTrue(keyLogs[2].success)
    }

    // MARK: - 8. Clear Audit Log

    func testAuditLogClearWorks() async throws {
        let vault = DotCredentialVault()
        let key = "clear.audit.key.\(UUID().uuidString)"
        try await vault.storeSecret(key: key, value: "temp_value")

        let beforeClear = await vault.getAuditLog()
        XCTAssertFalse(beforeClear.isEmpty)

        await vault.clearAuditLog()
        let afterClear = await vault.getAuditLog()
        XCTAssertTrue(afterClear.isEmpty)

        try await vault.deleteSecret(key: key)
    }

    // MARK: - 9. Missing Secret Retrieval Logs Miss

    func testRetrieveMissingSecretReturnsNilAndLogsMiss() async throws {
        let vault = DotCredentialVault()
        let nonExistentKey = "nonexistent.key.\(UUID().uuidString)"
        await vault.clearAuditLog()

        let result = try await vault.retrieveSecret(key: nonExistentKey)
        XCTAssertNil(result)

        let logs = await vault.getAuditLog()
        let missLog = logs.first(where: { $0.key == nonExistentKey && $0.action == "read" })
        XCTAssertNotNil(missLog)
        XCTAssertFalse(missLog?.success ?? true)
    }

    // MARK: - 10. Enum Cases & Metadata Codability

    func testMetadataTypeEnumCasesAreValid() throws {
        let expectedCases: [DotCredentialType: String] = [
            .gitHubCopilotToken: "github.copilot.token",
            .geminiApiKey: "google.gemini.apikey",
            .anthropicApiKey: "anthropic.apikey",
            .openAIApiKey: "openai.apikey",
            .customDotSecret: "dot.custom.secret"
        ]

        XCTAssertEqual(DotCredentialType.allCases.count, expectedCases.count)
        for (type, rawValue) in expectedCases {
            XCTAssertEqual(type.rawValue, rawValue)
            XCTAssertEqual(DotCredentialType(rawValue: rawValue), type)
        }

        // Test metadata serialization
        let metadata = DotCredentialMetadata(
            key: "test.key",
            dotId: UUID(),
            credentialType: .anthropicApiKey,
            description: "Anthropic API Key"
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(metadata)
        let decoded = try decoder.decode(DotCredentialMetadata.self, from: data)
        XCTAssertEqual(decoded, metadata)
    }

    // MARK: - 11. Extra Functional Validations

    func testEmptyKeyThrowsError() async {
        let vault = DotCredentialVault()
        do {
            try await vault.storeSecret(key: "", value: "foo")
            XCTFail("Expected empty key error")
        } catch let error as DotCredentialVaultError {
            XCTAssertEqual(error, .emptyKey)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        do {
            _ = try await vault.retrieveSecret(key: "   ")
            XCTFail("Expected empty key error on retrieve")
        } catch let error as DotCredentialVaultError {
            XCTAssertEqual(error, .emptyKey)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        do {
            try await vault.deleteSecret(key: "")
            XCTFail("Expected empty key error on delete")
        } catch let error as DotCredentialVaultError {
            XCTAssertEqual(error, .emptyKey)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testFingerprintIsDeterministicSHA256() {
        let secret = "sk-ant-api03-abcdef123456"
        let fp1 = DotCredentialVault.fingerprint(secret: secret)
        let fp2 = DotCredentialVault.fingerprint(secret: secret)
        XCTAssertEqual(fp1, fp2)
        XCTAssertEqual(fp1.count, 64) // SHA-256 hex string length
    }

    func testSharedVaultInstance() async throws {
        let key = "shared.vault.test.\(UUID().uuidString)"
        let secret = "shared_secret_\(UUID().uuidString)"

        try await DotCredentialVault.shared.storeSecret(key: key, value: secret)
        let retrieved = try await DotCredentialVault.shared.retrieveSecret(key: key)
        XCTAssertEqual(retrieved, secret)

        try await DotCredentialVault.shared.deleteSecret(key: key)
        let afterDelete = try await DotCredentialVault.shared.retrieveSecret(key: key)
        XCTAssertNil(afterDelete)
    }
}
