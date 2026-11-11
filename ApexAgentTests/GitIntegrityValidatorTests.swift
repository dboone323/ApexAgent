import Testing
import Foundation
@testable import ApexAgentCore

@Suite("GitIntegrityValidator tests")
struct GitIntegrityValidatorTests {

    @Test func integrityAdditionsOnlyPasses() {
        let diff = "A\tApexAgentTests/NewTests.swift\nA\tFooTests/Bar.swift\nM\tSources/App.swift\n"
        #expect(GitIntegrityValidator.integrityViolations(diffOutput: diff).isEmpty)
    }

    @Test func integrityDeletedTestFileFails() {
        let diff = "D\tApexAgentTests/OldTests.swift\n"
        let v = GitIntegrityValidator.integrityViolations(diffOutput: diff)
        #expect(!v.isEmpty)
    }

    @Test func integrityModifiedExistingTestFails() {
        let diff = "M\tApexAgentTests/ExistingTests.swift\n"
        let v = GitIntegrityValidator.integrityViolations(diffOutput: diff)
        #expect(!v.isEmpty)
    }

    @Test func integrityDeletedIndividualTestFails() {
        // git diff --name-status won't show individual test deletion; simulate renamed? Use M as modified.
        let diff = "M\tApexAgentTests/ExistingTests.swift\n"
        let v = GitIntegrityValidator.integrityViolations(diffOutput: diff)
        #expect(!v.isEmpty)
    }
}
