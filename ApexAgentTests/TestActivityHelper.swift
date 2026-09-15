import XCTest
import Foundation

/// Structured test activity and diagnostic attachment helpers for rich .xcresult reports.
@MainActor
public enum TestActivity {
    
    /// Executes a synchronous block inside a named XCTContext activity step.
    public static func step(_ name: String, block: (XCTActivity) throws -> Void) rethrows {
        try XCTContext.runActivity(named: name) { activity in
            try block(activity)
        }
    }
    
    /// Attaches a UTF-8 string payload (e.g. logs or output) to the given activity step.
    public static func attachText(_ text: String, named name: String, to activity: XCTActivity? = nil) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        activity?.add(attachment)
    }
    
    /// Attaches an Encodable JSON object payload to the given activity step.
    public static func attachJSON<T: Encodable>(_ object: T, named name: String, to activity: XCTActivity? = nil) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(object),
           let jsonString = String(data: data, encoding: .utf8) {
            attachText(jsonString, named: name, to: activity)
        }
    }
}
