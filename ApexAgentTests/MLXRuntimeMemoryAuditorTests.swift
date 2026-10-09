import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Batch 83 — Local MLX & On-Device Language Model Memory Pressure Gate Tests")
struct MLXRuntimeMemoryAuditorTests {

    @Test("Valid local MLX inference configuration passes audit with 100% score")
    func validInferenceConfigPasses() {
        let hostURL = URL(string: "http://127.0.0.1:8080")!
        let report = MLXRuntimeMemoryAuditor.auditInferenceConfig(
            hostURL: hostURL,
            contextLength: 4096,
            maxTokens: 1024,
            temperature: 0.7,
            topP: 0.95
        )

        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.parametersValid)
        #expect(report.hostSecure)
        #expect(report.violations.isEmpty)
    }

    @Test("KV-cache calculation accurately matches transformer layer parameters")
    func kvCacheCalculationAccurate() {
        // 32 layers, 8 kv_heads, 128 head_dim, 2048 context, 2 bytes precision:
        // 2 * 32 * 8 * 128 * 2048 * 2 = 268,435,456 bytes = 256.0 MB
        let mb = MLXRuntimeMemoryAuditor.estimateKVCacheMemoryMB(
            layers: 32,
            kvHeads: 8,
            headDim: 128,
            contextLength: 2048,
            precisionBytes: 2
        )
        #expect(mb == 256.0)
    }

    @Test("Non-loopback host endpoint triggers NON_LOOPBACK_ENDPOINT violation")
    func nonLoopbackEndpointFails() {
        let remoteURL = URL(string: "http://192.168.1.100:8080")!
        let report = MLXRuntimeMemoryAuditor.auditInferenceConfig(
            hostURL: remoteURL,
            contextLength: 2048,
            maxTokens: 512,
            temperature: 0.5,
            topP: 0.9
        )

        #expect(!report.passed)
        #expect(!report.hostSecure)
        #expect(report.violations.contains { $0.code == "NON_LOOPBACK_ENDPOINT" })
    }

    @Test("Invalid sampling parameters trigger parameter violation")
    func invalidSamplingParametersFail() {
        let hostURL = URL(string: "http://localhost:8080")!
        let report = MLXRuntimeMemoryAuditor.auditInferenceConfig(
            hostURL: hostURL,
            contextLength: 2048,
            maxTokens: 5000, // Exceeds default maxNewTokens 4096
            temperature: -0.5, // Negative temperature!
            topP: 1.5 // Out of bounds > 1.0!
        )

        #expect(!report.passed)
        #expect(!report.parametersValid)
        #expect(report.violations.contains { $0.code == "INVALID_TEMPERATURE" })
        #expect(report.violations.contains { $0.code == "INVALID_TOP_P" })
        #expect(report.violations.contains { $0.code == "INVALID_MAX_TOKENS" })
    }

    @Test("Excessive context length triggers CONTEXT_LENGTH_EXCEEDED violation")
    func excessiveContextLengthFails() {
        let hostURL = URL(string: "http://localhost:8080")!
        let report = MLXRuntimeMemoryAuditor.auditInferenceConfig(
            hostURL: hostURL,
            contextLength: 65536, // Exceeds default 32768
            maxTokens: 512,
            temperature: 0.7,
            topP: 0.9
        )

        #expect(!report.passed)
        #expect(report.violations.contains { $0.code == "CONTEXT_LENGTH_EXCEEDED" })
    }
}
