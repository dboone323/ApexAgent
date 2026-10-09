import Foundation

// MARK: - Companion Camera & Audio Sensor Privacy Consent Gate (Batch 64)

/// Types of hardware sensors available on companion devices.
public enum CompanionSensorType: String, Codable, Sendable, CaseIterable {
    case camera = "camera"
    case microphone = "microphone"
    case location = "location"
}

/// Consent status granted by the user for a specific companion sensor.
public enum SensorConsentStatus: String, Codable, Sendable {
    case notDetermined = "notDetermined"
    case authorized = "authorized"
    case denied = "denied"
    case restricted = "restricted"

    public var isAuthorized: Bool {
        self == .authorized
    }
}

/// Precision mode for location sensor payloads.
public enum LocationPrecisionMode: String, Codable, Sendable {
    case full = "full"
    case coarse = "coarse" // Rounded to ~1km to protect user privacy
}

/// Configuration governing companion sensor privacy policies and quotas.
public struct CompanionSensorPrivacyConfig: Codable, Sendable, Equatable {
    public var consents: [CompanionSensorType: SensorConsentStatus]
    public var maxCameraFPS: Double
    public var maxPhotoSizeBytes: Int
    public var maxAudioChunkSizeBytes: Int
    public var locationPrecision: LocationPrecisionMode
    public var autoTeardownOnDisconnect: Bool

    public init(
        consents: [CompanionSensorType: SensorConsentStatus] = [:],
        maxCameraFPS: Double = 5.0,
        maxPhotoSizeBytes: Int = 2 * 1024 * 1024, // 2MB
        maxAudioChunkSizeBytes: Int = 512 * 1024, // 512KB
        locationPrecision: LocationPrecisionMode = .coarse,
        autoTeardownOnDisconnect: Bool = true
    ) {
        self.consents = consents
        self.maxCameraFPS = maxCameraFPS
        self.maxPhotoSizeBytes = maxPhotoSizeBytes
        self.maxAudioChunkSizeBytes = maxAudioChunkSizeBytes
        self.locationPrecision = locationPrecision
        self.autoTeardownOnDisconnect = autoTeardownOnDisconnect
    }
}

/// Violation detected when evaluating sensor transmissions against privacy policy.
public struct SensorPrivacyViolation: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(sensorType):\(ruleId):\(message)" }
    public let sensorType: CompanionSensorType
    public let ruleId: String
    public let severity: ToolSandboxSeverity
    public let message: String
    public let remediation: String

    public init(
        sensorType: CompanionSensorType,
        ruleId: String,
        severity: ToolSandboxSeverity,
        message: String,
        remediation: String
    ) {
        self.sensorType = sensorType
        self.ruleId = ruleId
        self.severity = severity
        self.message = message
        self.remediation = remediation
    }
}

/// Report produced by auditing companion sensor transmissions.
public struct CompanionSensorAuditReport: Codable, Sendable, Equatable {
    public let passed: Bool
    public let score: Double
    public let evaluatedPayloadsCount: Int
    public let violations: [SensorPrivacyViolation]
    public let recommendations: [String]

    public init(
        passed: Bool,
        score: Double,
        evaluatedPayloadsCount: Int,
        violations: [SensorPrivacyViolation],
        recommendations: [String]
    ) {
        self.passed = passed
        self.score = score
        self.evaluatedPayloadsCount = evaluatedPayloadsCount
        self.violations = violations
        self.recommendations = recommendations
    }

    public func toJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}

/// Autonomous gate ensuring that all companion camera, microphone, and location streams
/// adhere to user consent agreements, quota limits, and privacy redaction standards.
public enum CompanionSensorConsentGate {

    /// Audits a set of sensor payloads against active consent and privacy policies.
    public static func audit(
        payloads: [CompanionSensorPayload],
        config: CompanionSensorPrivacyConfig
    ) -> CompanionSensorAuditReport {
        guard !payloads.isEmpty else {
            return CompanionSensorAuditReport(
                passed: true,
                score: 100.0,
                evaluatedPayloadsCount: 0,
                violations: [],
                recommendations: ["No sensor payloads evaluated."]
            )
        }

        var violations: [SensorPrivacyViolation] = []

        for payload in payloads {
            let sensorType = mapSensorKind(payload.kind)
            let consent = config.consents[sensorType] ?? .notDetermined

            // Consent check
            if !consent.isAuthorized {
                violations.append(
                    SensorPrivacyViolation(
                        sensorType: sensorType,
                        ruleId: "SENS-001",
                        severity: .critical,
                        message: "Payload transmitted from sensor '\(sensorType.rawValue)' without user authorization (status: \(consent.rawValue)).",
                        remediation: "Require explicit user opt-in before streaming sensor data."
                    )
                )
            }

            // Quota / Size checks
            let byteCount = Data(base64Encoded: payload.dataBase64)?.count ?? payload.dataBase64.utf8.count
            switch payload.kind {
            case .cameraPhoto:
                if byteCount > config.maxPhotoSizeBytes {
                    violations.append(
                        SensorPrivacyViolation(
                            sensorType: .camera,
                            ruleId: "SENS-002",
                            severity: .high,
                            message: "Camera photo payload (\(byteCount) bytes) exceeds maximum size of \(config.maxPhotoSizeBytes) bytes.",
                            remediation: "Compress or downsample camera photo frames."
                        )
                    )
                }
            case .voiceAudioChunk:
                if byteCount > config.maxAudioChunkSizeBytes {
                    violations.append(
                        SensorPrivacyViolation(
                            sensorType: .microphone,
                            ruleId: "SENS-003",
                            severity: .high,
                            message: "Audio chunk payload (\(byteCount) bytes) exceeds maximum size of \(config.maxAudioChunkSizeBytes) bytes.",
                            remediation: "Chunk audio buffers into smaller increments."
                        )
                    )
                }
            case .location:
                if config.locationPrecision == .coarse {
                    if let latStr = payload.metadata["latitude"],
                       let lonStr = payload.metadata["longitude"] {
                        let latDecimals = latStr.split(separator: ".").dropFirst().first?.count ?? 0
                        let lonDecimals = lonStr.split(separator: ".").dropFirst().first?.count ?? 0
                        let isHighPrecision = latDecimals > 2 || lonDecimals > 2
                        if isHighPrecision {
                            violations.append(
                                SensorPrivacyViolation(
                                    sensorType: .location,
                                    ruleId: "SENS-004",
                                    severity: .medium,
                                    message: "Location payload contains precise coordinates while policy mandates coarse precision.",
                                    remediation: "Round latitude and longitude to 2 decimal places in coarse mode."
                                )
                            )
                        }
                    }
                }
            }
        }

        let penalty = violations.reduce(0.0) { acc, v in
            switch v.severity {
            case .critical: return acc + 35.0
            case .high: return acc + 20.0
            case .medium: return acc + 10.0
            case .low: return acc + 5.0
            case .info: return acc + 1.0
            }
        }

        let score = max(0.0, 100.0 - penalty)
        let hasCriticalOrHigh = violations.contains { $0.severity >= .high }
        let passed = !hasCriticalOrHigh && score >= 80.0

        var recs: [String] = []
        if !passed {
            recs.append("Ensure user opt-in is confirmed before enabling companion sensors and clamp payload bandwidth.")
        }

        return CompanionSensorAuditReport(
            passed: passed,
            score: score,
            evaluatedPayloadsCount: payloads.count,
            violations: violations,
            recommendations: recs
        )
    }

    /// Sanitizes location coordinates according to precision mode.
    public static func sanitizeCoordinates(latitude: Double, longitude: Double, precision: LocationPrecisionMode) -> (latitude: Double, longitude: Double) {
        switch precision {
        case .full:
            return (latitude, longitude)
        case .coarse:
            let factor = 100.0 // ~1.1km
            let roundedLat = (latitude * factor).rounded() / factor
            let roundedLon = (longitude * factor).rounded() / factor
            return (roundedLat, roundedLon)
        }
    }

    private static func mapSensorKind(_ kind: CompanionSensorPayload.SensorKind) -> CompanionSensorType {
        switch kind {
        case .cameraPhoto: return .camera
        case .voiceAudioChunk: return .microphone
        case .location: return .location
        }
    }
}
