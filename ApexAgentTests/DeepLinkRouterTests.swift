import Testing
import Foundation
@testable import ApexAgentCore

@Suite("DeepLinkRouterTests", .serialized)
struct DeepLinkRouterTests {

    @Test func parsesAllValidDeepLinkRoutes() throws {
        let chatURL = try #require(URL(string: "apexagent://chat/conv-123"))
        #expect(DeepLinkRouter.parse(chatURL) == .success(.chat(id: "conv-123")))

        let routineURL = try #require(URL(string: "apexagent://routine/daily-triage"))
        #expect(DeepLinkRouter.parse(routineURL) == .success(.routine(id: "daily-triage")))

        let skillURL = try #require(URL(string: "apexagent://skill/git-audit"))
        #expect(DeepLinkRouter.parse(skillURL) == .success(.skill(name: "git-audit")))

        let diagnosticsURL = try #require(URL(string: "apexagent://diagnostics"))
        #expect(DeepLinkRouter.parse(diagnosticsURL) == .success(.diagnostics))

        let settingsURL = try #require(URL(string: "apexagent://settings"))
        #expect(DeepLinkRouter.parse(settingsURL) == .success(.settings))

        let commandURL = try #require(URL(string: "apexagent://command/compact"))
        #expect(DeepLinkRouter.parse(commandURL) == .success(.command(name: "compact")))
    }

    @Test func rejectsMalformedAndUnknownDeepLinksWithStructuredErrors() throws {
        let httpsURL = try #require(URL(string: "https://example.com/chat/1"))
        #expect(DeepLinkRouter.parse(httpsURL) == .failure(.unsupportedScheme("https")))

        let emptyRouteURL = try #require(URL(string: "apexagent://"))
        #expect(DeepLinkRouter.parse(emptyRouteURL) == .failure(.missingRoute))

        let unknownRouteURL = try #require(URL(string: "apexagent://unknown/target"))
        #expect(DeepLinkRouter.parse(unknownRouteURL) == .failure(.unknownRoute("unknown")))

        for route in ["chat", "routine", "skill", "command"] {
            let missingIdURL = try #require(URL(string: "apexagent://\(route)"))
            #expect(DeepLinkRouter.parse(missingIdURL) == .failure(.missingIdentifier(route: route)))

            let slashOnlyURL = try #require(URL(string: "apexagent://\(route)/"))
            #expect(DeepLinkRouter.parse(slashOnlyURL) == .failure(.missingIdentifier(route: route)))
        }
    }

    @Test func urlBuilderRoundTripsAllDestinations() {
        let destinations: [DeepLinkDestination] = [
            .chat(id: "abc-999"),
            .routine(id: "nightly-build"),
            .skill(name: "swift-concurrency"),
            .diagnostics,
            .settings,
            .command(name: "clear")
        ]
        for destination in destinations {
            let built = DeepLinkRouter.url(for: destination)
            #expect(DeepLinkRouter.parse(built) == .success(destination))
        }
    }

    @Test @MainActor func navigationStateAppliesEachDestinationAndCapturesErrors() throws {
        let nav = DeepLinkNavigationState()

        _ = nav.handle(try #require(URL(string: "apexagent://chat/session-42")))
        #expect(nav.activeChatId == "session-42")
        #expect(nav.lastDestination == .chat(id: "session-42"))
        #expect(nav.lastError == nil)

        _ = nav.handle(try #require(URL(string: "apexagent://routine/routine-7")))
        #expect(nav.selectedRoutineId == "routine-7")

        _ = nav.handle(try #require(URL(string: "apexagent://skill/code-review")))
        #expect(nav.selectedSkillName == "code-review")

        _ = nav.handle(try #require(URL(string: "apexagent://diagnostics")))
        #expect(nav.showDiagnostics == true)

        _ = nav.handle(try #require(URL(string: "apexagent://settings")))
        #expect(nav.showSettings == true)

        _ = nav.handle(try #require(URL(string: "apexagent://command/audit")))
        #expect(nav.lastExecutedCommand == "audit")

        let badResult = nav.handle(try #require(URL(string: "apexagent://bogus")))
        #expect(badResult == .failure(.unknownRoute("bogus")))
        #expect(nav.lastError == .unknownRoute("bogus"))

        nav.reset()
        #expect(nav.activeChatId == nil)
        #expect(nav.showDiagnostics == false)
        #expect(nav.showSettings == false)
        #expect(nav.lastError == nil)
    }
}
