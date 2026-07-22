import ApexAgentCore

// ApexAgentApp (the App) lives in ApexAgentCore. This thin executable target is
// the link entry point: it calls ApexAgentApp.main() explicitly. ApexAgentApp is
// NOT marked @main, so there is exactly one `_main` symbol (here). This avoids
// `@testable import ApexAgentCore` in the executable, which broke
// `swift build -c release`.
ApexAgentApp.main()
