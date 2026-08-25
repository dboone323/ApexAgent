import Foundation
import FoundationModels

// MARK: - GitHub Tool (via gh CLI)
// Wraps `gh` CLI for GitHub API access — issues, PRs, repos, etc.

struct GitHubTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "github"
    let description = """
        GitHub API access via gh CLI.
        Actions: issue (list/create/get/edit), pr (list/create/get/edit/merge), repo (list/create/clone/view), workflow (list/run/view), auth (status/login), api (raw REST call).
        Requires gh CLI installed and authenticated (gh auth login).
        """

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "Action: issue, pr, repo, workflow, auth, api")
        var action: String

        @Guide(description: "Sub-action (e.g. for issue: list, create, get, edit, comment, close, reopen)")
        var subAction: String?

        @Guide(description: "Repository in owner/name format (e.g. 'owner/repo')")
        var repo: String?

        @Guide(description: "Issue/PR number")
        var number: Int?

        @Guide(description: "Title (for create)")
        var title: String?

        @Guide(description: "Body (for create/edit/comment)")
        var body: String?

        @Guide(description: "Labels (comma-separated, for create/edit)")
        var labels: String?

        @Guide(description: "Assignees (comma-separated, for create/edit)")
        var assignees: String?

        @Guide(description: "State filter: open, closed, all (for list)")
        var state: String?

        @Guide(description: "Limit (for list, default 30)")
        var limit: Int?

        @Guide(description: "Raw API endpoint for 'api' action (e.g. '/repos/owner/repo/issues')")
        var endpoint: String?

        @Guide(description: "HTTP method for 'api' action (GET, POST, PATCH, DELETE)")
        var method: String?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            // Verify gh is available
            let ghPath = try await findGH()
            
            switch arguments.action {
            case "issue":
                return try await runIssue(ghPath: ghPath, args: arguments)
            case "pr":
                return try await runPR(ghPath: ghPath, args: arguments)
            case "repo":
                return try await runRepo(ghPath: ghPath, args: arguments)
            case "workflow":
                return try await runWorkflow(ghPath: ghPath, args: arguments)
            case "auth":
                return try await runAuth(ghPath: ghPath, args: arguments)
            case "api":
                return try await runAPI(ghPath: ghPath, args: arguments)
            default:
                throw NSError(domain: "GitHubTool", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Unknown action '\(arguments.action)'. Use: issue, pr, repo, workflow, auth, api"])
            }
        }
    }

    private func findGH() async throws -> String {
        let paths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        throw NSError(domain: "GitHubTool", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "gh CLI not found. Install with 'brew install gh'"])
    }

    private func runCommand(_ path: String, _ args: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            throw NSError(domain: "GitHubTool", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "gh exited with \(process.terminationStatus): \(output)"])
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Issue Commands

    private func runIssue(ghPath: String, args: Arguments) async throws -> String {
        let sub = args.subAction ?? "list"
        switch sub {
        case "list":
            var cmd = [ghPath, "issue", "list"]
            if let repo = args.repo { cmd += ["--repo", repo] }
            if let state = args.state { cmd += ["--state", state] }
            if let limit = args.limit { cmd += ["--limit", String(limit)] }
            cmd += ["--json", "number,title,state,labels,assignees,createdAt,updatedAt,url"]
            return try await runCommand(ghPath, cmd)
        case "create":
            guard let repo = args.repo, let title = args.title else {
                throw NSError(domain: "GitHubTool", code: 3, userInfo: [NSLocalizedDescriptionKey: "create requires repo and title"])
            }
            var cmd = [ghPath, "issue", "create", "--repo", repo, "--title", title]
            if let body = args.body { cmd += ["--body", body] }
            if let labels = args.labels { cmd += ["--label", labels] }
            if let assignees = args.assignees { cmd += ["--assignee", assignees] }
            cmd += ["--json", "number,title,url"]
            return try await runCommand(ghPath, cmd)
        case "get":
            guard let repo = args.repo, let number = args.number else {
                throw NSError(domain: "GitHubTool", code: 3, userInfo: [NSLocalizedDescriptionKey: "get requires repo and number"])
            }
            let cmd = [ghPath, "issue", "view", String(number), "--repo", repo, "--json", "number,title,state,body,labels,assignees,createdAt,updatedAt,url,comments"]
            return try await runCommand(ghPath, cmd)
        case "edit":
            guard let repo = args.repo, let number = args.number else {
                throw NSError(domain: "GitHubTool", code: 3, userInfo: [NSLocalizedDescriptionKey: "edit requires repo and number"])
            }
            var cmd = [ghPath, "issue", "edit", String(number), "--repo", repo]
            if let title = args.title { cmd += ["--title", title] }
            if let body = args.body { cmd += ["--body", body] }
            if let labels = args.labels { cmd += ["--add-label", labels] }
            if let assignees = args.assignees { cmd += ["--add-assignee", assignees] }
            cmd += ["--json", "number,title,state,labels,assignees,url"]
            return try await runCommand(ghPath, cmd)
        case "comment":
            guard let repo = args.repo, let number = args.number, let body = args.body else {
                throw NSError(domain: "GitHubTool", code: 3, userInfo: [NSLocalizedDescriptionKey: "comment requires repo, number, and body"])
            }
            let cmd = [ghPath, "issue", "comment", String(number), "--repo", repo, "--body", body]
            return try await runCommand(ghPath, cmd)
        case "close":
            guard let repo = args.repo, let number = args.number else {
                throw NSError(domain: "GitHubTool", code: 3, userInfo: [NSLocalizedDescriptionKey: "close requires repo and number"])
            }
            let cmd = [ghPath, "issue", "close", String(number), "--repo", repo]
            return try await runCommand(ghPath, cmd)
        case "reopen":
            guard let repo = args.repo, let number = args.number else {
                throw NSError(domain: "GitHubTool", code: 3, userInfo: [NSLocalizedDescriptionKey: "reopen requires repo and number"])
            }
            let cmd = [ghPath, "issue", "reopen", String(number), "--repo", repo]
            return try await runCommand(ghPath, cmd)
        default:
            throw NSError(domain: "GitHubTool", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unknown issue sub-action '\(sub)'. Use: list, create, get, edit, comment, close, reopen"])
        }
    }

    // MARK: - PR Commands

    private func runPR(ghPath: String, args: Arguments) async throws -> String {
        let sub = args.subAction ?? "list"
        switch sub {
        case "list":
            var cmd = [ghPath, "pr", "list"]
            if let repo = args.repo { cmd += ["--repo", repo] }
            if let state = args.state { cmd += ["--state", state] }
            if let limit = args.limit { cmd += ["--limit", String(limit)] }
            cmd += ["--json", "number,title,state,headRefName,baseRefName,createdAt,updatedAt,url,isDraft,mergeable"]
            return try await runCommand(ghPath, cmd)
        case "create":
            guard let repo = args.repo, let title = args.title else {
                throw NSError(domain: "GitHubTool", code: 3, userInfo: [NSLocalizedDescriptionKey: "create requires repo and title"])
            }
            var cmd = [ghPath, "pr", "create", "--repo", repo, "--title", title]
            if let body = args.body { cmd += ["--body", body] }
            if let base = args.labels { cmd += ["--base", base] } // reuse labels as base for simplicity
            cmd += ["--json", "number,title,url"]
            return try await runCommand(ghPath, cmd)
        case "get":
            guard let repo = args.repo, let number = args.number else {
                throw NSError(domain: "GitHubTool", code: 3, userInfo: [NSLocalizedDescriptionKey: "get requires repo and number"])
            }
            let cmd = [ghPath, "pr", "view", String(number), "--repo", repo, "--json", "number,title,state,body,headRefName,baseRefName,createdAt,updatedAt,url,isDraft,mergeable,commits,files"]
            return try await runCommand(ghPath, cmd)
        case "edit":
            guard let repo = args.repo, let number = args.number else {
                throw NSError(domain: "GitHubTool", code: 3, userInfo: [NSLocalizedDescriptionKey: "edit requires repo and number"])
            }
            var cmd = [ghPath, "pr", "edit", String(number), "--repo", repo]
            if let title = args.title { cmd += ["--title", title] }
            if let body = args.body { cmd += ["--body", body] }
            cmd += ["--json", "number,title,state,url"]
            return try await runCommand(ghPath, cmd)
        case "merge":
            guard let repo = args.repo, let number = args.number else {
                throw NSError(domain: "GitHubTool", code: 3, userInfo: [NSLocalizedDescriptionKey: "merge requires repo and number"])
            }
            let cmd = [ghPath, "pr", "merge", String(number), "--repo", repo, "--auto", "--delete-branch"]
            return try await runCommand(ghPath, cmd)
        case "checkout":
            guard let repo = args.repo, let number = args.number else {
                throw NSError(domain: "GitHubTool", code: 3, userInfo: [NSLocalizedDescriptionKey: "checkout requires repo and number"])
            }
            let cmd = [ghPath, "pr", "checkout", String(number), "--repo", repo]
            return try await runCommand(ghPath, cmd)
        default:
            throw NSError(domain: "GitHubTool", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unknown PR sub-action '\(sub)'. Use: list, create, get, edit, merge, checkout"])
        }
    }

    // MARK: - Repo Commands

    private func runRepo(ghPath: String, args: Arguments) async throws -> String {
        let sub = args.subAction ?? "list"
        switch sub {
        case "list":
            var cmd = [ghPath, "repo", "list"]
            if let limit = args.limit { cmd += ["--limit", String(limit)] }
            cmd += ["--json", "name,nameWithOwner,description,url,isPrivate,updatedAt"]
            return try await runCommand(ghPath, cmd)
        case "view":
            guard let repo = args.repo else {
                throw NSError(domain: "GitHubTool", code: 3, userInfo: [NSLocalizedDescriptionKey: "view requires repo"])
            }
            let cmd = [ghPath, "repo", "view", repo, "--json", "name,nameWithOwner,description,url,isPrivate,defaultBranchRef,updatedAt,issues,stargazers,forks"]
            return try await runCommand(ghPath, cmd)
        case "create":
            guard let title = args.title else {
                throw NSError(domain: "GitHubTool", code: 3, userInfo: [NSLocalizedDescriptionKey: "create requires title (used as repo name)"])
            }
            var cmd = [ghPath, "repo", "create", title, "--private", "--json", "name,nameWithOwner,url"]
            if let body = args.body { cmd += ["--description", body] }
            return try await runCommand(ghPath, cmd)
        case "clone":
            guard let repo = args.repo else {
                throw NSError(domain: "GitHubTool", code: 3, userInfo: [NSLocalizedDescriptionKey: "clone requires repo"])
            }
            let cmd = [ghPath, "repo", "clone", repo]
            return try await runCommand(ghPath, cmd)
        default:
            throw NSError(domain: "GitHubTool", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unknown repo sub-action '\(sub)'. Use: list, view, create, clone"])
        }
    }

    // MARK: - Workflow Commands

    private func runWorkflow(ghPath: String, args: Arguments) async throws -> String {
        let sub = args.subAction ?? "list"
        guard let repo = args.repo else {
            throw NSError(domain: "GitHubTool", code: 3, userInfo: [NSLocalizedDescriptionKey: "workflow requires repo"])
        }
        switch sub {
        case "list":
            let cmd = [ghPath, "workflow", "list", "--repo", repo, "--json", "id,name,state,path,createdAt,updatedAt"]
            return try await runCommand(ghPath, cmd)
        case "run":
            guard let workflow = args.title else { // reuse title as workflow name/id
                throw NSError(domain: "GitHubTool", code: 3, userInfo: [NSLocalizedDescriptionKey: "run requires workflow name (title field)"])
            }
            var cmd = [ghPath, "workflow", "run", workflow, "--repo", repo]
            if let body = args.body { // reuse body as ref
                cmd += ["--ref", body]
            }
            return try await runCommand(ghPath, cmd)
        case "view":
            guard let workflow = args.title else {
                throw NSError(domain: "GitHubTool", code: 3, userInfo: [NSLocalizedDescriptionKey: "view requires workflow name (title field)"])
            }
            let cmd = [ghPath, "run", "list", "--repo", repo, "--workflow", workflow, "--json", "databaseId,name,status,conclusion,headBranch,createdAt,updatedAt,url"]
            return try await runCommand(ghPath, cmd)
        default:
            throw NSError(domain: "GitHubTool", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unknown workflow sub-action '\(sub)'. Use: list, run, view"])
        }
    }

    // MARK: - Auth Commands

    private func runAuth(ghPath: String, args: Arguments) async throws -> String {
        let sub = args.subAction ?? "status"
        switch sub {
        case "status":
            let cmd = [ghPath, "auth", "status"]
            return try await runCommand(ghPath, cmd)
        case "login":
            var cmd = [ghPath, "auth", "login"]
            if args.body != nil { cmd += ["--with-token"] } // body would be token via stdin - simplified
            return try await runCommand(ghPath, cmd)
        case "token":
            let cmd = [ghPath, "auth", "token"]
            return try await runCommand(ghPath, cmd)
        default:
            throw NSError(domain: "GitHubTool", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unknown auth sub-action '\(sub)'. Use: status, login, token"])
        }
    }

    // MARK: - Raw API

    private func runAPI(ghPath: String, args: Arguments) async throws -> String {
        guard let endpoint = args.endpoint else {
            throw NSError(domain: "GitHubTool", code: 3, userInfo: [NSLocalizedDescriptionKey: "api requires endpoint"])
        }
        let method = args.method ?? "GET"
        let cmd = [ghPath, "api", "--method", method, endpoint]
        // Note: jsonBody not supported in this simple wrapper
        return try await runCommand(ghPath, cmd)
    }
}
