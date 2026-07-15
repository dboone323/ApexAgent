import Foundation

@globalActor
public actor ToolActor: Sendable {
    public static let shared = ToolActor()
}
