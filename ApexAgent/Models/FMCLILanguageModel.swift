import Foundation
import FoundationModels

/// A `LanguageModel` conformer that delegates to the macOS 27 `fm` command-line
/// tool (`/usr/bin/fm`), which exposes the on-device Apple Foundation Model and
/// the Private Cloud Compute server model. This lets ApexAgent treat Apple's
/// first-party models as just another `LanguageModel` behind the same Swift API
/// the other providers use — exactly the WWDC26 "one Swift API for any LLM"
/// model.
///
/// `fm` subcommands (verified present on macOS 27 beta):
///   available | chat | count-tokens | quota-usage | respond | schema | serve
/// Models: `system` (on-device) and `pcc` (Private Cloud Compute).
public struct FMCLILanguageModel: LanguageModel {
    public typealias Executor = FMCLILanguageModelExecutor

    /// Which `fm` model backend to target.
    public enum Backend: String, Sendable {
        case system
        case pcc
    }

    public let backend: Backend

    public var capabilities: LanguageModelCapabilities {
        // `fm` supports tool calling on the server model; keep it conservative
        // and let the request's toolCallingMode gate actual use.
        LanguageModelCapabilities([.reasoning])
    }

    public var executorConfiguration: FMCLILanguageModelExecutor.Configuration {
        FMCLILanguageModelExecutor.Configuration(backend: backend)
    }

    public init(backend: Backend = .system) {
        self.backend = backend
    }

    /// Convenience: the on-device Apple model.
    public static var onDevice: FMCLILanguageModel { FMCLILanguageModel(backend: .system) }
    /// Convenience: the Private Cloud Compute server model.
    public static var privateCloud: FMCLILanguageModel { FMCLILanguageModel(backend: .pcc) }
}

public struct FMCLILanguageModelExecutor: LanguageModelExecutor {
    public typealias Model = FMCLILanguageModel

    public struct Configuration: Hashable, Sendable {
        public let backend: FMCLILanguageModel.Backend
        public init(backend: FMCLILanguageModel.Backend) { self.backend = backend }
    }

    public let configuration: Configuration

    public init(configuration: Configuration) throws {
        self.configuration = configuration
    }

    public func prewarm(model: FMCLILanguageModel, transcript: Transcript) {}

    public func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: FMCLILanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        // Flatten the transcript into a single prompt string. `fm respond`
        // takes a plain prompt (system instructions are passed via --instructions
        // when available). We concatenate instructions + turns for fidelity.
        var systemText = ""
        var promptText = ""

        for entry in request.transcript {
            switch entry {
            case .instructions(let inst):
                for segment in inst.segments {
                    if case .text(let textSeg) = segment { systemText += textSeg.content + "\n" }
                }
            case .prompt(let prompt):
                for segment in prompt.segments {
                    if case .text(let textSeg) = segment { promptText += textSeg.content + "\n" }
                }
            case .response(let response):
                for segment in response.segments {
                    if case .text(let textSeg) = segment { promptText += "Assistant: " + textSeg.content + "\n" }
                }
            case .toolCalls, .toolOutput, .reasoning:
                // `fm` (text CLI) does not participate in tool loops; skip.
                break
            @unknown default:
                break
            }
        }

        let entryID = UUID().uuidString
        var args = ["respond", "--model", configuration.backend.rawValue, "--stream"]
        if !systemText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["--instructions", systemText.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        args.append(promptText.trimmingCharacters(in: .whitespacesAndNewlines))

        guard let fmURL = URL(string: "file:///usr/bin/fm") else {
            throw NSError(domain: "FMCLILanguageModel", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "fm CLI not found at /usr/bin/fm."])
        }

        let process = Process()
        process.executableURL = fmURL
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw NSError(domain: "FMCLILanguageModel", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to launch fm: \(error.localizedDescription)"])
        }

        // Stream fm's stdout line-by-line into the generation channel.
        let stdoutHandle = stdoutPipe.fileHandleForReading
        var accumulated = ""
        for try await line in stdoutHandle.bytes.lines {
            guard !line.isEmpty else { continue }
            accumulated += line + "\n"
            await channel.send(LanguageModelExecutorGenerationChannel.Event.response(
                entryID: entryID,
                action: .appendText(line + "\n", segmentID: nil, tokenCount: 0)
            ))
        }

        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            if accumulated.isEmpty {
                throw NSError(domain: "FMCLILanguageModel", code: -3,
                              userInfo: [NSLocalizedDescriptionKey: "fm exited \(process.terminationStatus): \(stderr)"])
            }
        }
    }
}
