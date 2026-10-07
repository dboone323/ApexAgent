import Foundation
import Observation

// MARK: - Deep Link Router & Navigation State (Batch 24)

/// Validated destination parsed from an `apexagent://` URL.
public enum DeepLinkDestination: Sendable, Equatable {
    case chat(id: String)
    case routine(id: String)
    case skill(name: String)
    case diagnostics
    case settings
    case command(name: String)
}

/// Structured routing error for malformed or unknown deep links.
public enum DeepLinkError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedScheme(String?)
    case missingRoute
    case unknownRoute(String)
    case missingIdentifier(route: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedScheme(let scheme):
            return "Unsupported URL scheme '\(scheme ?? "nil")'; expected 'apexagent'."
        case .missingRoute:
            return "Deep link is missing a target route."
        case .unknownRoute(let route):
            return "Unknown deep link route '\(route)'."
        case .missingIdentifier(let route):
            return "Deep link route '\(route)' requires a non-empty identifier."
        }
    }
}

/// Pure parser and URL builder for `apexagent://` deep links.
public enum DeepLinkRouter {
    public static let scheme = "apexagent"

    /// Parses a `URL` into a `DeepLinkDestination` or returns a structured `DeepLinkError`.
    public static func parse(_ url: URL) -> Result<DeepLinkDestination, DeepLinkError> {
        guard let urlScheme = url.scheme?.lowercased(), urlScheme == scheme else {
            return .failure(.unsupportedScheme(url.scheme))
        }

        let rawHost = (url.host(percentEncoded: false) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let pathSegments = url.pathComponents
            .filter { $0 != "/" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let route: String
        let remainder: [String]
        if !rawHost.isEmpty {
            route = rawHost.lowercased()
            remainder = pathSegments
        } else if let first = pathSegments.first {
            route = first.lowercased()
            remainder = Array(pathSegments.dropFirst())
        } else {
            return .failure(.missingRoute)
        }

        switch route {
        case "chat":
            guard let id = remainder.first, !id.isEmpty else {
                return .failure(.missingIdentifier(route: "chat"))
            }
            return .success(.chat(id: id))

        case "routine":
            guard let id = remainder.first, !id.isEmpty else {
                return .failure(.missingIdentifier(route: "routine"))
            }
            return .success(.routine(id: id))

        case "skill":
            guard let name = remainder.first, !name.isEmpty else {
                return .failure(.missingIdentifier(route: "skill"))
            }
            return .success(.skill(name: name))

        case "diagnostics":
            return .success(.diagnostics)

        case "settings":
            return .success(.settings)

        case "command":
            guard let name = remainder.first, !name.isEmpty else {
                return .failure(.missingIdentifier(route: "command"))
            }
            return .success(.command(name: name))

        default:
            return .failure(.unknownRoute(route))
        }
    }

    /// Constructs a canonical `apexagent://` URL for the given destination.
    public static func url(for destination: DeepLinkDestination) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        switch destination {
        case .chat(let id):
            components.host = "chat"
            components.path = "/\(id)"
        case .routine(let id):
            components.host = "routine"
            components.path = "/\(id)"
        case .skill(let name):
            components.host = "skill"
            components.path = "/\(name)"
        case .diagnostics:
            components.host = "diagnostics"
        case .settings:
            components.host = "settings"
        case .command(let name):
            components.host = "command"
            components.path = "/\(name)"
        }
        return components.url ?? URL(string: "apexagent://diagnostics")!
    }
}

/// Observable navigation state driven by incoming `apexagent://` deep links.
@Observable
@MainActor
public final class DeepLinkNavigationState {
    public static let shared = DeepLinkNavigationState()

    public var activeChatId: String?
    public var selectedRoutineId: String?
    public var selectedSkillName: String?
    public var showDiagnostics = false
    public var showSettings = false
    public var lastExecutedCommand: String?
    public var lastDestination: DeepLinkDestination?
    public var lastError: DeepLinkError?

    public init() {}

    /// Parses and applies an incoming URL to the navigation state.
    @discardableResult
    public func handle(_ url: URL) -> Result<DeepLinkDestination, DeepLinkError> {
        let result = DeepLinkRouter.parse(url)
        switch result {
        case .success(let destination):
            lastError = nil
            lastDestination = destination
            apply(destination)
            AppLog.info(.ui, "Handled deep link: \(url.absoluteString)")
        case .failure(let error):
            lastError = error
            AppLog.error(.ui, "Rejected malformed deep link: \(url.absoluteString)", error: error)
        }
        return result
    }

    public func apply(_ destination: DeepLinkDestination) {
        switch destination {
        case .chat(let id):
            activeChatId = id
        case .routine(let id):
            selectedRoutineId = id
        case .skill(let name):
            selectedSkillName = name
        case .diagnostics:
            showDiagnostics = true
            NotificationCenter.default.post(name: .showDiagnosticsSheet, object: nil)
        case .settings:
            showSettings = true
            NotificationCenter.default.post(name: .showSettingsSheet, object: nil)
        case .command(let name):
            lastExecutedCommand = name
        }
    }

    public func reset() {
        activeChatId = nil
        selectedRoutineId = nil
        selectedSkillName = nil
        showDiagnostics = false
        showSettings = false
        lastExecutedCommand = nil
        lastDestination = nil
        lastError = nil
    }
}

extension Notification.Name {
    public static let showSettingsSheet = Notification.Name("showSettingsSheet")
}
