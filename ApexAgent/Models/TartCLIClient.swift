import Foundation

public struct TartVMInfo: Sendable, Equatable, Codable {
    public let name: String
    public let source: String
    public let state: String
    public let running: Bool
    public let diskSize: Int
    public let size: Int

    public init(name: String, source: String, state: String, running: Bool, diskSize: Int, size: Int) {
        self.name = name
        self.source = source
        self.state = state
        self.running = running
        self.diskSize = diskSize
        self.size = size
    }

    private enum CodingKeys: String, CodingKey {
        case name = "Name"
        case source = "Source"
        case state = "State"
        case running = "Running"
        case diskSize = "Disk"
        case size = "Size"
    }
}

public enum TartCLIClientError: Error, Sendable, Equatable {
    case binaryNotFound
    case launchFailed(String)
    case nonZeroExit(command: [String], exitCode: Int32, stderr: String)
    case timeout
    case invalidOutput(String)
}

public protocol TartClientProtocol: Sendable {
    func clone(source: String, name: String) async throws
    func set(name: String, cpu: Int?, memoryMB: Int?) async throws
    func run(name: String, softnet: Bool) async throws
    func exec(name: String, arguments: [String]) async throws -> (stdout: String, stderr: String, exitCode: Int32)
    func execStdin(name: String, arguments: [String], input: Data) async throws -> (stdout: String, stderr: String, exitCode: Int32)
    func ip(name: String, wait: Int?) async throws -> String
    func stop(name: String) async throws
    func delete(name: String) async throws
    func list() async throws -> [TartVMInfo]
}

public actor TartCLIClient: TartClientProtocol {
    public let binaryURL: URL

    public init(binaryURL: URL? = nil) {
        if let binaryURL {
            self.binaryURL = binaryURL
        } else if let resolved = Self.resolveBinary() {
            self.binaryURL = resolved
        } else {
            self.binaryURL = URL(fileURLWithPath: "/opt/homebrew/bin/tart")
        }
    }

    public static func resolveBinary() -> URL? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["TART_BINARY"],
           fm.isExecutableFile(atPath: env) {
            return URL(fileURLWithPath: env)
        }
        let cellar = "/opt/homebrew/Cellar/tart"
        if let versions = try? fm.contentsOfDirectory(atPath: cellar) {
            for version in versions.sorted().reversed() {
                let candidate = "\(cellar)/\(version)/libexec/tart.app/Contents/MacOS/tart"
                if fm.isExecutableFile(atPath: candidate) {
                    return URL(fileURLWithPath: candidate)
                }
            }
        }
        if fm.isExecutableFile(atPath: "/opt/homebrew/bin/tart") {
            return URL(fileURLWithPath: "/opt/homebrew/bin/tart")
        }
        return nil
    }

    public static func cloneArguments(source: String, name: String) -> [String] {
        ["clone", source, name]
    }

    public static func setArguments(name: String, cpu: Int? = nil, memoryMB: Int? = nil) -> [String] {
        var args: [String] = ["set", name]
        if let cpu {
            args += ["--cpu", String(cpu)]
        }
        if let memoryMB {
            args += ["--memory", String(memoryMB)]
        }
        return args
    }

    public static func runArguments(name: String, softnet: Bool) -> [String] {
        ["run"] + (softnet ? ["--net-softnet"] : []) + [name]
    }

    public static func execArguments(name: String, arguments: [String]) -> [String] {
        ["exec", name] + arguments
    }

    public static func execStdinArguments(name: String, arguments: [String]) -> [String] {
        ["exec", "-i", name] + arguments
    }

    public static func ipArguments(name: String, wait: Int? = nil) -> [String] {
        var args: [String] = ["ip", name]
        if let wait {
            args += ["--wait", String(wait)]
        }
        return args
    }

    public static func stopArguments(name: String) -> [String] {
        ["stop", name]
    }

    public static func deleteArguments(name: String) -> [String] {
        ["delete", name]
    }

    public static func listArguments() -> [String] {
        ["list", "--format", "json"]
    }

    public static func parseVMList(_ data: Data) throws -> [TartVMInfo] {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode([TartVMInfo].self, from: data)
        } catch {
            throw TartCLIClientError.invalidOutput("Unable to parse tart list JSON: \(error.localizedDescription)")
        }
    }

    public static func parseIP(_ stdout: String) -> String? {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func execute(_ arguments: [String]) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = binaryURL
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw TartCLIClientError.launchFailed(error.localizedDescription)
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        let exitCode = process.terminationStatus

        if exitCode != 0 {
            throw TartCLIClientError.nonZeroExit(command: arguments, exitCode: exitCode, stderr: stderr)
        }
        return (stdout, stderr, exitCode)
    }

    private var runningProcesses: [String: Process] = [:]

    public func clone(source: String, name: String) async throws {
        _ = try await execute(Self.cloneArguments(source: source, name: name))
    }

    public func set(name: String, cpu: Int? = nil, memoryMB: Int? = nil) async throws {
        _ = try await execute(Self.setArguments(name: name, cpu: cpu, memoryMB: memoryMB))
    }

    public func run(name: String, softnet: Bool) async throws {
        let process = Process()
        process.executableURL = binaryURL
        process.arguments = Self.runArguments(name: name, softnet: softnet)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw TartCLIClientError.launchFailed(error.localizedDescription)
        }
        runningProcesses[name] = process
    }

    public func exec(name: String, arguments: [String]) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = binaryURL
        process.arguments = Self.execArguments(name: name, arguments: arguments)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw TartCLIClientError.launchFailed(error.localizedDescription)
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        return (stdout, stderr, process.terminationStatus)
    }

    public func execStdin(name: String, arguments: [String], input: Data) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = binaryURL
        process.arguments = Self.execStdinArguments(name: name, arguments: arguments)

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw TartCLIClientError.launchFailed(error.localizedDescription)
        }

        inPipe.fileHandleForWriting.write(input)
        try? inPipe.fileHandleForWriting.close()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        return (stdout, stderr, process.terminationStatus)
    }

    public func ip(name: String, wait: Int? = nil) async throws -> String {
        let result = try await execute(Self.ipArguments(name: name, wait: wait))
        guard let parsed = Self.parseIP(result.stdout) else {
            throw TartCLIClientError.invalidOutput("Empty IP output")
        }
        return parsed
    }

    public func stop(name: String) async throws {
        _ = try await execute(Self.stopArguments(name: name))
        if let process = runningProcesses[name] {
            process.terminate()
            runningProcesses.removeValue(forKey: name)
        }
    }

    public func delete(name: String) async throws {
        _ = try await execute(Self.deleteArguments(name: name))
        runningProcesses.removeValue(forKey: name)
    }

    public func list() async throws -> [TartVMInfo] {
        let result = try await execute(Self.listArguments())
        guard let data = result.stdout.data(using: .utf8) else {
            throw TartCLIClientError.invalidOutput("Non-UTF8 list output")
        }
        return try Self.parseVMList(data)
    }
}
