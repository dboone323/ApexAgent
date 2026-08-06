// apexflow — runs ApexAgent's local automation workflows against real code
// paths and prints a hard pass/fail verdict per workflow.
//
//   swift run apexflow          # all ten
//   swift run apexflow 3 7      # selected

import Foundation
import ApexAgentCore

@main
struct ApexFlow {
    static func main() async {
        setenv("APEX_TEST_MODE", "1", 1)

        let selected = Set(CommandLine.arguments.dropFirst().compactMap(Int.init))
        let results = await ApexWorkflows.run(ids: selected)

        print("ApexAgent automation workflows")
        print(String(repeating: "─", count: 72))
        for result in results { print(result.line) }
        print(String(repeating: "─", count: 72))

        let passed = results.filter(\.passed).count
        print("\(passed)/\(results.count) workflows passed")
        exit(passed == results.count ? 0 : 1)
    }
}
