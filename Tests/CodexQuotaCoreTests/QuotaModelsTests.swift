import XCTest
@testable import CodexQuotaCore

final class QuotaModelsTests: XCTestCase {
    func testDecodesCodexRateLimitsAndMapsBothWindows() throws {
        let json = #"""
        {
          "rateLimits": {
            "limitId": "codex",
            "primary": { "usedPercent": 44, "windowDurationMins": 300, "resetsAt": 1788847385 },
            "secondary": { "usedPercent": 82, "windowDurationMins": 10080, "resetsAt": 1789093240 },
            "planType": "plus",
            "rateLimitReachedType": null
          }
        }
        """#.data(using: .utf8)!

        let response = try JSONDecoder().decode(CodexRateLimitsResponse.self, from: json)
        let fetchedAt = Date(timeIntervalSince1970: 100)
        let snapshot = try CodexQuotaSnapshot(response: response, fetchedAt: fetchedAt)

        XCTAssertEqual(snapshot.fiveHour.usedPercent, 44)
        XCTAssertEqual(snapshot.fiveHour.remainingPercent, 56)
        XCTAssertEqual(snapshot.weekly.usedPercent, 82)
        XCTAssertEqual(snapshot.weekly.remainingPercent, 18)
        XCTAssertEqual(snapshot.planType, "plus")
        XCTAssertEqual(snapshot.fetchedAt, fetchedAt)
    }

    func testUsagePercentIsClampedForDisplay() {
        let over = CodexRateLimitWindow(usedPercent: 140, windowDurationMins: 300, resetsAt: nil)
        let under = CodexRateLimitWindow(usedPercent: -4, windowDurationMins: 300, resetsAt: nil)

        XCTAssertEqual(over.clampedUsedPercent, 100)
        XCTAssertEqual(over.remainingPercent, 0)
        XCTAssertEqual(under.clampedUsedPercent, 0)
        XCTAssertEqual(under.remainingPercent, 100)
    }

    func testSparseRateLimitUpdateMergesIntoTheLatestSnapshot() {
        let original = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 20, windowDurationMins: 300, resetsAt: 100),
            secondary: CodexRateLimitWindow(usedPercent: 40, windowDurationMins: 10080, resetsAt: 200),
            planType: "plus",
            rateLimitReachedType: nil
        )
        let update = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 35, windowDurationMins: 300, resetsAt: 110),
            secondary: nil,
            planType: nil,
            rateLimitReachedType: "rate_limit_reached"
        )

        let merged = original.merged(with: update)

        XCTAssertEqual(merged.primary?.usedPercent, 35)
        XCTAssertEqual(merged.primary?.resetsAt, 110)
        XCTAssertEqual(merged.secondary?.usedPercent, 40)
        XCTAssertEqual(merged.planType, "plus")
        XCTAssertEqual(merged.rateLimitReachedType, "rate_limit_reached")
    }
}
