import Foundation
import FoundationModels
import WeatherKit
import CoreLocation
import MapKit

// MARK: - Weather Tool (WeatherKit + CoreLocation + Fallback)

struct WeatherTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "get_weather"
    let description = """
    Retrieves real-time weather information and forecasts for a specified location (e.g. "Anoka, MN", "London, UK", or "45.1983,-93.3886") \
    using Apple WeatherKit and CoreLocation geocoding. \
    Supports current conditions, hourly forecasts, 10-day daily forecasts, and severe weather alerts.
    """

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "The city, address, or geographic coordinate (e.g., 'Anoka, MN', 'San Francisco', '45.19,-93.38')")
        var location: String

        @Guide(description: "Type of forecast to return: 'current', 'hourly', 'daily', or 'alerts'. Defaults to 'current'.")
        var forecastType: String?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            let requestedType = (arguments.forecastType ?? "current").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            
            // 1. Resolve Location Coordinates
            guard let clLocation = await resolveCoordinates(for: arguments.location) else {
                return "❌ Unable to resolve geographic coordinates for location: \"\(arguments.location)\". Please check the spelling or specify coordinates."
            }

            // 2. Fetch from WeatherKit
            do {
                let weather = try await WeatherService.shared.weather(for: clLocation)
                return formatWeatherResponse(weather: weather, locationName: arguments.location, type: requestedType)
            } catch {
                // Fallback to wttr.in if WeatherKit requires active developer entitlement/connection
                if let fallbackResult = await fetchWttrInFallback(query: arguments.location) {
                    return "🌤️ Weather for \"\(arguments.location)\" (Online Fallback):\n\n\(fallbackResult)"
                }
                return "⚠️ WeatherKit query failed for \(arguments.location): \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Geocoding

    private func resolveCoordinates(for query: String) async -> CLLocation? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Check for direct coordinate pair (lat, lon)
        let parts = trimmed.components(separatedBy: ",")
        if parts.count == 2,
           let lat = Double(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
           let lon = Double(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) {
            return CLLocation(latitude: lat, longitude: lon)
        }

        let searchRequest = MKLocalSearch.Request()
        searchRequest.naturalLanguageQuery = trimmed
        searchRequest.resultTypes = [.address, .pointOfInterest]
        let search = MKLocalSearch(request: searchRequest)
        do {
            let response = try await search.start()
            return response.mapItems.first?.location
        } catch {
            return nil
        }
    }

    // MARK: - WeatherKit Formatting

    private func formatWeatherResponse(weather: Weather, locationName: String, type: String) -> String {
        let current = weather.currentWeather
        let tempFormatted = String(format: "%.1f°F (%.1f°C)", current.temperature.converted(to: .fahrenheit).value, current.temperature.converted(to: .celsius).value)
        let feelsLike = String(format: "%.1f°F", current.apparentTemperature.converted(to: .fahrenheit).value)
        let windSpeed = String(format: "%.1f mph", current.wind.speed.converted(to: .milesPerHour).value)
        let humidity = String(format: "%.0f%%", current.humidity * 100)
        let uv = "\(current.uvIndex.value) (\(current.uvIndex.category.description))"

        var output = """
        🌤️ Current Weather in \(locationName):
        • Condition: \(current.condition.description)
        • Temperature: \(tempFormatted)
        • Feels Like: \(feelsLike)
        • Humidity: \(humidity)
        • Wind: \(windSpeed) \(current.wind.compassDirection.abbreviation)
        • UV Index: \(uv)
        • Visibility: \(String(format: "%.1f miles", current.visibility.converted(to: .miles).value))
        
        """

        if type == "hourly" || type == "all" {
            output += "\n⏱️ Next 12 Hours Forecast:\n"
            let formatter = DateFormatter()
            formatter.dateFormat = "h a"
            for hour in weather.hourlyForecast.prefix(12) {
                let timeStr = formatter.string(from: hour.date)
                let hourTemp = String(format: "%.0f°F", hour.temperature.converted(to: .fahrenheit).value)
                let precip = String(format: "%.0f%%", hour.precipitationChance * 100)
                output += "• \(timeStr): \(hourTemp), \(hour.condition.description) (Precip: \(precip))\n"
            }
        }

        if type == "daily" || type == "all" {
            output += "\n📅 7-Day Forecast:\n"
            let dayFormatter = DateFormatter()
            dayFormatter.dateFormat = "EEE, MMM d"
            for day in weather.dailyForecast.prefix(7) {
                let dateStr = dayFormatter.string(from: day.date)
                let high = String(format: "%.0f°F", day.highTemperature.converted(to: .fahrenheit).value)
                let low = String(format: "%.0f°F", day.lowTemperature.converted(to: .fahrenheit).value)
                output += "• \(dateStr): High \(high) / Low \(low) — \(day.condition.description)\n"
            }
        }

        if let alerts = weather.weatherAlerts, !alerts.isEmpty {
            output += "\n🚨 Weather Alerts:\n"
            for alert in alerts {
                output += "⚠️ \(alert.summary) (Severity: \(alert.severity))\n"
            }
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Fallback

    private func fetchWttrInFallback(query: String) async -> String? {
        let location = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://wttr.in/\(location)?format=4") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("curl/8.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let text = String(data: data, encoding: .utf8), !text.isEmpty else {
                return nil
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}
