import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Batch 38 — CLI Shell Completions, Manpage Generator & audit/sbom Subcommand Tests")
struct CLICompletionGeneratorTests {

    @Test("zsh, bash, and fish completion scripts cover all subcommands, flags, and apexflow")
    func generatesZshBashAndFishCompletions() {
        let zsh = CLICompletionGenerator.generateCompletionScript(for: .zsh)
        #expect(zsh.contains("#compdef ApexAgent apexflow"))
        #expect(zsh.contains("compdef _apexagent ApexAgent"))
        #expect(zsh.contains("'doctor:Run subsystem health checks'"))
        #expect(zsh.contains("'audit:Run repository hygiene and supply-chain dependency lock audit'"))
        #expect(zsh.contains("'sbom:Export Software Bill of Materials"))
        #expect(zsh.contains("'changelog:Generate categorized Conventional Changelog and next SemVer'"))
        #expect(zsh.contains("'release-check:Audit Info.plist and project.yml version parity and release readiness'"))
        #expect(zsh.contains("'provenance:Generate SLSA v1.0 build provenance attestation and SHA-256 digests'"))
        #expect(zsh.contains("'sarif:Export OASIS SARIF v2.1.0 security and static analysis report'"))
        #expect(zsh.contains("'self-test:Run end-to-end CLI subcommand smoke-test contract matrix'"))
        #expect(zsh.contains("26 27 28 29 30"))

        let bash = CLICompletionGenerator.generateCompletionScript(for: .bash)
        #expect(bash.contains("complete -F _apexagent_completions ApexAgent"))
        #expect(bash.contains("complete -F _apexflow_completions apexflow"))
        #expect(bash.contains("ollama gemini mlx foundation"))
        #expect(bash.contains("26 27 28 29 30"))

        let fish = CLICompletionGenerator.generateCompletionScript(for: .fish)
        #expect(fish.contains("complete -c ApexAgent -f -n '__fish_use_subcommand' -a 'doctor'"))
        #expect(fish.contains("complete -c ApexAgent -f -n '__fish_use_subcommand' -a 'sbom'"))
        #expect(fish.contains("complete -c ApexAgent -f -n '__fish_use_subcommand' -a 'provenance'"))
        #expect(fish.contains("complete -c ApexAgent -f -n '__fish_use_subcommand' -a 'sarif'"))
        #expect(fish.contains("complete -c ApexAgent -f -n '__fish_use_subcommand' -a 'self-test'"))
        #expect(fish.contains("complete -c apexflow -l list"))
    }

    @Test("generateManPage emits valid troff man(1) sections for ApexAgent and apexflow")
    func generatesTroffManPage() {
        let man = CLICompletionGenerator.generateManPage(version: "2026.10.0")
        #expect(man.contains(".TH APEXAGENT 1"))
        #expect(man.contains(".SH NAME"))
        #expect(man.contains(".SH SYNOPSIS"))
        #expect(man.contains(".SH GLOBAL OPTIONS"))
        #expect(man.contains(".SH SUBCOMMANDS"))
        #expect(man.contains(".SH EXIT STATUS"))
        #expect(man.contains(".B doctor"))
        #expect(man.contains(".B sbom"))
        #expect(man.contains(".B changelog"))
        #expect(man.contains(".B release-check"))
        #expect(man.contains(".B provenance"))
        #expect(man.contains(".B sarif"))
        #expect(man.contains(".B self-test"))
    }

    @Test("ApexCLIRouter parses and renders completions, man, audit, and sbom subcommands")
    @MainActor
    func routerHandlesCompletionsManAuditAndSBOM() throws {
        #expect(try ApexCLIRouter.parse(arguments: ["ApexAgent", "completions"]).command == .completions(shell: .zsh))
        #expect(try ApexCLIRouter.parse(arguments: ["ApexAgent", "completions", "bash"]).command == .completions(shell: .bash))
        #expect(try ApexCLIRouter.parse(arguments: ["ApexAgent", "completions", "fish"]).command == .completions(shell: .fish))
        #expect(try ApexCLIRouter.parse(arguments: ["ApexAgent", "man"]).command == .man)
        #expect(try ApexCLIRouter.parse(arguments: ["ApexAgent", "--json", "audit"]).command == .audit(jsonOutput: true))
        #expect(try ApexCLIRouter.parse(arguments: ["ApexAgent", "--json", "sbom"]).command == .sbom(jsonOutput: true))

        #expect(throws: ApexCLIError.unknownSubcommand("completions powershell")) {
            _ = try ApexCLIRouter.parse(arguments: ["ApexAgent", "completions", "powershell"])
        }

        let fishOut = try #require(ApexCLIRouter.renderImmediateSubcommand(.completions(shell: .fish)))
        #expect(fishOut.exitCode == 0)
        #expect(fishOut.output.contains("complete -c ApexAgent"))

        let manOut = try #require(ApexCLIRouter.renderImmediateSubcommand(.man))
        #expect(manOut.exitCode == 0)
        #expect(manOut.output.contains(".TH APEXAGENT 1"))

        let sbomJSON = try #require(ApexCLIRouter.renderImmediateSubcommand(.sbom(jsonOutput: true)))
        #expect(sbomJSON.exitCode == 0)
        let parsedSBOM = try #require(
            try JSONSerialization.jsonObject(with: Data(sbomJSON.output.utf8)) as? [String: Any]
        )
        #expect(parsedSBOM["bomFormat"] as? String == "CycloneDX")
    }
}
