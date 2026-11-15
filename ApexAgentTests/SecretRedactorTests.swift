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

    @Test func redactsURIPasswords() {
        let uri = "Connecting to postgresql://postgres:mysecretpassword123@db.example.com:5432/mydb"
        let out = SecretRedactor.redact(text: uri)
        #expect(!out.contains("mysecretpassword123"))
        #expect(out.contains("postgresql://postgres:«redacted»@db.example.com:5432/mydb"))
    }

    @Test func redactsFakeTestKeysAndDiscordWebhookUrls() {
        let text = "Test OpenAI key: sk-test-fake-1234 and Discord webhook: https://discord.com/api/webhooks/123456789/fake-webhook-token-secret-9999"
        let out = SecretRedactor.redact(text: text)
        #expect(!out.contains("sk-test-fake-1234"))
        #expect(!out.contains("fake-webhook-token-secret-9999"))
        #expect(out.contains("https://discord.com/api/webhooks/123456789/«redacted»"))
    }

    @Test func redactsTavilyAndBraveSearchKeys() {
        let text = "Tavily: tvly-fake-secret-tavily-key-12345 and Brave: BSA1234567890abcdefghijklmnopqrstuvwxyz"
        let out = SecretRedactor.redact(text: text)
        #expect(!out.contains("tvly-fake-secret-tavily-key-12345"))
        #expect(!out.contains("BSA1234567890abcdefghijklmnopqrstuvwxyz"))
        #expect(out.contains("«redacted»"))
    }

    @Test func containsSecretDetectsCredentialShapes() {
        #expect(SecretRedactor.containsSecret("export KEY=sk-test-fake-1234"))
        #expect(SecretRedactor.containsSecret("https://discord.com/api/webhooks/1234/token-secret-12345"))
        #expect(!SecretRedactor.containsSecret("This is normal documentation text without secrets."))
    }
}
