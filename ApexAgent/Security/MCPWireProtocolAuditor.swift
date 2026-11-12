import Foundation

// MARK: - MCPKit Wire Protocol JSON-RPC & Backpressure Gate (Batch 81)

/// Configuration policy for MCP wire protocol auditing.
public struct MCPWireProtocolConfig: Sendable, Codable, Equatable {
    /// Maximum allowed single frame size in bytes (e.g. 10 MB).
    public var maxFrameSizeBytes: Int
    /// Maximum allowed in-flight requests per server connection.
    public var maxInFlightRequests: Int
    /// Enforce strictly JSON-RPC 2.0 envelope ("jsonrpc": "2.0").
    public var enforceJSONRPCVersion: Bool
    /// Allowed MCP core methods.
    public var allowedMethods: Set<String>
    /// Explicitly reject deprecated MCP 2026-07-28 features (roots, sampling, logging).
    public var rejectDeprecatedMethods: Bool

    /// Deprecated protocol methods per MCP 2026-07-28 specification.
    public static let deprecatedMethods: Set<String> = [
        "roots/list",
        "sampling/createMessage",
        "logging/setLevel"
    ]

    public init(
        maxFrameSizeBytes: Int = 10_485_760, // 10 MB
        maxInFlightRequests: Int = 16,
        enforceJSONRPCVersion: Bool = true,
        allowedMethods: Set<String> = [
            "initialize", "notifications/initialized", "ping",
            "tools/list", "tools/call",
            "resources/list", "resources/read", "resources/subscribe", "resources/unsubscribe",
            "prompts/list", "prompts/get",
            "completion/complete",
            "tasks/list", "tasks/get", "tasks/call", "tasks/cancel", "tasks/result",
            "server/card",
            "apps/list", "apps/get"
        ],
        rejectDeprecatedMethods: Bool = true
    ) {
        self.maxFrameSizeBytes = maxFrameSizeBytes
        self.maxInFlightRequests = maxInFlightRequests
        self.enforceJSONRPCVersion = enforceJSONRPCVersion
        self.allowedMethods = allowedMethods
        self.rejectDeprecatedMethods = rejectDeprecatedMethods
    }
}

/// Violation detected in an MCP wire protocol message.
public struct MCPWireViolation: Sendable, Codable, Equatable {
    public let code: String
    public let message: String
    public let isFatal: Bool

    public init(code: String, message: String, isFatal: Bool = true) {
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

/// Category of parsed JSON-RPC message.
public enum MCPWireMessageKind: String, Sendable, Codable, Equatable {
    case request
    case notification
    case responseSuccess
    case responseError
    case unknown
}

/// Complete report of MCP wire protocol audit.
public struct MCPWireProtocolAuditReport: Sendable, Codable, Equatable {
    public let passed: Bool
    public let score: Double
    public let messageKind: MCPWireMessageKind
    public let jsonrpcValid: Bool
    public let methodAllowed: Bool
    public let frameSizeBytes: Int
    public let violations: [MCPWireViolation]

    public init(
        passed: Bool,
        score: Double,
        messageKind: MCPWireMessageKind,
        jsonrpcValid: Bool,
        methodAllowed: Bool,
        frameSizeBytes: Int,
        violations: [MCPWireViolation]
    ) {
        self.passed = passed
        self.score = score
        self.messageKind = messageKind
        self.jsonrpcValid = jsonrpcValid
        self.methodAllowed = methodAllowed
        self.frameSizeBytes = frameSizeBytes
        self.violations = violations
    }
}

/// Auditor for MCP stdio / SSE wire protocol, JSON-RPC 2.0 framing, and backpressure.
public enum MCPWireProtocolAuditor {

    // MARK: - Chunk Defragmentation

    /// Assembles streaming byte chunks into complete messages split by delimiter (default: `\n` = 0x0A).
    public static func defragmentChunks(
        chunks: [Data],
        delimiter: UInt8 = 0x0A
    ) -> [Data] {
        var completeFrames: [Data] = []
        var accumulator = Data()

        for chunk in chunks {
            accumulator.append(chunk)

            while let delimiterIndex = accumulator.firstIndex(of: delimiter) {
                let frame = accumulator.subdata(in: accumulator.startIndex..<delimiterIndex)
                if !frame.isEmpty {
                    completeFrames.append(frame)
                }
                accumulator.removeSubrange(accumulator.startIndex...delimiterIndex)
            }
        }

        if !accumulator.isEmpty {
            completeFrames.append(accumulator)
        }

        return completeFrames
    }

    // MARK: - Frame Audit

    /// Audits a raw MCP message frame for JSON-RPC 2.0 compliance, method allowlist, and size bounds.
    public static func auditRawFrame(
        _ data: Data,
        config: MCPWireProtocolConfig = MCPWireProtocolConfig()
    ) -> MCPWireProtocolAuditReport {
        var violations: [MCPWireViolation] = []
        let frameSize = data.count

        // 1. Frame size check
        if frameSize > config.maxFrameSizeBytes {
            violations.append(MCPWireViolation(
                code: "FRAME_SIZE_EXCEEDED",
                message: "Frame size of \(frameSize) bytes exceeds limit of \(config.maxFrameSizeBytes) bytes."
            ))
        }

        guard let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            violations.append(MCPWireViolation(
                code: "JSON_PARSE_ERROR",
                message: "Payload is not valid JSON."
            ))
            return MCPWireProtocolAuditReport(
                passed: false,
                score: 0.0,
                messageKind: .unknown,
                jsonrpcValid: false,
                methodAllowed: false,
                frameSizeBytes: frameSize,
                violations: violations
            )
        }

        // 2. JSON-RPC version check
        let version = jsonObject["jsonrpc"] as? String
        let jsonrpcValid = version == "2.0"
        if config.enforceJSONRPCVersion && !jsonrpcValid {
            violations.append(MCPWireViolation(
                code: "INVALID_JSONRPC_VERSION",
                message: "Missing or invalid 'jsonrpc' field; expected '2.0', got '\(version ?? "nil")'."
            ))
        }

        // 3. Message kind classification & method check
        var kind: MCPWireMessageKind = .unknown
        var methodAllowed = true

        let hasId = jsonObject["id"] != nil
        let method = jsonObject["method"] as? String
        let hasResult = jsonObject["result"] != nil
        let hasError = jsonObject["error"] != nil

        if let m = method {
            if hasId {
                kind = .request
            } else {
                kind = .notification
            }

            if config.rejectDeprecatedMethods && MCPWireProtocolConfig.deprecatedMethods.contains(m) {
                methodAllowed = false
                violations.append(MCPWireViolation(
                    code: "DEPRECATED_PROTOCOL_FEATURE",
                    message: "MCP method '\(m)' is deprecated in MCP 2026-07-28 and prohibited."
                ))
            } else if !config.allowedMethods.contains(m) && !m.hasPrefix("custom/") {
                methodAllowed = false
                violations.append(MCPWireViolation(
                    code: "METHOD_NOT_PERMITTED",
                    message: "MCP method '\(m)' is not in the allowed method set."
                ))
            }
        } else if hasResult && !hasError {
            kind = .responseSuccess
        } else if hasError && !hasResult {
            kind = .responseError
        } else if hasResult && hasError {
            violations.append(MCPWireViolation(
                code: "INVALID_RESPONSE_MUTUAL_EXCLUSION",
                message: "JSON-RPC response contains both 'result' and 'error' simultaneously."
            ))
        } else {
            violations.append(MCPWireViolation(
                code: "INVALID_JSONRPC_STRUCTURE",
                message: "Payload lacks both 'method' and response fields ('result'/'error')."
            ))
        }

        let fatalViolations = violations.filter(\.isFatal)
        let passed = fatalViolations.isEmpty
        let score = passed ? (violations.isEmpty ? 100.0 : 85.0) : max(0.0, 100.0 - Double(fatalViolations.count) * 30.0)

        return MCPWireProtocolAuditReport(
            passed: passed,
            score: score,
            messageKind: kind,
            jsonrpcValid: jsonrpcValid,
            methodAllowed: methodAllowed,
            frameSizeBytes: frameSize,
            violations: violations
        )
    }

    // MARK: - Backpressure Audit

    /// Audits in-flight request count to prevent transport congestion and deadlock.
    public static func auditInFlightRequests(
        currentCount: Int,
        config: MCPWireProtocolConfig = MCPWireProtocolConfig()
    ) -> Bool {
        currentCount <= config.maxInFlightRequests
    }
}
