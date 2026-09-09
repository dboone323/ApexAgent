import Foundation

// MARK: - Companion Camera & Hardware Sensor Node (OpenClaw Style)

public struct CompanionCameraSensor: Sendable {
    public init() {}

    /// Encodes a raw image data buffer into base64 for transmission to the Mac host.
    public func encodePhotoPayload(jpegData: Data, sourceDevice: String = "Dan's iPhone 15 Pro Max") -> CompanionSensorPayload {
        let base64 = jpegData.base64EncodedString()
        let meta = [
            "device": sourceDevice,
            "format": "jpeg",
            "bytes": "\(jpegData.count)"
        ]
        return CompanionSensorPayload(
            kind: .cameraPhoto,
            dataBase64: base64,
            metadata: meta,
            timestamp: Date()
        )
    }

    /// Creates a GPS location sensor payload.
    public func encodeLocationPayload(latitude: Double, longitude: Double, accuracyMeters: Double) -> CompanionSensorPayload {
        let meta = [
            "latitude": "\(latitude)",
            "longitude": "\(longitude)",
            "accuracy": "\(accuracyMeters)"
        ]
        return CompanionSensorPayload(
            kind: .location,
            dataBase64: "",
            metadata: meta,
            timestamp: Date()
        )
    }
}
