import Foundation

// MARK: - Local MLX & On-Device Language Model Memory Pressure Gate (Batch 83)

/// Policy configuration for local MLX model execution.
public struct MLXMemoryPolicy: Sendable, Codable, Equatable {
    /// Maximum context tokens permitted before sliding window truncation.
    public var maxContextTokens: Int
    /// Maximum new output tokens per generation request.
    public var maxNewTokens: Int
    /// Maximum allowable estimated KV-cache memory in megabytes.
    public var maxKVCacheMemoryMB: Double
    /// Enforce strictly localhost/loopback endpoints for security.
    public var enforceLocalhostOnly: Bool

    public init(
        maxContextTokens: Int = 32_768,
        maxNewTokens: Int = 4_096,
        maxKVCacheMemoryMB: Double = 2_048.0, // 2 GB
        enforceLocalhostOnly: Bool = true
    ) {
        self.maxContextTokens = maxContextTokens
        self.maxNewTokens = maxNewTokens
        self.maxKVCacheMemoryMB = maxKVCacheMemoryMB
        self.enforceLocalhostOnly = enforceLocalhostOnly
    }
}

/// Violation detected during MLX runtime or memory audit.
public struct MLXAuditViolation: Sendable, Codable, Equatable {
    public let code: String
    public let message: String
    public let isFatal: Bool

    public init(code: String, message: String, isFatal: Bool = true) {
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

/// Report produced by MLX runtime memory and parameter auditing.
public struct MLXConfigAuditReport: Sendable, Codable, Equatable {
    public let passed: Bool
    public let score: Double
    public let estimatedKVCacheMB: Double
    public let parametersValid: Bool
    public let hostSecure: Bool
    public let violations: [MLXAuditViolation]

    public init(
        passed: Bool,
        score: Double,
        estimatedKVCacheMB: Double,
        parametersValid: Bool,
        hostSecure: Bool,
        violations: [MLXAuditViolation]
    ) {
        self.passed = passed
        self.score = score
        self.estimatedKVCacheMB = estimatedKVCacheMB
        self.parametersValid = parametersValid
        self.hostSecure = hostSecure
        self.violations = violations
    }
}

/// Auditor for on-device MLX model memory constraints, KV-cache sizing, and sampling parameters.
public enum MLXRuntimeMemoryAuditor {

    // MARK: - KV-Cache Memory Calculation

    /// Estimates KV-cache allocation in MB for transformer architecture:
    /// 2 (K & V) * layers * kv_heads * head_dim * context_length * precisionBytes
    public static func estimateKVCacheMemoryMB(
        layers: Int = 32,
        kvHeads: Int = 8,
        headDim: Int = 128,
        contextLength: Int,
        precisionBytes: Int = 2 // float16 / bfloat16 = 2 bytes
    ) -> Double {
        let totalBytes = 2 * layers * kvHeads * headDim * contextLength * precisionBytes
        return Double(totalBytes) / (1024.0 * 1024.0)
    }

    // MARK: - Host Endpoint Security

    /// Validates that an MLX host URL is bound to a loopback address.
    public static func isLoopbackEndpoint(url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    // MARK: - Config & Sampling Audit

    /// Audits generation parameters, context length, KV-cache footprint, and endpoint security.
    public static func auditInferenceConfig(
        hostURL: URL,
        contextLength: Int,
        maxTokens: Int,
        temperature: Double,
        topP: Double,
        policy: MLXMemoryPolicy = MLXMemoryPolicy()
    ) -> MLXConfigAuditReport {
        var violations: [MLXAuditViolation] = []
        var paramsValid = true

        // 1. Host URL Check
        let isLocal = isLoopbackEndpoint(url: hostURL)
        if policy.enforceLocalhostOnly && !isLocal {
            violations.append(MLXAuditViolation(
                code: "NON_LOOPBACK_ENDPOINT",
                message: "MLX host '\(hostURL.absoluteString)' is not bound to a loopback address (127.0.0.1/localhost)."
            ))
        }

        // 2. Sampling parameters check
        if temperature < 0.0 || temperature > 2.0 || temperature.isNaN {
            paramsValid = false
            violations.append(MLXAuditViolation(
                code: "INVALID_TEMPERATURE",
                message: "Temperature \(temperature) is out of bounds [0.0, 2.0]."
            ))
        }
        if topP <= 0.0 || topP > 1.0 || topP.isNaN {
            paramsValid = false
            violations.append(MLXAuditViolation(
                code: "INVALID_TOP_P",
                message: "Top-P \(topP) is out of bounds (0.0, 1.0]."
            ))
        }
        if maxTokens <= 0 || maxTokens > policy.maxNewTokens {
            paramsValid = false
            violations.append(MLXAuditViolation(
                code: "INVALID_MAX_TOKENS",
                message: "Requested max_tokens \(maxTokens) exceeds policy maximum of \(policy.maxNewTokens)."
            ))
        }

        // 3. Context Length and KV-Cache Memory Check
        if contextLength > policy.maxContextTokens {
            violations.append(MLXAuditViolation(
                code: "CONTEXT_LENGTH_EXCEEDED",
                message: "Context length \(contextLength) exceeds policy limit of \(policy.maxContextTokens) tokens."
            ))
        }

        let kvCacheMB = estimateKVCacheMemoryMB(contextLength: contextLength)
        if kvCacheMB > policy.maxKVCacheMemoryMB {
            violations.append(MLXAuditViolation(
                code: "KV_CACHE_BUDGET_EXCEEDED",
                message: "Estimated KV-cache memory of \(String(format: "%.1f", kvCacheMB)) MB exceeds budget of \(policy.maxKVCacheMemoryMB) MB."
            ))
        }

        let fatalViolations = violations.filter(\.isFatal)
        let passed = fatalViolations.isEmpty
        let score = passed ? (violations.isEmpty ? 100.0 : 85.0) : max(0.0, 100.0 - Double(fatalViolations.count) * 25.0)

        return MLXConfigAuditReport(
            passed: passed,
            score: score,
            estimatedKVCacheMB: kvCacheMB,
            parametersValid: paramsValid,
            hostSecure: isLocal,
            violations: violations
        )
    }
}
