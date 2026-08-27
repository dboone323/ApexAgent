import Foundation
import FoundationModels
import OSLog

struct OSLogQueryTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "query_logs"
    let description = "Queries the unified log via OSLogStore."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "Subsystem to filter by")
        var subsystem: String?
        
        @Guide(description: "Category to filter by")
        var category: String?
        
        @Guide(description: "Log level: debug, info, error, or fault")
        var level: String?
        
        @Guide(description: "Look back time in seconds (default 300)")
        var lastSeconds: Int?
        
        @Guide(description: "Text to search in log messages")
        var searchText: String?
        
        @Guide(description: "Maximum number of logs to return (default 50)")
        var limit: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator, riskDescription: nil) {
            
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let seconds = Double(arguments.lastSeconds ?? 300)
            let position = store.position(date: Date().addingTimeInterval(-seconds))
            
            var predicates: [NSPredicate] = []
            if let subsystem = arguments.subsystem {
                predicates.append(NSPredicate(format: "subsystem == %@", subsystem))
            }
            if let category = arguments.category {
                predicates.append(NSPredicate(format: "category == %@", category))
            }
            
            if let level = arguments.level?.lowercased() {
                let messageType: OSLogEntryLog.Level? = switch level {
                case "debug": .debug
                case "info": .info
                case "error": .error
                case "fault": .fault
                default: nil
                }
                
                if let type = messageType {
                    predicates.append(NSPredicate(format: "level == %d", type.rawValue))
                }
            }
            
            let predicate = predicates.isEmpty ? nil : NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            
            let entries = try store.getEntries(at: position, matching: predicate)
            
            var results: [String] = []
            let limit = arguments.limit ?? 50
            let searchText = arguments.searchText?.lowercased()
            
            let formatter = ISO8601DateFormatter()
            
            for entry in entries {
                guard let logEntry = entry as? OSLogEntryLog else { continue }
                
                let message = logEntry.composedMessage
                if let search = searchText, !message.lowercased().contains(search) {
                    continue
                }
                
                let timestamp = formatter.string(from: logEntry.date)
                let levelStr = {
                    switch logEntry.level {
                    case .debug: return "DEBUG"
                    case .info: return "INFO"
                    case .notice: return "NOTICE"
                    case .error: return "ERROR"
                    case .fault: return "FAULT"
                    default: return "UNKNOWN"
                    }
                }()
                
                let line = "[\(timestamp)] [\(levelStr)] \(logEntry.subsystem)/\(logEntry.category): \(message)"
                results.append(line)
                
                if results.count >= limit {
                    break
                }
            }
            
            if results.isEmpty {
                return "No logs found matching criteria."
            }
            return results.joined(separator: "\n")
        }
    }
}
