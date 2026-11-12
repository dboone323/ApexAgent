import Foundation

public enum MCPValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case array([MCPValue])
    case object([String: MCPValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let val = try? container.decode(String.self) {
            self = .string(val)
        } else if let val = try? container.decode(Double.self) {
            self = .number(val)
        } else if let val = try? container.decode(Bool.self) {
            self = .boolean(val)
        } else if let val = try? container.decode([MCPValue].self) {
            self = .array(val)
        } else if let val = try? container.decode([String: MCPValue].self) {
            self = .object(val)
        } else if container.decodeNil() {
            self = .null
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid MCPValue")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let val): try container.encode(val)
        case .number(let val): try container.encode(val)
        case .boolean(let val): try container.encode(val)
        case .array(let val): try container.encode(val)
        case .object(let val): try container.encode(val)
        case .null: try container.encodeNil()
        }
    }
}

public struct MCPTool: Codable, Sendable {
    public let name: String
    public let description: String
    public let inputSchema: MCPInputSchema

    public init(name: String, description: String, inputSchema: MCPInputSchema) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    public static func make(
        name: String,
        description: String,
        inputs: [MCPInputProperty]
    ) -> MCPTool {
        let properties = Dictionary(uniqueKeysWithValues: inputs.map {
            ($0.name, MCPPropertySchema(type: $0.type, description: $0.description))
        })
        let required = inputs.filter { $0.required }.map { $0.name }
        return MCPTool(
            name: name,
            description: description,
            inputSchema: MCPInputSchema(
                type: "object",
                properties: properties,
                required: required
            )
        )
    }
}

public struct MCPInputSchema: Codable, Sendable {
    public let type: String
    public let properties: [String: MCPPropertySchema]
    public let required: [String]
}

public struct MCPPropertySchema: Codable, Sendable {
    public let type: String
    public let description: String?
}

public struct MCPInputProperty: Sendable {
    public let name: String
    public let type: String
    public let description: String?
    public let required: Bool

    public static func string(_ name: String, description: String? = nil, required: Bool = false) -> MCPInputProperty {
        MCPInputProperty(name: name, type: "string", description: description, required: required)
    }

    public static func int(_ name: String, description: String? = nil, required: Bool = false) -> MCPInputProperty {
        MCPInputProperty(name: name, type: "integer", description: description, required: required)
    }

    public static func boolean(_ name: String, description: String? = nil, required: Bool = false) -> MCPInputProperty {
        MCPInputProperty(name: name, type: "boolean", description: description, required: required)
    }
}

public struct MCPToolResult: Codable, Sendable, Equatable {
    public let content: [MCPContent]
    public let isError: Bool

    public init(content: [MCPContent], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }
}

public struct MCPContent: Codable, Sendable, Equatable {
    public let type: String
    public let text: String

    public init(type: String = "text", text: String) {
        self.type = type
        self.text = text
    }
}

public struct MCPRequest: Codable, Sendable, Equatable {
    public let method: String
    public let params: MCPRequestParams?
    public let id: Int?
}

public struct MCPRequestParams: Codable, Sendable, Equatable {
    public let name: String?
    public let arguments: [String: MCPValue]?
}

// MARK: - MCP 2026-07-28 Modern Specifications

public struct MCPExtensionCapability: Codable, Sendable, Equatable {
    public let version: String?
    public let options: [String: MCPValue]?

    public init(version: String? = "2026-07-28", options: [String: MCPValue]? = nil) {
        self.version = version
        self.options = options
    }
}

public enum MCPTaskStatus: String, Codable, Sendable, Equatable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
    case cancelled = "cancelled"

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        case .pending, .running: return false
        }
    }
}

public struct MCPTask: Codable, Sendable, Equatable, Identifiable {
    public var id: String { taskId }
    public let taskId: String
    public let name: String?
    public let status: MCPTaskStatus
    public let progress: Double?
    public let message: String?
    public let result: MCPToolResult?
    public let error: String?
    public let createdAt: Date?
    public let updatedAt: Date?

    public init(
        taskId: String,
        name: String? = nil,
        status: MCPTaskStatus,
        progress: Double? = nil,
        message: String? = nil,
        result: MCPToolResult? = nil,
        error: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.taskId = taskId
        self.name = name
        self.status = status
        self.progress = progress
        self.message = message
        self.result = result
        self.error = error
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct MCPServerCard: Codable, Sendable, Equatable {
    public let name: String
    public let version: String
    public let description: String?
    public let vendor: String?
    public let website: String?
    public let documentation: String?
    public let iconURL: String?
    public let capabilities: [String]?
    public let tags: [String]?
    public let license: String?
    public let privacyPolicy: String?

    public init(
        name: String,
        version: String,
        description: String? = nil,
        vendor: String? = nil,
        website: String? = nil,
        documentation: String? = nil,
        iconURL: String? = nil,
        capabilities: [String]? = nil,
        tags: [String]? = nil,
        license: String? = nil,
        privacyPolicy: String? = nil
    ) {
        self.name = name
        self.version = version
        self.description = description
        self.vendor = vendor
        self.website = website
        self.documentation = documentation
        self.iconURL = iconURL
        self.capabilities = capabilities
        self.tags = tags
        self.license = license
        self.privacyPolicy = privacyPolicy
    }
}

public struct MCPAppDefinition: Codable, Sendable, Equatable, Identifiable {
    public var id: String { appId }
    public let appId: String
    public let title: String
    public let description: String?
    public let version: String?
    public let entryPoint: String
    public let isInlineHTML: Bool
    public let permissions: [String]?
    public let supportedFormFactors: [String]?

    public init(
        appId: String,
        title: String,
        description: String? = nil,
        version: String? = nil,
        entryPoint: String,
        isInlineHTML: Bool = true,
        permissions: [String]? = nil,
        supportedFormFactors: [String]? = nil
    ) {
        self.appId = appId
        self.title = title
        self.description = description
        self.version = version
        self.entryPoint = entryPoint
        self.isInlineHTML = isInlineHTML
        self.permissions = permissions
        self.supportedFormFactors = supportedFormFactors
    }
}
