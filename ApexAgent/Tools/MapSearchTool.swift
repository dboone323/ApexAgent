import Foundation
import FoundationModels
import MapKit
import CoreLocation

// MARK: - Map Search Tool (MapKit MKLocalSearch)

struct MapSearchTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "map_search"
    let description = """
    Searches for places, businesses, landmarks, and addresses (e.g. "coffee shops in Minneapolis", "Apple Store", "libraries near Anoka") \
    using Apple MapKit Local Search. Returns structured names, addresses, phone numbers, URLs, and coordinates.
    """

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "The search query for places, businesses, or landmarks (e.g. 'Italian restaurants', 'gas station', 'Target')")
        var query: String

        @Guide(description: "Optional city, address, or coordinate to center the search around (e.g. 'Anoka, MN', 'Downtown Minneapolis')")
        var nearLocation: String?

        @Guide(description: "Number of results to return (1 to 20, default: 5)")
        var resultCount: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            let maxCount = min(max(arguments.resultCount ?? 5, 1), 20)
            let searchRequest = MKLocalSearch.Request()
            searchRequest.naturalLanguageQuery = arguments.query
            searchRequest.resultTypes = [.pointOfInterest, .address]

            // If a center location was provided, geocode it and establish a search region
            if let near = arguments.nearLocation, !near.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let location = await resolveLocation(for: near) {
                    let span = MKCoordinateSpan(latitudeDelta: 0.15, longitudeDelta: 0.15)
                    searchRequest.region = MKCoordinateRegion(center: location.coordinate, span: span)
                }
            }

            let search = MKLocalSearch(request: searchRequest)
            do {
                let response = try await search.start()
                let items = Array(response.mapItems.prefix(maxCount))
                if items.isEmpty {
                    return "📍 No map results found for query: \"\(arguments.query)\""
                }

                var output = "📍 Map Search Results for \"\(arguments.query)\":\n\n"
                for (index, item) in items.enumerated() {
                    output += "\(index + 1). **\(item.name ?? "Unknown Location")**\n"
                    if let category = item.pointOfInterestCategory?.rawValue {
                        let cleanCategory = category.replacingOccurrences(of: "MKPOICategory", with: "")
                        output += "   • Category: \(cleanCategory)\n"
                    }
                    
                    if let phone = item.phoneNumber, !phone.isEmpty {
                        output += "   • Phone: \(phone)\n"
                    }
                    if let url = item.url {
                        output += "   • Website: \(url.absoluteString)\n"
                    }
                    let location = item.location
                    output += String(format: "   • Coordinates: %.5f, %.5f\n\n", location.coordinate.latitude, location.coordinate.longitude)
                }
                return output.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                return "❌ Map search failed for \"\(arguments.query)\": \(error.localizedDescription)"
            }
        }
    }

    private func resolveLocation(for query: String) async -> CLLocation? {
        let searchRequest = MKLocalSearch.Request()
        searchRequest.naturalLanguageQuery = query
        searchRequest.resultTypes = [.address, .pointOfInterest]
        let search = MKLocalSearch(request: searchRequest)
        do {
            let response = try await search.start()
            return response.mapItems.first?.location
        } catch {
            return nil
        }
    }
}
