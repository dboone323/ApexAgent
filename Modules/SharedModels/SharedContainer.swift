import Foundation
import SwiftData

public enum SharedContainer {
    public static let suiteDirectory: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("ApexSuite", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    public static let storeURL: URL =
        suiteDirectory.appendingPathComponent("default.store")

    public static func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(url: storeURL)
        return try ModelContainer(
            for: Schema(versionedSchema: ApexSuiteSchemaV1.self),
            migrationPlan: ApexSuiteMigrationPlan.self,
            configurations: [config]
        )
    }
}
