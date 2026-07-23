import Foundation
import XCTest
@testable import tokmon

final class CodexProviderTests: XCTestCase {
    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    func testLiveUsageMapsStringCreditBalance() throws {
        let usage = try decoder.decode(CodexProvider.WhamUsage.self, from: Data(#"""
        {
            "rate_limit": {
                "primary_window": {
                    "used_percent": 42,
                    "limit_window_seconds": 18000,
                    "reset_at": 1800000000
                }
            },
            "credits": {
                "has_credits": true,
                "unlimited": false,
                "balance": "12.5"
            }
        }
        """#.utf8))

        let metrics = CodexProvider.metrics(from: usage)

        XCTAssertEqual(metrics.count, 2)
        XCTAssertEqual(metrics.last, UsageMetric(
            id: "credits-remaining",
            label: "Credits remaining",
            kind: .quota,
            used: 12.5,
            limit: nil,
            unit: .credits,
            window: nil
        ))
    }

    func testFallbackMapsNumericZeroEvenWithoutCreditEntitlement() throws {
        let limits = try decoder.decode(CodexProvider.RateLimits.self, from: Data(#"""
        {
            "credits": {
                "has_credits": false,
                "unlimited": false,
                "balance": 0
            },
            "plan_type": "plus"
        }
        """#.utf8))

        let metrics = CodexProvider.metrics(from: limits)

        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics[0].used, 0)
        XCTAssertEqual(metrics[0].unit, .credits)
        XCTAssertNil(metrics[0].limit)
    }

    func testInvalidCreditBalancesAreOmitted() throws {
        for balance in [#""not-a-number""#, #""NaN""#, #"-1"#] {
            let json = #"{"credits":{"has_credits":true,"unlimited":false,"balance":\#(balance)}}"#
            let limits = try decoder.decode(CodexProvider.RateLimits.self, from: Data(json.utf8))
            XCTAssertTrue(CodexProvider.metrics(from: limits).isEmpty, "Unexpected metric for \(balance)")
        }
    }

    func testUnlimitedCreditsAreOmittedFromNumericMetrics() throws {
        let limits = try decoder.decode(CodexProvider.RateLimits.self, from: Data(#"""
        {
            "credits": {
                "has_credits": true,
                "unlimited": true,
                "balance": "100"
            }
        }
        """#.utf8))

        XCTAssertTrue(CodexProvider.metrics(from: limits).isEmpty)
    }

    @MainActor
    func testCreditsMetricCannotBecomeMenuBarHeadline() throws {
        let limits = try decoder.decode(CodexProvider.RateLimits.self, from: Data(#"""
        {
            "credits": {
                "has_credits": true,
                "unlimited": false,
                "balance": "25"
            }
        }
        """#.utf8))
        let snapshot = ProviderSnapshot(
            providerID: "codex",
            fetchedAt: Date(),
            status: .ok,
            metrics: CodexProvider.metrics(from: limits)
        )
        let state = AppState(providers: [StubCodexProvider()], cached: ["codex": snapshot])

        XCTAssertTrue(state.menuBarRows.isEmpty)
    }

    func testCreditAmountFormatting() {
        XCTAssertEqual(MetricGaugeRow.creditAmount(0), "0")
        XCTAssertEqual(MetricGaugeRow.creditAmount(12.5), "12.5")
        XCTAssertEqual(MetricGaugeRow.creditAmount(12.346), "12.35")
    }

    @MainActor
    func testHundredPercentMenuBarLabelUsesItsFullIntrinsicWidth() throws {
        let row99 = MenuBarRow(id: "codex", glyph: "X", fraction: 0.99, degraded: false)
        let row100 = MenuBarRow(id: "codex", glyph: "X", fraction: 1, degraded: false)
        let companion = MenuBarRow(id: "claude", glyph: "C", fraction: 0.5, degraded: false)

        let single99 = try XCTUnwrap(MenuBarLabel.render(rows: [row99], darkMenuBar: false))
        let single100 = try XCTUnwrap(MenuBarLabel.render(rows: [row100], darkMenuBar: false))
        XCTAssertGreaterThan(single100.size.width, single99.size.width)

        let compact99 = try XCTUnwrap(MenuBarLabel.render(rows: [row99, companion], darkMenuBar: false))
        let compact100 = try XCTUnwrap(MenuBarLabel.render(rows: [row100, companion], darkMenuBar: false))
        XCTAssertGreaterThan(compact100.size.width, compact99.size.width)
    }
}

private struct StubCodexProvider: UsageProvider {
    let id = "codex"
    let descriptor = ProviderDescriptor(
        displayName: "Codex",
        systemImage: "chevron.left.forwardslash.chevron.right",
        menuBarGlyph: "X"
    )
    let refreshInterval: TimeInterval = 300

    func fetchSnapshot() async throws -> ProviderSnapshot {
        ProviderSnapshot(providerID: id, fetchedAt: Date(), status: .ok, metrics: [])
    }
}
