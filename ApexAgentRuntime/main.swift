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

if let cliIndex = args.firstIndex(where: { $0 == "--cli" || $0 == "--prompt" || $0 == "-p" }), cliIndex + 1 < args.count {
    let prompt = args[cliIndex + 1]
    await ApexAgentCore.AppDelegate.runCLIMode(prompt: prompt)
    exit(0)
}

ApexAgentApp.main()

