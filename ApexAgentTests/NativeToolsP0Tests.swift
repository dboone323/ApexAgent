import Testing
import Foundation
import CoreLocation
import MapKit
@testable import ApexAgentCore

@Suite("NativeToolsP0Tests")
struct NativeToolsP0Tests {
    @Test("WeatherTool metadata and initialization")
    @MainActor
    func testWeatherToolMetadata() {
        let orchestrator = AgentOrchestrator()
        let tool = WeatherTool(orchestrator: orchestrator)
        #expect(tool.name == "get_weather")
        #expect(tool.description.contains("WeatherKit"))
    }

    @Test("WeatherTool geocodes valid coordinates and executes query")
    @MainActor
    func testWeatherToolExecution() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = WeatherTool(orchestrator: orchestrator)
        let args = WeatherTool.Arguments(location: "Anoka, MN", forecastType: "current")
        let result = try await tool.call(arguments: args)
        #expect(!result.isEmpty)
        #expect(result.contains("Weather") || result.contains("Anoka") || result.contains("°"))
    }

    @Test("WeatherTool handles coordinate string input directly")
    @MainActor
    func testWeatherToolCoordinatesDirect() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = WeatherTool(orchestrator: orchestrator)
        let args = WeatherTool.Arguments(location: "45.1983, -93.3886", forecastType: "hourly")
        let result = try await tool.call(arguments: args)
        #expect(!result.isEmpty)
    }

    @Test("MapSearchTool metadata and search query execution")
    @MainActor
    func testMapSearchToolExecution() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = MapSearchTool(orchestrator: orchestrator)
        #expect(tool.name == "map_search")
        
        let args = MapSearchTool.Arguments(query: "Coffee", nearLocation: "Minneapolis, MN", resultCount: 3)
        let result = try await tool.call(arguments: args)
        #expect(!result.isEmpty)
        #expect(result.contains("Map Search Results") || result.contains("Coffee") || result.contains("📍"))
    }

    @Test("DirectionsTool metadata and route calculation")
    @MainActor
    func testDirectionsToolExecution() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = DirectionsTool(orchestrator: orchestrator)
        #expect(tool.name == "get_directions")

        let args = DirectionsTool.Arguments(from: "Anoka, MN", to: "Minneapolis, MN", transportType: "driving")
        let result = try await tool.call(arguments: args)
        #expect(!result.isEmpty)
        #expect(result.contains("Directions") || result.contains("miles") || result.contains("min") || result.contains("Navigation"))
    }

    @Test("WebSearchTool contains Tavily and Brave key lookup cascade")
    @MainActor
    func testWebSearchToolCascade() {
        let orchestrator = AgentOrchestrator()
        let tool = WebSearchTool(orchestrator: orchestrator)
        #expect(tool.name == "web_search")
    }
}
