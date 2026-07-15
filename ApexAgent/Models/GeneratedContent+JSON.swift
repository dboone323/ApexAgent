import Foundation
import FoundationModels

extension GeneratedContent {
    func toJSONObject() -> Any {
        switch self.kind {
        case .null:
            return NSNull()
        case .bool(let value):
            return value
        case .number(let value):
            return value
        case .string(let value):
            return value
        case .array(let array):
            return array.map { $0.toJSONObject() }
        case .structure(let properties, _):
            var dict: [String: Any] = [:]
            for (k, v) in properties {
                dict[k] = v.toJSONObject()
            }
            return dict
        @unknown default:
            return NSNull()
        }
    }
}
