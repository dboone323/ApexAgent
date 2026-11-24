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

case .gateQueue(let subArgs):
    let exitCode = await GateQueueCLI.run(arguments: subArgs)
    exit(exitCode)

case .scheduler(let subArgs):
    let exitCode = await SchedulerCLI.run(arguments: subArgs)
    exit(exitCode)

case .longRun(let subArgs):
    let exitCode = await LongRunCLI.run(arguments: subArgs)
    exit(exitCode)

case .goal(let subArgs):
    let exitCode = await GoalCLI.run(arguments: subArgs)
    exit(exitCode)

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

case .traceVerify(let jsonOutput):
    let result = await TraceLiveVerifier.runVerification(jsonOutput: jsonOutput)
    print(result.output)
    exit(result.passed ? 0 : 1)

case .secretsVerify(let jsonOutput):
    let result = await SecretsHygieneLiveVerifier.runVerification(jsonOutput: jsonOutput)
    print(result.output)
    exit(result.passed ? 0 : 1)

case .promptInjectionVerify:
    let result = await PromptInjectionLiveVerifier.runVerification()
    print(result.output)
    exit(result.passed ? 0 : 1)

case .skillsVerify:
    let result = await AgentSkillsLiveVerifier.runVerification()
    print(result.output)
    exit(result.passed ? 0 : 1)

case .skillsRun(let id, let args, _):
    let result = await ApexCLIRouter.runNamedSkill(id: id, arguments: args)
    if result.exitCode == 0 {
        print(result.output)
    } else {
        fputs("\(result.output)\n", stderr)
    }
    exit(result.exitCode)

case .evalVerify(let jsonOutput):
    let result = await EvalHarnessLiveVerifier.runVerification(jsonOutput: jsonOutput)
    print(result.output)
    exit(result.passed ? 0 : 1)

case .verificationVerify(let runId, let jsonOutput):
    let result = await VerificationUILiveVerifier.runVerification(targetRunId: runId, jsonOutput: jsonOutput)
    print(result.output)
    exit(result.passed ? 0 : 1)

case .memoryVerify:
    let result = await MemoryConsolidationLiveVerifier.runVerification()
    print(result.output)
    exit(result.passed ? 0 : 1)

case .sharedMemoryVerify(let jsonOutput):
    let result = SharedMemoryBlocksLiveVerifier.runVerification(writeLogTo: "runs/issue84/live-verify.log")
    if jsonOutput {
        let dict: [String: Any] = ["passed": result.passed, "output": result.output]
        let data = (try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted])) ?? Data()
        print(String(data: data, encoding: .utf8) ?? "{}")
        exit(result.passed ? 0 : 1)
    }
    print(result.output)
    exit(result.passed ? 0 : 1)

case .reviewerVerify(let jsonOutput):
    let result = await ReviewerCriticLiveVerifier.runVerification(jsonOutput: jsonOutput)
    print(result.output)
    exit(result.passed ? 0 : 1)

case .mcpRegistryVerify(let jsonOutput):
    let result = await MCPRegistryLiveVerifier.runVerification(jsonOutput: jsonOutput)
    print(result.output)
    exit(result.passed ? 0 : 1)

case .workspacesVerify(let jsonOutput):
    let result = await TaskWorkspaceLiveVerifier.runVerification(jsonOutput: jsonOutput)
    print(result.output)
    exit(result.passed ? 0 : 1)

case .onboardingVerify(let jsonOutput):
    let result = await OnboardingLiveVerifier.runVerification(jsonOutput: jsonOutput)
    print(result.output)
    exit(result.passed ? 0 : 1)

case .modelRouterVerify(let jsonOutput):
    let logPath = "/Users/danielstevens/.gemini/antigravity/worktrees/ApexAgent/issue179_model_router/runs/issue179/live-verify-round1.log"
    let result = await ModelRouterLiveVerifier.runVerification(logPath: logPath, jsonOutput: jsonOutput)
    print(result.output)
    exit(result.passed ? 0 : 1)

case .modelRetirementVerify(let jsonOutput):
    let logPath = "/Users/danielstevens/.gemini/antigravity/worktrees/ApexAgent/issue180_model_retirement/runs/issue180/live-verify-round1.log"
    let result = await ModelRetirementLiveVerifier.runVerification(logPath: logPath, jsonOutput: jsonOutput)
    print(result.output)
    exit(result.passed ? 0 : 1)

case .agentGovernanceVerify(let jsonOutput):
    let repoRoot = ApexCLIRouter.resolveRepositoryRoot()
    let logPath = ProcessInfo.processInfo.environment["APEX_GOVERNANCE_VERIFY_LOG"] ?? repoRoot.appendingPathComponent("runs/issue181/live-verify-round4.log").path
    let result = await AgentGovernanceLiveVerifier.runVerification(logPath: logPath, jsonOutput: jsonOutput)
    print(result.output)
    exit(result.passed ? 0 : 1)

case .proactiveVerify(let jsonOutput):
    let result = await ProactiveInitiativeLiveVerifier.runVerification(jsonOutput: jsonOutput)
    print(result.output)
    exit(result.passed ? 0 : 1)

case .personalContextVerify:
    let result = await PersonalContextIndexLiveVerifier.runVerification()
    print(result.output)
    exit(result.passed ? 0 : 1)
case .traceReplay, .tracesList:
    // If not handled by renderImmediateSubcommand (e.g. empty target):
    if let imm = ApexCLIRouter.renderImmediateSubcommand(invocation.command) {
        print(imm.output)
        exit(imm.exitCode)
    }
    exit(1)

case .launchGUI, .help, .version, .doctor, .diagnostics, .skillsList, .skillsValidate, .skillsShow, .routinesList, .completions, .man, .audit, .sbom, .changelog, .releaseCheck, .provenance, .sarif, .selfTest, .traces, .policy, .approvals, .governance, .governanceSetLimit:
    ApexAgentApp.main()
}
