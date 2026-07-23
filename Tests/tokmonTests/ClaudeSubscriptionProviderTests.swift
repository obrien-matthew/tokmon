import Foundation
import XCTest
@testable import tokmon

final class ClaudeSubscriptionProviderTests: XCTestCase {
    func testExtraCreditsShowsZeroUsageAndLimit() throws {
        let usage = try ClaudeSubscriptionProvider.makeDecoder().decode(
            ClaudeSubscriptionProvider.OAuthUsage.self,
            from: Data(#"{"spend":{"used":{"amount_minor":0,"exponent":2},"limit":{"amount_minor":2000,"exponent":2}}}"#.utf8)
        )

        let metric = try XCTUnwrap(ClaudeSubscriptionProvider.metrics(from: usage).last)

        XCTAssertEqual(metric.id, "extra-credits")
        XCTAssertEqual(metric.used, 0)
        XCTAssertEqual(metric.limit, 20)
        XCTAssertEqual(MetricGaugeRow.valueText(for: metric), "$0.00 / $20.00")
    }

    func testExtraCreditsWithoutLimitStillShowsUsage() throws {
        let usage = try ClaudeSubscriptionProvider.makeDecoder().decode(
            ClaudeSubscriptionProvider.OAuthUsage.self,
            from: Data(#"{"spend":{"used":{"amount_minor":1234,"exponent":2}}}"#.utf8)
        )

        let metric = try XCTUnwrap(ClaudeSubscriptionProvider.metrics(from: usage).last)

        XCTAssertEqual(metric.used, 12.34)
        XCTAssertNil(metric.limit)
        XCTAssertEqual(MetricGaugeRow.valueText(for: metric), "$12.34")
    }
}
