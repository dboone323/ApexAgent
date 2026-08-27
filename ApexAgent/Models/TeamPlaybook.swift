import Foundation

public struct PlaybookBot: Codable, Sendable {
    public var name: String
    public var title: String
    public var description: String
    public var avatarName: String
    public var isChiefOfStaff: Bool
    public var modelProvider: String?
    public var ollamaModel: String?
    public var memory: String?
    
    public init(name: String, title: String, description: String, avatarName: String, isChiefOfStaff: Bool, modelProvider: String? = nil, ollamaModel: String? = nil, memory: String? = nil) {
        self.name = name
        self.title = title
        self.description = description
        self.avatarName = avatarName
        self.isChiefOfStaff = isChiefOfStaff
        self.modelProvider = modelProvider
        self.ollamaModel = ollamaModel
        self.memory = memory
    }
}

public struct TeamPlaybook: Codable, Sendable {
    public var name: String
    public var description: String
    public var version: String
    public var bots: [PlaybookBot]
    
    public init(name: String, description: String, version: String = "1.0", bots: [PlaybookBot]) {
        self.name = name
        self.description = description
        self.version = version
        self.bots = bots
    }
    
    public func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
    
    public static func decode(from data: Data) throws -> TeamPlaybook {
        let decoder = JSONDecoder()
        return try decoder.decode(TeamPlaybook.self, from: data)
    }
    
    enum PlaybookError: Error {
        case invalidMarkdownFormat
        case missingRequiredField(String)
    }
    
    public static func decodeFromMarkdown(_ markdown: String) throws -> TeamPlaybook {
        let lines = markdown.components(separatedBy: .newlines)
        
        var isFrontmatter = false
        var frontmatterLines: [String] = []
        var bodyLines: [String] = []
        var frontmatterEndIndex = -1
        
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if index == 0 && trimmed == "---" {
                isFrontmatter = true
                continue
            }
            
            if isFrontmatter && trimmed == "---" {
                isFrontmatter = false
                frontmatterEndIndex = index
                break
            }
            
            if isFrontmatter {
                frontmatterLines.append(line)
            }
        }
        
        if frontmatterEndIndex == -1 {
            throw PlaybookError.invalidMarkdownFormat
        }
        
        for index in (frontmatterEndIndex + 1)..<lines.count {
            bodyLines.append(lines[index])
        }
        
        var name = ""
        var description = ""
        var version = "1.0"
        
        for line in frontmatterLines {
            let parts = line.split(separator: ":", maxSplits: 1).map { String($0) }
            if parts.count == 2 {
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let value = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                
                switch key {
                case "name": name = value
                case "description": description = value
                case "version": version = value
                default: break
                }
            }
        }
        
        if name.isEmpty { throw PlaybookError.missingRequiredField("name in frontmatter") }
        if description.isEmpty { throw PlaybookError.missingRequiredField("description in frontmatter") }
        
        var bots: [PlaybookBot] = []
        var currentBot: [String: String] = [:]
        var currentBotName = ""
        
        func saveCurrentBot() {
            if !currentBotName.isEmpty {
                let bot = PlaybookBot(
                    name: currentBotName,
                    title: currentBot["title"] ?? "",
                    description: currentBot["description"] ?? "",
                    avatarName: currentBot["avatarName"] ?? "",
                    isChiefOfStaff: (currentBot["isChiefOfStaff"]?.lowercased() == "true"),
                    modelProvider: currentBot["modelProvider"],
                    ollamaModel: currentBot["ollamaModel"],
                    memory: currentBot["memory"]
                )
                bots.append(bot)
            }
            currentBot = [:]
            currentBotName = ""
        }
        
        var i = 0
        while i < bodyLines.count {
            let line = bodyLines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## Bot: ") {
                saveCurrentBot()
                currentBotName = String(trimmed.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("- ") && !currentBotName.isEmpty {
                let content = String(trimmed.dropFirst(2))
                let parts = content.split(separator: ":", maxSplits: 1).map { String($0) }
                if parts.count == 2 {
                    let key = parts[0].trimmingCharacters(in: .whitespaces)
                    var value = parts[1].trimmingCharacters(in: .whitespaces)
                    
                    if value.isEmpty || value == "|" || value == ">" {
                        var multiLineValue = ""
                        i += 1
                        while i < bodyLines.count {
                            let nextLine = bodyLines[i]
                            if nextLine.trimmingCharacters(in: .whitespaces).isEmpty {
                                multiLineValue += "\n"
                            } else if nextLine.hasPrefix("  ") || nextLine.hasPrefix("\t") {
                                let lineContent = nextLine.trimmingCharacters(in: .whitespaces)
                                multiLineValue += (multiLineValue.isEmpty ? "" : "\n") + lineContent
                            } else {
                                i -= 1
                                break
                            }
                            i += 1
                        }
                        currentBot[key] = multiLineValue
                    } else {
                        if value.hasPrefix("\"") && value.hasSuffix("\"") {
                            value = String(value.dropFirst().dropLast())
                        } else if value.hasPrefix("'") && value.hasSuffix("'") {
                            value = String(value.dropFirst().dropLast())
                        }
                        currentBot[key] = value
                    }
                }
            }
            i += 1
        }
        saveCurrentBot()
        
        return TeamPlaybook(name: name, description: description, version: version, bots: bots)
    }
    
    public func toMarkdown() -> String {
        var md = ""
        md += "---\n"
        md += "name: \"\(name)\"\n"
        md += "description: \"\(description)\"\n"
        md += "version: \"\(version)\"\n"
        md += "---\n\n"
        
        for bot in bots {
            md += "## Bot: \(bot.name)\n"
            md += "- title: \"\(bot.title)\"\n"
            md += "- description: \"\(bot.description)\"\n"
            md += "- avatarName: \"\(bot.avatarName)\"\n"
            md += "- isChiefOfStaff: \(bot.isChiefOfStaff)\n"
            if let mp = bot.modelProvider {
                md += "- modelProvider: \"\(mp)\"\n"
            }
            if let om = bot.ollamaModel {
                md += "- ollamaModel: \"\(om)\"\n"
            }
            if let mem = bot.memory {
                md += "- memory: |\n"
                let lines = mem.components(separatedBy: .newlines)
                for line in lines {
                    md += "  \(line)\n"
                }
            }
            md += "\n"
        }
        
        return md.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}
