import Foundation
import Observation
import SwiftData
import AppKit
import SharedKit

/// Protocol for providing access to the AgentOrchestrator instance.
/// This replaces direct access to `AgentOrchestrator.shared` static property,
/// enabling dependency injection and better testability.
@MainActor
public protocol OrchestratorProvider: Sendable {
    var orchestrator: AgentOrchestrator { get }
    var dataBus: AppGroupDataBus { get }
}
