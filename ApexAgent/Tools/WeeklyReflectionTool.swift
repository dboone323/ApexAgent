import Foundation
import FoundationModels
import SwiftData
import SharedKit

public struct WeeklyReflectionTool {
    private let modelContext: ModelContext?

    public init(modelContext: ModelContext? = nil) {
        self.modelContext = modelContext
    }

    public func save(reflection: WeeklyReflection) throws {
        guard let modelContext else { return }
        modelContext.insert(reflection)
        try modelContext.save()
    }

    public func recent(limit: Int = 5) async -> [WeeklyReflection] {
        guard let modelContext else { return [] }
        var descriptor = FetchDescriptor<WeeklyReflection>()
        descriptor.fetchLimit = max(limit, 1) * 4
        let all = (try? modelContext.fetch(descriptor)) ?? []
        return Array(all.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }

    @available(macOS 15.0, *)
    public func generatedReflectionSummary(for prompt: String) async throws -> String {
        let model = SystemLanguageModel.default
        let session = LanguageModelSession(model: model)
        let response = try await session.respond(to: prompt)
        return String(decoding: response.content.data(using: .utf8) ?? Data(), as: UTF8.self)
    }
}
