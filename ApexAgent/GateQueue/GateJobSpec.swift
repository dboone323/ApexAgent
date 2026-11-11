import Foundation

/// Specification for a gate job submitted to the file-drop queue.
/// Dropped as a `.json` file inside `<targetProject>/runs/gate-queue/`.
public struct GateJobSpec: Codable, Sendable, Equatable {
    /// Unique identifier for the job.
    public let id: String
    /// Human-readable job name (e.g. "lint", "test-deep", "solo-gate").
    public let jobName: String
    /// Absolute path to the target project directory.
    public let targetProject: String
    /// Command to execute as an argv array (no shell interpolation).
    public let gateCommand: [String]
    /// Optional path to a baseline file (absolute or relative to target project).
    public let baselineFile: String?
    /// Submission timestamp.
    public let submittedAt: Date

    public init(
        id: String = UUID().uuidString,
        jobName: String,
        targetProject: String,
        gateCommand: [String],
        baselineFile: String? = nil,
        submittedAt: Date = Date()
    ) {
        self.id = id
        self.jobName = jobName
        self.targetProject = targetProject
        self.gateCommand = gateCommand
        self.baselineFile = baselineFile
        self.submittedAt = submittedAt
    }

    /// Default queue directory for a target project: `<targetProject>/runs/gate-queue`.
    public static func queueDirectory(for projectPath: String) -> URL {
        URL(fileURLWithPath: projectPath, isDirectory: true)
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent("gate-queue", isDirectory: true)
    }

    /// JSON encoder configured with ISO8601 date formatting.
    public static var jsonEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// JSON decoder configured with ISO8601 date decoding.
    public static var jsonDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Encodes this spec into JSON data.
    public func toJSONData() throws -> Data {
        try Self.jsonEncoder.encode(self)
    }

    /// Decodes a spec from JSON data.
    public static func fromJSONData(_ data: Data) throws -> GateJobSpec {
        try Self.jsonDecoder.decode(GateJobSpec.self, from: data)
    }

    /// Submits this job spec to the target project's queue directory on disk.
    @discardableResult
    public func submit(to targetProjectOverride: String? = nil) throws -> URL {
        let target = targetProjectOverride ?? self.targetProject
        let queueDir = Self.queueDirectory(for: target)
        try FileManager.default.createDirectory(at: queueDir, withIntermediateDirectories: true)

        let sanitizedJobName = jobName
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        let filename = "\(sanitizedJobName)-\(id).json"
        let fileURL = queueDir.appendingPathComponent(filename)

        let data = try toJSONData()
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }
}
