import Foundation
import FoundationModels
import NaturalLanguage

// MARK: - Entity Extraction & NLP Tool (Apple NaturalLanguage Framework)

struct EntityExtractTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "extract_entities"
    let description = """
    Extracts named entities (people, places, locations, organizations), sentiment polarity, and dominant language from text \
    using Apple's on-device NaturalLanguage framework.
    """

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "The input text, document excerpt, or query to analyze")
        var text: String

        @Guide(description: "Optional filter for entity types to extract: 'people', 'places', 'organizations', 'sentiment', or 'all'. Defaults to 'all'.")
        var filter: String?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            let text = arguments.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return "❌ Error: Text to analyze cannot be empty."
            }

            let requestedFilter = (arguments.filter ?? "all").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

            // 1. Language Detection
            let langRecognizer = NLLanguageRecognizer()
            langRecognizer.processString(text)
            let dominantLang = langRecognizer.dominantLanguage
            let langName = dominantLang.flatMap { Locale.current.localizedString(forLanguageCode: $0.rawValue) } ?? "Unknown"

            // 2. Named Entity Tagging
            let tagger = NLTagger(tagSchemes: [.nameType, .sentimentScore])
            tagger.string = text

            var people: Set<String> = []
            var places: Set<String> = []
            var organizations: Set<String> = []

            tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, tokenRange in
                guard let tag = tag else { return true }
                let entity = String(text[tokenRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !entity.isEmpty, entity.count > 1 else { return true }

                switch tag {
                case .personalName:
                    people.insert(entity)
                case .placeName:
                    places.insert(entity)
                case .organizationName:
                    organizations.insert(entity)
                default:
                    break
                }
                return true
            }

            // 3. Sentiment Analysis
            var sentimentScore: Double = 0.0
            let (sentimentTag, _) = tagger.tag(at: text.startIndex, unit: .paragraph, scheme: .sentimentScore)
            if let scoreStr = sentimentTag?.rawValue, let score = Double(scoreStr) {
                sentimentScore = score
            }

            let sentimentPolarity: String
            if sentimentScore > 0.25 {
                sentimentPolarity = "🟢 Positive (Score: \(String(format: "%.2f", sentimentScore)))"
            } else if sentimentScore < -0.25 {
                sentimentPolarity = "🔴 Negative (Score: \(String(format: "%.2f", sentimentScore)))"
            } else {
                sentimentPolarity = "⚪ Neutral (Score: \(String(format: "%.2f", sentimentScore)))"
            }

            // 4. Format Output
            var output = "🧠 **Natural Language Analysis Report**:\n"
            output += "• **Language**: \(langName) (`\(dominantLang?.rawValue ?? "und")`)\n"
            output += "• **Sentiment**: \(sentimentPolarity)\n\n"

            if requestedFilter == "all" || requestedFilter.contains("people") || requestedFilter.contains("person") {
                output += "👤 **People & Names (\(people.count))**:\n"
                if people.isEmpty {
                    output += "  (None detected)\n"
                } else {
                    for person in people.sorted() {
                        output += "  • \(person)\n"
                    }
                }
                output += "\n"
            }

            if requestedFilter == "all" || requestedFilter.contains("place") || requestedFilter.contains("location") {
                output += "📍 **Places & Locations (\(places.count))**:\n"
                if places.isEmpty {
                    output += "  (None detected)\n"
                } else {
                    for place in places.sorted() {
                        output += "  • \(place)\n"
                    }
                }
                output += "\n"
            }

            if requestedFilter == "all" || requestedFilter.contains("org") || requestedFilter.contains("company") {
                output += "🏢 **Organizations & Brands (\(organizations.count))**:\n"
                if organizations.isEmpty {
                    output += "  (None detected)\n"
                } else {
                    for org in organizations.sorted() {
                        output += "  • \(org)\n"
                    }
                }
            }

            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
