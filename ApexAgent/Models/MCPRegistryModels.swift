import Foundation
import SharedKit

// MARK: - MCP Registry Models (Issue #87, C2)
//
// Types matching the official Model Context Protocol (MCP) Registry OpenAPI specification
// (https://registry.modelcontextprotocol.io/openapi.yaml, schema v0.1).

/// A single argument definition for a package binary or runtime.
public struct MCPRegistryArgument: Codable, Sendable, Equatable, Hashable {
    public var type: String?
    public var name: String?
    public var value: String?
    public var description: String?
    public var isRequired: Bool?
    public var isSecret: Bool?
    public var defaultVal: String?

    public init(
        type: String? = nil,
        name: String? = nil,
        value: String? = nil,
        description: String? = nil,
        isRequired: Bool? = nil,
        isSecret: Bool? = nil,
        defaultVal: String? = nil
    ) {
        self.type = type
        self.name = name
        self.value = value
        self.description = description
        self.isRequired = isRequired
        self.isSecret = isSecret
        self.defaultVal = defaultVal
    }

    enum CodingKeys: String, CodingKey {
        case type
        case name
        case value
        case description
        case isRequired
        case isSecret
        case defaultVal = "default"
    }
}

/// An environment variable declaration for an MCP package.
public struct MCPRegistryEnvVar: Codable, Sendable, Equatable, Hashable {
    public var name: String
    public var description: String?
    public var isRequired: Bool?
    public var isSecret: Bool?
    public var value: String?

    public init(
        name: String,
        description: String? = nil,
        isRequired: Bool? = nil,
        isSecret: Bool? = nil,
        value: String? = nil
    ) {
        self.name = name
        self.description = description
        self.isRequired = isRequired
        self.isSecret = isSecret
        self.value = value
    }
}

/// A transport configuration for a package or remote.
public struct MCPRegistryTransport: Codable, Sendable, Equatable, Hashable {
    public var type: String // "stdio", "streamable-http", "sse"
    public var url: String?
    public var headers: [MCPRegistryHeader]?

    public init(type: String, url: String? = nil, headers: [MCPRegistryHeader]? = nil) {
        self.type = type
        self.url = url
        self.headers = headers
    }
}

/// Header definition for HTTP/SSE transports.
public struct MCPRegistryHeader: Codable, Sendable, Equatable, Hashable {
    public var name: String
    public var description: String?
    public var isSecret: Bool?
    public var value: String?

    public init(name: String, description: String? = nil, isSecret: Bool? = nil, value: String? = nil) {
        self.name = name
        self.description = description
        self.isSecret = isSecret
        self.value = value
    }
}

/// A package distribution configuration (e.g. npm, pypi, docker, mcpb).
public struct MCPRegistryPackage: Codable, Sendable, Equatable, Hashable {
    public var registryType: String
    public var identifier: String
    public var version: String?
    public var fileSha256: String?
    public var registryBaseUrl: String?
    public var runtimeHint: String?
    public var transport: MCPRegistryTransport
    public var environmentVariables: [MCPRegistryEnvVar]?
    public var packageArguments: [MCPRegistryArgument]?
    public var runtimeArguments: [MCPRegistryArgument]?

    public init(
        registryType: String,
        identifier: String,
        version: String? = nil,
        fileSha256: String? = nil,
        registryBaseUrl: String? = nil,
        runtimeHint: String? = nil,
        transport: MCPRegistryTransport,
        environmentVariables: [MCPRegistryEnvVar]? = nil,
        packageArguments: [MCPRegistryArgument]? = nil,
        runtimeArguments: [MCPRegistryArgument]? = nil
    ) {
        self.registryType = registryType
        self.identifier = identifier
        self.version = version
        self.fileSha256 = fileSha256
        self.registryBaseUrl = registryBaseUrl
        self.runtimeHint = runtimeHint
        self.transport = transport
        self.environmentVariables = environmentVariables
        self.packageArguments = packageArguments
        self.runtimeArguments = runtimeArguments
    }
}

/// A remote endpoint configuration (e.g. streamable-http or sse).
public struct MCPRegistryRemote: Codable, Sendable, Equatable, Hashable {
    public var type: String // "streamable-http", "sse"
    public var url: String
    public var headers: [MCPRegistryHeader]?

    public init(type: String, url: String, headers: [MCPRegistryHeader]? = nil) {
        self.type = type
        self.url = url
        self.headers = headers
    }
}

/// Repository metadata for the MCP server source.
public struct MCPRegistryRepository: Codable, Sendable, Equatable, Hashable {
    public var url: String?
    public var source: String?
    public var owner: String?

    public init(url: String? = nil, source: String? = nil, owner: String? = nil) {
        self.url = url
        self.source = source
        self.owner = owner
    }
}

/// Official metadata attached by the registry (lifecycle status, publication time).
public struct MCPRegistryOfficialMeta: Codable, Sendable, Equatable, Hashable {
    public var status: String // "active", "deprecated", "deleted"
    public var statusChangedAt: String?
    public var publishedAt: String?
    public var updatedAt: String?
    public var isLatest: Bool?
    public var statusMessage: String?

    public init(
        status: String = "active",
        statusChangedAt: String? = nil,
        publishedAt: String? = nil,
        updatedAt: String? = nil,
        isLatest: Bool? = true,
        statusMessage: String? = nil
    ) {
        self.status = status
        self.statusChangedAt = statusChangedAt
        self.publishedAt = publishedAt
        self.updatedAt = updatedAt
        self.isLatest = isLatest
        self.statusMessage = statusMessage
    }
}

/// Core server definition matching ServerJSON in the registry spec.
public struct MCPRegistryServer: Codable, Sendable, Equatable, Hashable {
    public var schema: String?
    public var name: String // e.g. "io.modelcontextprotocol/everything" or "agency.extremely/agency"
    public var title: String?
    public var description: String
    public var version: String
    public var websiteUrl: String?
    public var repository: MCPRegistryRepository?
    public var packages: [MCPRegistryPackage]?
    public var remotes: [MCPRegistryRemote]?

    public init(
        schema: String? = nil,
        name: String,
        title: String? = nil,
        description: String,
        version: String,
        websiteUrl: String? = nil,
        repository: MCPRegistryRepository? = nil,
        packages: [MCPRegistryPackage]? = nil,
        remotes: [MCPRegistryRemote]? = nil
    ) {
        self.schema = schema
        self.name = name
        self.title = title
        self.description = description
        self.version = version
        self.websiteUrl = websiteUrl
        self.repository = repository
        self.packages = packages
        self.remotes = remotes
    }

    enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case name
        case title
        case description
        case version
        case websiteUrl
        case repository
        case packages
        case remotes
    }
}

/// An entry returned from the official registry API (/v0.1/servers).
public struct MCPRegistryItem: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: String { server.name }
    public var server: MCPRegistryServer
    public var officialMeta: MCPRegistryOfficialMeta?
    public var publisherProvidedMeta: [String: String]?

    public init(
        server: MCPRegistryServer,
        officialMeta: MCPRegistryOfficialMeta? = nil,
        publisherProvidedMeta: [String: String]? = nil
    ) {
        self.server = server
        self.officialMeta = officialMeta
        self.publisherProvidedMeta = publisherProvidedMeta
    }

    enum CodingKeys: String, CodingKey {
        case server
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.server = try container.decode(MCPRegistryServer.self, forKey: .server)

        if let metaContainer = try? container.nestedContainer(keyedBy: DynamicMetaKey.self, forKey: .meta) {
            let officialKey = DynamicMetaKey(stringValue: "io.modelcontextprotocol.registry/official")
            if let key = officialKey, let meta = try? metaContainer.decode(MCPRegistryOfficialMeta.self, forKey: key) {
                self.officialMeta = meta
            }

            let publisherKey = DynamicMetaKey(stringValue: "io.modelcontextprotocol.registry/publisher-provided")
            if let key = publisherKey, let dict = try? metaContainer.decode([String: String].self, forKey: key) {
                self.publisherProvidedMeta = dict
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(server, forKey: .server)
        // Meta encoding can be simplified if re-serializing
    }

    private struct DynamicMetaKey: CodingKey {
        var stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { return nil }
    }
}

/// Top-level list response from GET /v0.1/servers.
public struct MCPRegistryListResponse: Codable, Sendable {
    public var servers: [MCPRegistryItem]?
}
