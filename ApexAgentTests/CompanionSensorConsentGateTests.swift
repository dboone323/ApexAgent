import Testing
import Foundation
@testable import ApexAgentCore

@Suite("Batch 64 — Companion Camera & Audio Sensor Privacy Consent Gate Tests")
struct CompanionSensorConsentGateTests {

    @Test("Authorized sensor payloads pass audit with score 100.0")
    func authorizedPayloadsPass() {
        var config = CompanionSensorPrivacyConfig()
        config.consents[.camera] = .authorized
        config.consents[.microphone] = .authorized
        config.consents[.location] = .authorized

        let sampleImageBytes = Data(repeating: 0xFF, count: 1024)
        let payloads = [
            CompanionSensorPayload(
                kind: .cameraPhoto,
                dataBase64: sampleImageBytes.base64EncodedString(),
                metadata: ["device": "Dan's iPhone", "bytes": "1024"]
            ),
            CompanionSensorPayload(
                kind: .voiceAudioChunk,
                dataBase64: Data(repeating: 0xAA, count: 512).base64EncodedString(),
                metadata: ["codec": "aac"]
            ),
            CompanionSensorPayload(
                kind: .location,
                dataBase64: "",
                metadata: ["latitude": "37.77", "longitude": "-122.42"]
            )
        ]

        let report = CompanionSensorConsentGate.audit(payloads: payloads, config: config)
        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.violations.isEmpty)
        #expect(report.evaluatedPayloadsCount == 3)
    }

    @Test("Unauthorized camera transmission triggers critical violation")
    func unauthorizedCameraTriggersCritical() {
        var config = CompanionSensorPrivacyConfig()
        config.consents[.camera] = .denied

        let payload = CompanionSensorPayload(
            kind: .cameraPhoto,
            dataBase64: Data([1, 2, 3]).base64EncodedString()
        )

        let report = CompanionSensorConsentGate.audit(payloads: [payload], config: config)
        #expect(!report.passed)
        #expect(report.violations.contains { $0.ruleId == "SENS-001" && $0.severity == .critical })
    }

    @Test("Oversized camera photo triggers high violation")
    func oversizedPhotoTriggersHighViolation() {
        var config = CompanionSensorPrivacyConfig(maxPhotoSizeBytes: 1024)
        config.consents[.camera] = .authorized

        let largeData = Data(repeating: 0x55, count: 2048)
        let payload = CompanionSensorPayload(
            kind: .cameraPhoto,
            dataBase64: largeData.base64EncodedString()
        )

        let report = CompanionSensorConsentGate.audit(payloads: [payload], config: config)
        #expect(!report.passed)
        #expect(report.violations.contains { $0.ruleId == "SENS-002" && $0.severity == .high })
    }

    @Test("Precise coordinates in coarse mode trigger medium violation")
    func preciseCoordinatesInCoarseModeTriggerViolation() {
        var config = CompanionSensorPrivacyConfig(locationPrecision: .coarse)
        config.consents[.location] = .authorized

        let payload = CompanionSensorPayload(
            kind: .location,
            dataBase64: "",
            metadata: ["latitude": "37.774929", "longitude": "-122.419416"] // high precision
        )

        let report = CompanionSensorConsentGate.audit(payloads: [payload], config: config)
        #expect(report.passed) // passes since single medium penalty (-10) keeps score at 90 >= 80
        #expect(report.violations.contains { $0.ruleId == "SENS-004" && $0.severity == .medium })
    }

    @Test("sanitizeCoordinates accurately coarsens GPS precision")
    func sanitizeCoordinatesCoarsensPrecision() {
        let exactLat = 37.774929
        let exactLon = -122.419416

        let coarse = CompanionSensorConsentGate.sanitizeCoordinates(latitude: exactLat, longitude: exactLon, precision: .coarse)
        #expect(coarse.latitude == 37.77)
        #expect(coarse.longitude == -122.42)

        let full = CompanionSensorConsentGate.sanitizeCoordinates(latitude: exactLat, longitude: exactLon, precision: .full)
        #expect(full.latitude == exactLat)
        #expect(full.longitude == exactLon)
    }

    @Test("Report serializes to formatted JSON")
    func reportSerializesToJSON() {
        let config = CompanionSensorPrivacyConfig()
        let report = CompanionSensorConsentGate.audit(payloads: [], config: config)
        let json = report.toJSON()
        #expect(json.contains("\"passed\" : true"))
        #expect(json.contains("\"score\" : 100"))
    }
}
