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

    func testCodexVersionNormalizesTagsAndComparesSemverParts() {
        XCTAssertEqual(CodexVersion("v0.1.1"), CodexVersion("0.1.1"))
        XCTAssertTrue(CodexVersion("v0.1.2")! > CodexVersion("v0.1.1")!)
        XCTAssertTrue(CodexVersion("1.0")! > CodexVersion("0.9.9")!)
        XCTAssertNil(CodexVersion("latest"))
    }

    func testReleaseSelectsTheMacOSUniversalZipAsset() throws {
        let json = #"""
        {
          "tag_name": "v0.1.2",
          "name": "CodexQuotaMenu v0.1.2",
          "html_url": "https://github.com/hy123-pixel/CodexQuotaMenu/releases/tag/v0.1.2",
          "published_at": "2026-10-19T10:00:00Z",
          "assets": [
            { "name": "SHA256SUMS.txt", "browser_download_url": "https://example.com/SHA256SUMS.txt", "digest": null },
            { "name": "CodexQuotaMenu-macOS-universal-v0.1.2.zip", "browser_download_url": "https://example.com/CodexQuotaMenu.zip", "digest": "sha256:abc" }
          ]
        }
        """#.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let release = try decoder.decode(CodexRelease.self, from: json)

        XCTAssertEqual(release.version, CodexVersion("0.1.2"))
        XCTAssertEqual(release.macOSUniversalAsset?.name, "CodexQuotaMenu-macOS-universal-v0.1.2.zip")
    }
}
