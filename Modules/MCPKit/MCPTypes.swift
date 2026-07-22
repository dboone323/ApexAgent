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

public struct MCPToolResult: Codable, Sendable {
    public let content: [MCPContent]
    public let isError: Bool

    public init(content: [MCPContent], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }
}

public struct MCPContent: Codable, Sendable {
    public let type: String
    public let text: String

    public init(type: String = "text", text: String) {
        self.type = type
        self.text = text
    }
}

public struct MCPRequest: Codable, Sendable {
    public let method: String
    public let params: MCPRequestParams?
    public let id: Int?
}

public struct MCPRequestParams: Codable, Sendable {
    public let name: String?
    public let arguments: [String: MCPValue]?
}
