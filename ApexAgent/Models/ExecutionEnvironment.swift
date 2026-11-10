import Foundation

public enum ExecutionEnvironment: Equatable, Sendable {
    case host
    case appleContainer
    case tartVM(spaceID: String)
    case seatbelt(spaceID: String)
}
