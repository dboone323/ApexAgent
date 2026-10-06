import XCTest
@testable import ApexAgentCore

final class AgentEvaluationRatingTests: XCTestCase {

    func testScorecardWeightedAggregationAndGrading() {
        let engine = AgentEvaluationRatingEngine()

        let scorecard = engine.evaluateSystem(
            computerUseChecks: (passed: 10, total: 10, notes: "All OSWorld computer use actions executed"),
            visualChecks: (passed: 8, total: 8, notes: "Vision OCR & highlight overlay 100% verified"),
            toolChecks: (passed: 15, total: 15, notes: "Tool allowlists & schema validation clean"),
            safetyChecks: (passed: 12, total: 12, notes: "Destructive guards and approval gates passing"),
            playbookChecks: (passed: 6, total: 6, notes: "Multi-bot playbooks and chief delegation passing"),
            perfChecks: (passed: 5, total: 5, notes: "Sub-second execution and lean RAM footprint")
        )

        XCTAssertEqual(scorecard.overallScore, 100.0, accuracy: 0.001)
        XCTAssertEqual(scorecard.grade, .aPlus)
        XCTAssertEqual(scorecard.dimensionScores.count, 6)

        let md = scorecard.generateMarkdownReport()
        XCTAssertTrue(md.contains("# 🏆 ApexAgent Comprehensive Evaluation & Rating Scorecard"))
        XCTAssertTrue(md.contains("A+ (Industry Leading)"))
        XCTAssertTrue(md.contains("OS & Computer Use Automation"))
        XCTAssertTrue(md.contains("100.0%"))
    }

    func testPartialScorecardAndRecommendations() {
        let engine = AgentEvaluationRatingEngine()

        let scorecard = engine.evaluateSystem(
            computerUseChecks: (passed: 7, total: 10, notes: "3 click coordinates out of bounds"),
            visualChecks: (passed: 6, total: 8, notes: "2 low-contrast text elements missed"),
            toolChecks: (passed: 15, total: 15, notes: "Tool routing clean"),
            safetyChecks: (passed: 12, total: 12, notes: "Security gates active"),
            playbookChecks: (passed: 6, total: 6, notes: "Playbooks verified"),
            perfChecks: (passed: 4, total: 5, notes: "1 slow inference turn")
        )

        // Overall score should be in the B/A range
        XCTAssertTrue(scorecard.overallScore > 75.0 && scorecard.overallScore < 95.0)
        XCTAssertFalse(scorecard.recommendations.isEmpty)
        XCTAssertTrue(scorecard.recommendations.first?.contains("Improve") ?? false)
    }
}

// MARK: - Markdown projection for the scorecard

final class ScorecardMarkdownTests: XCTestCase {
    func testScorecardMarkdown() throws {
        let engine = AgentEvaluationRatingEngine()
        let card = engine.quickAudit()
        let md = card.formatAsMarkdown()
        XCTAssertTrue(md.contains("Overall"))
        XCTAssertTrue(md.contains("OS & Computer Use Automation"))
    }
}

// MARK: - Input validation hardening for dimension scores

final class DimensionScoreValidationTests: XCTestCase {
    func testDimensionScoreValidated() {
        let s = DimensionScore.validated(dimension: .toolCalling, passedChecks: 99, totalChecks: 5, notes: "clamped")
        XCTAssertEqual(s.passedChecks, 5)
        XCTAssertEqual(s.totalChecks, 5)
        let s2 = DimensionScore.validated(dimension: .toolCalling, passedChecks: -3, totalChecks: 5)
        XCTAssertEqual(s2.passedChecks, 0)
    }
}
