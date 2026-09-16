import XCTest
@testable import tokmon

final class OpenRouterProviderTests: XCTestCase {
    /// The live account at the time this provider was written.
    private let credits = OpenRouterProvider.Credits(
        totalCredits: 60,
        totalUsage: 54.561828163
    )

    func testExhaustedCapFillsTheGauge() throws {
        let metric = try XCTUnwrap(OpenRouterProvider.keyCapMetric(.init(
            limit: 25, limitRemaining: 0, limitReset: "monthly"
        )))
        XCTAssertEqual(metric.id, "key-cap")
        XCTAssertEqual(metric.kind, .spend)
        XCTAssertEqual(metric.used, 25)
        XCTAssertEqual(metric.limit, 25)
        XCTAssertEqual(metric.fraction, 1)
        XCTAssertEqual(metric.label, "Key spend (monthly)")
        XCTAssertNil(metric.window)
        XCTAssertEqual(MetricGaugeRow.valueText(for: metric), "$25.00 / $25.00")
    }

    func testPartiallyUsedCap() throws {
        let metric = try XCTUnwrap(OpenRouterProvider.keyCapMetric(.init(
            limit: 25, limitRemaining: 10, limitReset: "monthly"
        )))
        XCTAssertEqual(metric.used, 15)
        XCTAssertEqual(try XCTUnwrap(metric.fraction), 0.6, accuracy: 0.000_000_001)
        XCTAssertEqual(MetricGaugeRow.valueText(for: metric), "$15.00 / $25.00")
    }

    /// A cap without a finite remainder is incomplete, so it cannot be
    /// rendered as an invented unused or exhausted gauge.
    func testCapWithoutRemainderIsOmitted() {
        XCTAssertNil(OpenRouterProvider.keyCapMetric(.init(
            limit: 25, limitRemaining: nil, limitReset: "monthly"
        )))
        XCTAssertNil(OpenRouterProvider.keyCapMetric(.init(
            limit: 25, limitRemaining: .infinity, limitReset: "monthly"
        )))
    }

    func testUncappedKeyHasNoGauge() {
        XCTAssertNil(OpenRouterProvider.keyCapMetric(.init(
            limit: nil, limitRemaining: nil, limitReset: nil
        )))
        XCTAssertNil(OpenRouterProvider.keyCapMetric(.init(
            limit: 0, limitRemaining: 0, limitReset: "monthly"
        )))
    }

    func testResetCadenceDrivesTheLabel() throws {
        let lifetime = try XCTUnwrap(OpenRouterProvider.keyCapMetric(.init(
            limit: 100, limitRemaining: 75, limitReset: nil
        )))
        XCTAssertEqual(lifetime.label, "Key spend (lifetime)")

        let unknown = try XCTUnwrap(OpenRouterProvider.keyCapMetric(.init(
            limit: 100, limitRemaining: 75, limitReset: "quarterly"
        )))
        XCTAssertEqual(unknown.label, "Key spend (quarterly)")
    }

    func testBalanceIsAnOpenEndedCounter() throws {
        let metric = try XCTUnwrap(OpenRouterProvider.balanceMetric(credits.balance))
        XCTAssertEqual(metric.id, "credits")
        XCTAssertEqual(metric.used, 5.438171837, accuracy: 0.000_000_001)
        XCTAssertNil(metric.limit)
        XCTAssertNil(metric.fraction)
        XCTAssertEqual(metric.label, "Balance")
        XCTAssertEqual(MetricGaugeRow.valueText(for: metric), "$5.44")
    }

    func testEmptyAndOverdrawnBalances() throws {
        let empty = OpenRouterProvider.Credits(totalCredits: 0, totalUsage: 0)
        let emptyMetric = try XCTUnwrap(OpenRouterProvider.balanceMetric(empty.balance))
        XCTAssertEqual(MetricGaugeRow.valueText(for: emptyMetric), "$0.00")

        let overdrawn = OpenRouterProvider.Credits(totalCredits: 20, totalUsage: 25)
        let overdrawnMetric = try XCTUnwrap(OpenRouterProvider.balanceMetric(overdrawn.balance))
        XCTAssertEqual(overdrawnMetric.used, -5)
        XCTAssertEqual(MetricGaugeRow.valueText(for: overdrawnMetric), "$-5.00")
    }

    func testIncompleteCreditsPayloadYieldsNoBalance() {
        let partial = OpenRouterProvider.Credits(totalCredits: 60, totalUsage: nil)
        XCTAssertNil(OpenRouterProvider.balanceMetric(partial.balance))
    }

    /// Either endpoint failing must degrade to the other, never blank
    /// the provider — that is what `fetchSnapshot` keys its status off.
    func testEachEndpointSuppliesMetricsIndependently() {
        let key = OpenRouterProvider.KeyInfo(limit: 25, limitRemaining: 0, limitReset: "monthly")
        XCTAssertEqual(
            OpenRouterProvider.metrics(credits: credits, key: key).map(\.id),
            ["key-cap", "credits"]
        )
        XCTAssertEqual(OpenRouterProvider.metrics(credits: credits, key: nil).map(\.id), ["credits"])
        XCTAssertEqual(OpenRouterProvider.metrics(credits: nil, key: key).map(\.id), ["key-cap"])
        XCTAssertTrue(OpenRouterProvider.metrics(credits: nil, key: nil).isEmpty)
    }

    func testUncappedKeySuccessResolvesToEmptyMetricsAfterCreditsUnauthorized() throws {
        let metrics = try OpenRouterProvider.resolve(
            credits: .init(error: URLError(.badServerResponse), unauthorized: true),
            key: .init(value: .init(limit: nil, limitRemaining: nil, limitReset: nil))
        )

        XCTAssertTrue(metrics.isEmpty)
    }

    func testNeitherEndpointSuccessWithUnauthorizedResultRequiresAuthentication() {
        XCTAssertThrowsError(try OpenRouterProvider.resolve(
            credits: .init(error: URLError(.badServerResponse)),
            key: .init(error: URLError(.badServerResponse), unauthorized: true)
        )) { error in
            guard case .authRequired = error as? ProviderError else {
                return XCTFail("Expected authRequired, got \(error)")
            }
        }
    }

    func testNeitherEndpointSuccessThrowsFirstUnderlyingError() {
        XCTAssertThrowsError(try OpenRouterProvider.resolve(
            credits: .init(error: URLError(.timedOut)),
            key: .init(error: URLError(.cannotConnectToHost))
        )) { error in
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
    }

    @MainActor
    func testOpenRouterNeverReachesTheMenuBar() {
        let provider = OpenRouterProvider()
        let state = AppState(
            providers: [provider],
            cached: ["openrouter": ProviderSnapshot(
                providerID: "openrouter",
                fetchedAt: Date(),
                status: .ok,
                metrics: OpenRouterProvider.metrics(
                    credits: credits,
                    key: .init(limit: 25, limitRemaining: 0, limitReset: "monthly")
                )
            )]
        )
        XCTAssertTrue(state.menuBarRows.isEmpty)
    }
}
