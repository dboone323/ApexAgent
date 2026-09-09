import Foundation
import ApexAgentCore
import Darwin

setbuf(stdout, nil)
setbuf(stderr, nil)

let args = CommandLine.arguments

if args.contains("--daemon") {
    await runDaemonMode()
    exit(0)
}

if let cliIndex = args.firstIndex(of: "--cli"), cliIndex + 1 < args.count {
    let prompt = args[cliIndex + 1]
    await ApexAgentCore.AppDelegate.runCLIMode(prompt: prompt)
    exit(0)
}

ApexAgentApp.main()
