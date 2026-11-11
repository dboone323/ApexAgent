import Foundation

public enum ExecutionEnvironment: Equatable, Sendable {
    case host
    case appleContainer
    case seatbelt(spaceID: String)
}
