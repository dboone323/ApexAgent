// apexflow — runs ApexAgent's local automation workflows against real code
// paths and prints a hard pass/fail verdict per workflow.
//
//   swift run apexflow             # all fifteen workflows
//   swift run apexflow 3 7 11      # selected workflows
//   swift run apexflow --list      # list all workflows and subsystems
//   swift run apexflow --json 11   # output JSON results

import Foundation
import ApexAgentCore

@main
struct ApexFlow {
    static func main() async {
        setenv("APEX_TEST_MODE", "1", 1)

        let args = Array(CommandLine.arguments.dropFirst())
        let jsonOutput = args.contains("--json")

        if args.contains("--help") || args.contains("-h") {
            print("""
            apexflow — ApexAgent Local Automation Workflow Runner (15 workflows)

            USAGE:
              apexflow [options] [workflow-ids...]

            OPTIONS:
              --list         List all 15 workflows and their target subsystems
              --json         Emit results or workflow catalog as structured JSON
              -h, --help     Show this help message
            """)
            exit(0)
        }

        if args.contains("--list") {
            let descriptors = ApexWorkflows.allDescriptors()
            if jsonOutput {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let data = try? encoder.encode(descriptors),
                   let str = String(data: data, encoding: .utf8) {
                    print(str)
                }
            } else {
                print("ApexAgent automation workflow catalog (\(descriptors.count) workflows)")
                print(String(repeating: "─", count: 72))
                for wf in descriptors {
                    print(String(format: "[%2d] %-44s (%s)", wf.id, (wf.name as NSString).utf8String ?? "", (wf.subsystems as NSString).utf8String ?? ""))
                }
            }
            exit(0)
        }

        let selected = Set(args.compactMap(Int.init))
        let results = await ApexWorkflows.run(ids: selected)

        if jsonOutput {
            print(ApexWorkflows.formatJSON(results))
        } else {
            print("ApexAgent automation workflows")
            print(String(repeating: "─", count: 72))
            for result in results { print(result.line) }
            print(String(repeating: "─", count: 72))

            let passed = results.filter(\.passed).count
            print("\(passed)/\(results.count) workflows passed")
        }

        let passed = results.filter(\.passed).count
        exit(passed == results.count ? 0 : 1)
    }
}
