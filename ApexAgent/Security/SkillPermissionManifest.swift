import Foundation

// MARK: - Skill Permission Manifest (Issue #107)
//
// Every skill, plugin, or dynamic tool installed or registered in ApexAgent carries
// a declared permission manifest specifying its identity, version, and requested
// capabilities (tools, network, filesystem paths, shell).
// Registration without a manifest is strictly refused.

/// Declared permission scopes requested by a skill.
public struct SkillPermissions: Codable, Sendable, Equatable {
    /// Internal tools the skill is authorized to invoke or provide.
    public var tools: [String]
    /// Whether outbound network requests (curl, HTTP, socket connections) are permitted.
    public var allowNetwork: Bool
    /// Filesystem paths or directory prefixes the skill is authorized to access.
    public var filesystemPaths: [String]
    /// Whether direct shell process execution (/bin/zsh, /bin/sh) is permitted.
    public var allowShell: Bool

    public init(
        tools: [String] = [],
        allowNetwork: Bool = false,
        filesystemPaths: [String] = [],
        allowShell: Bool = false
    ) {
        self.tools = tools
        self.allowNetwork = allowNetwork
        self.filesystemPaths = filesystemPaths
        self.allowShell = allowShell
    }

    enum CodingKeys: String, CodingKey {
        case tools
        case allowNetwork = "allow_network"
        case allowNetworkCamel = "allowNetwork"
        case filesystemPaths = "filesystem_paths"
        case filesystemPathsCamel = "filesystemPaths"
        case allowShell = "allow_shell"
        case allowShellCamel = "allowShell"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.tools = (try? container.decode([String].self, forKey: .tools)) ?? []
        self.allowNetwork = (try? container.decode(Bool.self, forKey: .allowNetwork))
            ?? (try? container.decode(Bool.self, forKey: .allowNetworkCamel))
            ?? false
        self.filesystemPaths = (try? container.decode([String].self, forKey: .filesystemPaths))
            ?? (try? container.decode([String].self, forKey: .filesystemPathsCamel))
            ?? []
        self.allowShell = (try? container.decode(Bool.self, forKey: .allowShell))
            ?? (try? container.decode(Bool.self, forKey: .allowShellCamel))
            ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tools, forKey: .tools)
        try container.encode(allowNetwork, forKey: .allowNetwork)
        try container.encode(filesystemPaths, forKey: .filesystemPaths)
        try container.encode(allowShell, forKey: .allowShell)
    }

    /// Converts permissions to a JSON-serializable dictionary.
    public func toDictionary() -> [String: Any] {
        [
            "tools": tools,
            "allow_network": allowNetwork,
            "filesystem_paths": filesystemPaths,
            "allow_shell": allowShell
        ]
    }
}

/// The complete permission manifest describing an installable skill.
public struct SkillPermissionManifest: Codable, Sendable, Equatable {
    public var name: String
    public var version: String
    public var description: String
    public var scriptPath: String?
    public var permissions: SkillPermissions

    public init(
        name: String,
        version: String = "1.0.0",
        description: String = "",
        scriptPath: String? = nil,
        permissions: SkillPermissions = SkillPermissions()
    ) {
        self.name = name
        self.version = version
        self.description = description
        self.scriptPath = scriptPath
        self.permissions = permissions
    }

    enum CodingKeys: String, CodingKey {
        case name
        case version
        case description
        case scriptPath = "script_path"
        case scriptPathCamel = "scriptPath"
        case permissions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.version = (try? container.decode(String.self, forKey: .version)) ?? "1.0.0"
        self.description = (try? container.decode(String.self, forKey: .description)) ?? ""
        self.scriptPath = (try? container.decode(String.self, forKey: .scriptPath))
            ?? (try? container.decode(String.self, forKey: .scriptPathCamel))
        self.permissions = (try? container.decode(SkillPermissions.self, forKey: .permissions))
            ?? SkillPermissions()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(version, forKey: .version)
        try container.encode(description, forKey: .description)
        try container.encodeIfPresent(scriptPath, forKey: .scriptPath)
        try container.encode(permissions, forKey: .permissions)
    }

    /// Converts manifest to a JSON-serializable dictionary matching ApexAgent storage conventions.
    public func toDictionary(parameterSchema: [String: Any]? = nil) -> [String: Any] {
        var dict: [String: Any] = [
            "name": name,
            "version": version,
            "description": description,
            "permissions": permissions.toDictionary()
        ]
        if let scriptPath = scriptPath {
            dict["script_path"] = scriptPath
        }
        if let params = parameterSchema {
            dict["parameters"] = params
        }
        return dict
    }

    /// Parses a SkillPermissionManifest from a dictionary.
    public static func from(dictionary: [String: Any]) -> SkillPermissionManifest? {
        guard let name = dictionary["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let version = dictionary["version"] as? String ?? "1.0.0"
        let description = dictionary["description"] as? String ?? ""
        let scriptPath = (dictionary["script_path"] as? String) ?? (dictionary["scriptPath"] as? String)

        var perms = SkillPermissions()
        if let permDict = dictionary["permissions"] as? [String: Any] {
            let tools = permDict["tools"] as? [String] ?? []
            let allowNetwork = (permDict["allow_network"] as? Bool) ?? (permDict["allowNetwork"] as? Bool) ?? false
            let filesystemPaths = (permDict["filesystem_paths"] as? [String]) ?? (permDict["filesystemPaths"] as? [String]) ?? []
            let allowShell = (permDict["allow_shell"] as? Bool) ?? (permDict["allowShell"] as? Bool) ?? false
            perms = SkillPermissions(
                tools: tools,
                allowNetwork: allowNetwork,
                filesystemPaths: filesystemPaths,
                allowShell: allowShell
            )
        }

        return SkillPermissionManifest(
            name: name,
            version: version,
            description: description,
            scriptPath: scriptPath,
            permissions: perms
        )
    }
}
