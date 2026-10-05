import Foundation
import ApexAgentCore
import Darwin

setbuf(stdout, nil)
setbuf(stderr, nil)

let args = CommandLine.arguments

if let providerIndex = args.firstIndex(of: "--provider"), providerIndex + 1 < args.count {
    setenv("APEX_MODEL_PROVIDER", args[providerIndex + 1], 1)
}

if let modelIndex = args.firstIndex(of: "--model"), modelIndex + 1 < args.count {
    let modelValue = args[modelIndex + 1]
    setenv("APEX_OLLAMA_MODEL", modelValue, 1)
    setenv("APEX_GEMINI_MODEL", modelValue, 1)
    setenv("APEX_MLX_MODEL", modelValue, 1)
}

if args.contains("--daemon") {
    await runDaemonMode()
    exit(0)
}

if let spaceIdx = args.firstIndex(of: "--space-cli") {
    let subArgs = Array(args.dropFirst(spaceIdx + 1))
    await runSpaceCLIMode(subcommandArgs: subArgs)
    exit(0)
}

if let cliIndex = args.firstIndex(where: { $0 == "--cli" || $0 == "--prompt" || $0 == "-p" }) {
    let cliArguments = args.dropFirst(cliIndex + 1)
    let allowTools = cliArguments.contains("--allow-tools") && !cliArguments.contains("--no-tools")
    let prompt = cliArguments
        .filter { $0 != "--allow-tools" && $0 != "--no-tools" }
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else {
        fputs("Usage: ApexAgent --cli [--allow-tools|--no-tools] <prompt>\n", stderr)
        exit(64)
    }
    if !allowTools {
        setenv("APEX_DISABLE_DYNAMIC_TOOLS", "1", 1)
    }
    await ApexAgentCore.AppDelegate.runCLIMode(prompt: prompt, allowTools: allowTools)
    exit(0)
}

ApexAgentApp.main()
