import Foundation
import FoundationModels
import MapKit
import CoreLocation

// MARK: - Directions Tool (MapKit MKDirections)

struct DirectionsTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "get_directions"
    let description = """
    Calculates routes, driving/walking times, distances, and turn-by-turn navigation steps between two locations \
    using Apple MapKit Directions.
    """

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "Starting location or address (e.g. 'Anoka, MN', 'Minneapolis-Saint Paul Airport')")
        var from: String

        @Guide(description: "Destination location or address (e.g. 'Mall of America', 'Duluth, MN')")
        var to: String

        @Guide(description: "Transportation mode: 'driving' (automobile), 'walking', or 'transit'. Defaults to 'driving'.")
        var transportType: String?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            // 1. Geocode Origin and Destination
            guard let originPlacemark = await resolvePlacemark(for: arguments.from) else {
                return "❌ Unable to resolve starting address: \"\(arguments.from)\""
            }
            guard let destPlacemark = await resolvePlacemark(for: arguments.to) else {
                return "❌ Unable to resolve destination address: \"\(arguments.to)\""
            }

            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(placemark: originPlacemark))
            request.destination = MKMapItem(placemark: MKPlacemark(placemark: destPlacemark))

            let mode = (arguments.transportType ?? "driving").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            switch mode {
            case "walking", "walk":
                request.transportType = .walking
            case "transit":
                request.transportType = .transit
            default:
                request.transportType = .automobile
            }

            let directions = MKDirections(request: request)
            do {
                let response = try await directions.calculate()
                guard let primaryRoute = response.routes.first else {
                    return "⚠️ No route found between \"\(arguments.from)\" and \"\(arguments.to)\"."
                }

                let distanceMiles = primaryRoute.distance / 1609.344
                let travelMinutes = Int(primaryRoute.expectedTravelTime / 60)
                let hours = travelMinutes / 60
                let mins = travelMinutes % 60
                let timeString = hours > 0 ? "\(hours) hr \(mins) min" : "\(mins) min"

                var output = """
                🗺️ Directions from **\(arguments.from)** to **\(arguments.to)**:
                • Mode: \(mode.capitalized)
                • Distance: \(String(format: "%.1f miles", distanceMiles))
                • Estimated Travel Time: \(timeString)
                
                📋 Step-by-Step Navigation:
                """
                for (index, step) in primaryRoute.steps.enumerated() {
                    if step.instructions.isEmpty { continue }
                    let stepMiles = step.distance / 1609.344
                    let distanceNote = stepMiles >= 0.1 ? String(format: " (%.1f mi)", stepMiles) : ""
                    output += "\(index + 1). \(step.instructions)\(distanceNote)\n"
                }

                return output.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                return "❌ Routing calculation failed: \(error.localizedDescription)"
            }
        }
    }

    private func resolvePlacemark(for query: String) async -> CLPlacemark? {
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.geocodeAddressString(query)
            return placemarks.first
        } catch {
            return nil
        }
    }
}
