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

    // MARK: - Credential candidate resolution

    private let now = Date(timeIntervalSince1970: 1_786_710_000)

    private func keychainJSON(token: String = "sk-keychain", expiresAtMS: Double?) -> String {
        let expiry = expiresAtMS.map { ",\"expiresAt\":\($0)" } ?? ""
        return #"{"claudeAiOauth":{"accessToken":"\#(token)"\#(expiry)}}"#
    }

    private func ompCredential(token: String = "sk-omp", expiresAt: Date?) -> OmpOAuthCredential {
        OmpOAuthCredential(accessToken: token, accountId: "acct", expiresAt: expiresAt)
    }

    func testKeychainFirstThenOmp() {
        let resolution = ClaudeSubscriptionProvider.resolveTokens(
            keychainJSON: keychainJSON(expiresAtMS: (now.timeIntervalSince1970 + 3600) * 1000),
            omp: ompCredential(expiresAt: now.addingTimeInterval(3600)),
            now: now
        )
        XCTAssertEqual(resolution.tokens, ["sk-keychain", "sk-omp"])
        XCTAssertFalse(resolution.anyExpired)
    }

    func testExpiredKeychainFallsBackToOmp() {
        let resolution = ClaudeSubscriptionProvider.resolveTokens(
            keychainJSON: keychainJSON(expiresAtMS: (now.timeIntervalSince1970 - 60) * 1000),
            omp: ompCredential(expiresAt: now.addingTimeInterval(3600)),
            now: now
        )
        XCTAssertEqual(resolution.tokens, ["sk-omp"])
        XCTAssertTrue(resolution.anyExpired)
    }

    func testAllExpiredSelectsRefreshHintState() {
        let resolution = ClaudeSubscriptionProvider.resolveTokens(
            keychainJSON: keychainJSON(expiresAtMS: (now.timeIntervalSince1970 - 60) * 1000),
            omp: ompCredential(expiresAt: now.addingTimeInterval(-60)),
            now: now
        )
        XCTAssertTrue(resolution.tokens.isEmpty)
        XCTAssertTrue(resolution.anyExpired)
    }

    func testNoCredentialsAnywhere() {
        let resolution = ClaudeSubscriptionProvider.resolveTokens(keychainJSON: nil, omp: nil, now: now)
        XCTAssertTrue(resolution.tokens.isEmpty)
        XCTAssertFalse(resolution.anyExpired)
    }

    func testUndecodableKeychainSkippedWithoutExpiredFlag() {
        let resolution = ClaudeSubscriptionProvider.resolveTokens(
            keychainJSON: "not json",
            omp: ompCredential(expiresAt: nil),
            now: now
        )
        XCTAssertEqual(resolution.tokens, ["sk-omp"])
        XCTAssertFalse(resolution.anyExpired)
    }

    func testIdenticalTokensDeduplicated() {
        let resolution = ClaudeSubscriptionProvider.resolveTokens(
            keychainJSON: keychainJSON(token: "sk-same", expiresAtMS: nil),
            omp: ompCredential(token: "sk-same", expiresAt: nil),
            now: now
        )
        XCTAssertEqual(resolution.tokens, ["sk-same"])
    }
}
