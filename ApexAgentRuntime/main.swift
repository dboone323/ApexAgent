import Foundation
import ApexAgentCore
import Darwin

setbuf(stdout, nil)
setbuf(stderr, nil)

let invocation: ParsedCLIInvocation
do {
    invocation = try ApexCLIRouter.parse(arguments: CommandLine.arguments)
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(64)
}

ApexCLIRouter.applyEnvironmentOverrides(from: invocation)

if let immediate = ApexCLIRouter.renderImmediateSubcommand(invocation.command) {
    print(immediate.output)
    exit(immediate.exitCode)
}

switch invocation.command {
case .daemon:
    await runDaemonMode()
    exit(0)

case .spaceCLI(let subArgs):
    await runSpaceCLIMode(subcommandArgs: subArgs)
    exit(0)

case .prompt(let text, let allowTools):
    if !allowTools {
        setenv("APEX_DISABLE_DYNAMIC_TOOLS", "1", 1)
    }
    await ApexAgentCore.AppDelegate.runCLIMode(prompt: text, allowTools: allowTools)
    exit(0)

case .routinesRun(let name, _):
    let result = await ApexCLIRouter.runNamedRoutine(name)
    if result.exitCode == 0 {
        print(result.output)
    } else {
        fputs("\(result.output)\n", stderr)
    }
    exit(result.exitCode)

case .launchGUI, .help, .version, .doctor, .diagnostics, .skillsList, .skillsValidate, .routinesList:
    ApexAgentApp.main()
}
