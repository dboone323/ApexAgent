import Testing
import Foundation
@testable import ApexAgentCore

// MARK: - O2: SecretRedactor

@Suite("SecretRedactorTests")
struct SecretRedactorTests {

    @Test func redactsProviderApiKeysAndGithubTokens() {
        let out = SecretRedactor.redact(text: "key=sk-ant-api03-abcdefghijklmnopqrstuvwxyz and ghp_1234567890ABCDEFGHIJ")
        #expect(!out.contains("sk-ant-api03"))
        #expect(!out.contains("ghp_1234567890"))
        #expect(out.contains("«redacted"))
    }

    @Test func redactsBearerTokens() {
        let out = SecretRedactor.redact(text: "Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345")
        #expect(!out.contains("abcdefghijklmnopqrstuvwxyz012345"))
        #expect(out.contains("Bearer"))
    }

    @Test func redactsKeyValueLines() {
        let out = SecretRedactor.redact(text: "export MY_API_KEY=supersecretvalue123")
        #expect(!out.contains("supersecretvalue123"))
        #expect(out.contains("MY_API_KEY=«redacted"))
    }

    @Test func redactsPEMBlocks() {
        let key = "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFA\n-----END PRIVATE KEY-----"
        let out = SecretRedactor.redact(text: key)
        #expect(!out.contains("MIIEvQIBADANBgkqhkiG9w0BAQEFA"))
        #expect(out.contains("BEGIN PRIVATE KEY"))
    }

    @Test func redactEnvironmentMasksSecretKeysOnly() {
        let env = [
            "ANTHROPIC_API_KEY": "sk-ant-abcdefghijklmnopqrstuvwxyz",
            "HOME": "/Users/me",
        ]
        let out = SecretRedactor.redactEnvironment(env)
        #expect(out["ANTHROPIC_API_KEY"]?.contains("sk-ant") == false)
        #expect(out["HOME"] == "/Users/me")
    }

    @Test func isSecretNameMatchesSuffixKeys() {
        #expect(SecretRedactor.isSecretName("api_key"))
        #expect(SecretRedactor.isSecretName("consumer-key"))
        #expect(SecretRedactor.isSecretName("xai_key"))
        #expect(!SecretRedactor.isSecretName("keyboard"))
        #expect(!SecretRedactor.isSecretName("hotkeys"))
    }
}
