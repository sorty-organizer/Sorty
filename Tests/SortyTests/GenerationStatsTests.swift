import XCTest
@testable import SortyLib
@testable import SortyCore

final class GenerationStatsTests: XCTestCase {

    func testResponseAndContextTokenAccessors() {
        let stats = GenerationStats(
            duration: 4.2,
            tps: 120,
            ttft: 0.8,
            totalTokens: 900,
            model: "gpt-5.4",
            promptTokens: 1100
        )

        XCTAssertEqual(stats.responseTokens, 900)
        XCTAssertEqual(stats.totalContextTokens, 2000)
    }

    func testTotalContextTokensNilWhenPromptTokensMissing() {
        let stats = GenerationStats(
            duration: 1,
            tps: 10,
            ttft: 0.2,
            totalTokens: 150,
            model: "gpt-5.4"
        )

        XCTAssertNil(stats.totalContextTokens)
    }

    func testEstimatedTimeSavedReflectsFullManualOrganizationWork() {
        let stats = GenerationStats(
            duration: 1,
            tps: 10,
            ttft: 0.2,
            totalTokens: 150,
            model: "gpt-5.4",
            filesScanned: 12
        )

        XCTAssertEqual(stats.estimatedTimeSaved, 240)
        XCTAssertEqual(GenerationStats.estimatedTimeSaved(forFileCount: 3), 60)
        XCTAssertEqual(GenerationStats.estimatedTimeSaved(forFileCount: -1), 0)
    }

    func testHasBillableCostReflectsComputedCost() {
        let zeroCost = GenerationStats(
            duration: 1,
            tps: 10,
            ttft: 0.2,
            totalTokens: 100,
            model: "gpt-5.4",
            estimatedCost: 0
        )
        XCTAssertFalse(zeroCost.hasBillableCost)

        let positiveCost = GenerationStats(
            duration: 1,
            tps: 10,
            ttft: 0.2,
            totalTokens: 100,
            model: "gpt-5.4",
            estimatedCost: Decimal(string: "0.02")
        )
        XCTAssertTrue(positiveCost.hasBillableCost)
    }

    func testCompactModelNameTrimsAndUsesPrefixBeforeDot() {
        let stats = GenerationStats(
            duration: 1,
            tps: 10,
            ttft: 0.2,
            totalTokens: 100,
            model: "  gpt-5.4.high  "
        )

        XCTAssertEqual(stats.compactModelName, "gpt-5")
    }

    func testFormatDurationAcrossRanges() {
        XCTAssertEqual(GenerationStats.formatDuration(-2), "0.0s")
        XCTAssertEqual(GenerationStats.formatDuration(9.34), "9.3s")
        XCTAssertEqual(GenerationStats.formatDuration(14.7), "15s")
        XCTAssertEqual(GenerationStats.formatDuration(125), "2m 5s")
        XCTAssertEqual(GenerationStats.formatDuration(3660), "1h 1m")
    }

    func testFormatCostUsesExpectedPrecisionBands() {
        let small = GenerationStats.formatCost(Decimal(string: "0.0094") ?? 0)
        let standard = GenerationStats.formatCost(Decimal(string: "1.23") ?? 0)

        let decimalSeparator = Locale.current.decimalSeparator ?? "."
        if let smallFractionPart = small.components(separatedBy: decimalSeparator).last {
            XCTAssertGreaterThanOrEqual(smallFractionPart.count, 4)
        } else {
            XCTFail("Expected formatted small cost to include a fractional part")
        }

        if let standardFractionPart = standard.components(separatedBy: decimalSeparator).last {
            XCTAssertGreaterThanOrEqual(standardFractionPart.count, 2)
        } else {
            XCTFail("Expected formatted standard cost to include a fractional part")
        }
    }
}
