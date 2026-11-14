import Foundation

// MARK: - Phone-Ready Approval Payload (Issue #105, feeds #70 iOS)

/// A compact, mobile-optimized payload representing an action approval request.
/// Designed specifically for low-bandwidth, glanceable approval on phone screens.
///
/// Carries strictly:
/// 1. `ask`: what is being asked (action / prompt)
/// 2. `command`: the exact command being executed
/// 3. `directory`: the target execution directory
/// 4. `riskSummary`: clear, human-readable risk summary
/// 5. `expiresAt`: expiration timestamp after which approval is invalid
public struct PhoneApprovalPayload: Codable, Sendable, Equatable {
    /// What is being asked of the reviewer.
    public let ask: String

    /// The exact command being executed.
    public let command: String

    /// The directory where the command executes.
    public let directory: String

    /// Summary of the potential risk.
    public let riskSummary: String

    /// Expiration timestamp of the request.
    public let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case ask
        case command
        case directory
        case riskSummary = "risk_summary"
        case expiresAt = "expires_at"
    }

    public init(
        ask: String,
        command: String,
        directory: String,
        riskSummary: String,
        expiresAt: Date
    ) {
        self.ask = ask
        self.command = command
        self.directory = directory
        self.riskSummary = riskSummary
        self.expiresAt = expiresAt
    }

    /// Serializes payload to formatted JSON data.
    public func toJSONData(prettyPrinted: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        } else {
            encoder.outputFormatting = [.sortedKeys]
        }
        return try encoder.encode(self)
    }

    /// Serializes payload to compact or pretty JSON string.
    public func toJSONString(prettyPrinted: Bool = false) -> String {
        guard let data = try? toJSONData(prettyPrinted: prettyPrinted),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    /// Decodes a phone approval payload from JSON data.
    public static func fromJSONData(_ data: Data) throws -> PhoneApprovalPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PhoneApprovalPayload.self, from: data)
    }
}
