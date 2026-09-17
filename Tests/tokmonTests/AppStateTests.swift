import Foundation
import XCTest
@testable import tokmon

final class AppStateTests: XCTestCase {
    func testLegacySettingsIgnoreProviderPinAndDefaultNewOverrides() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"""
        {
            "providerOverrides": {"codex": false},
            "headlineProviderID": "claude-subscription"
        }
        """#.utf8))

        XCTAssertEqual(settings.providerOverrides, ["codex": false])
        XCTAssertTrue(settings.headlineMetricOverrides.isEmpty)
    }

    func testSettingsWithNoKnownFieldsUseDefaults() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{}"#.utf8))

        XCTAssertTrue(settings.providerOverrides.isEmpty)
        XCTAssertTrue(settings.headlineMetricOverrides.isEmpty)
    }

    @MainActor
    func testPerProviderMetricOverridesKeepBothRowsAndApplyImmediately() {
        let providers: [any UsageProvider] = [StubProvider(id: "claude"), StubProvider(id: "codex")]
        let state = AppState(
            providers: providers,
            cached: [
                "claude": snapshot(providerID: "claude", session: 20, weekly: 80),
                "codex": snapshot(providerID: "codex", session: 30, weekly: 60),
            ],
            headlineMetricOverrides: ["claude": "weekly"]
        )

        XCTAssertEqual(state.menuBarRows.map(\.id), ["claude", "codex"])
        XCTAssertEqual(state.menuBarRows.map(\.percent), [80, 30])

        state.setHeadlineMetric("weekly", for: "codex")
        XCTAssertEqual(state.menuBarRows.map(\.percent), [80, 60])
    }

    @MainActor
    func testUnavailableOrNonRateSelectionFallsBackToAuto() {
        var claude = snapshot(providerID: "claude", session: 20, weekly: 80)
        claude.metrics.append(UsageMetric(
            id: "credits", label: "Credits", kind: .quota,
            used: 10, limit: nil, unit: .credits, window: nil
        ))
        let provider = StubProvider(id: "claude")

        for selectedID in ["missing", "credits"] {
            let state = AppState(
                providers: [provider],
                cached: ["claude": claude],
                headlineMetricOverrides: ["claude": selectedID]
            )
            XCTAssertEqual(state.menuBarRows.map(\.percent), [20])
        }
    }

    /// Publishing is async, so a slow attempt can land after the attempt
    /// that superseded it. The newer result must win regardless of
    /// arrival order, or the UI silently reverts to stale state.
    @MainActor
    func testStaleSequenceCannotOverwriteANewerSnapshot() {
        let state = AppState(providers: [StubProvider(id: "claude")], cached: [:])
        let fresh = snapshot(providerID: "claude", session: 20, weekly: 30)
        var stale = snapshot(providerID: "claude", session: 90, weekly: 95)
        stale.status = .error(message: "stale")

        state.apply(fresh, sequence: 7)
        state.apply(stale, sequence: 6)

        XCTAssertEqual(state.snapshots["claude"], fresh)
        XCTAssertTrue(try XCTUnwrap(state.snapshots["claude"]).status.isOK)
    }

    @MainActor
    func testEqualOrNewerSequenceApplies() {
        let state = AppState(providers: [StubProvider(id: "claude")], cached: [:])
        let first = snapshot(providerID: "claude", session: 10, weekly: 10)
        let retry = snapshot(providerID: "claude", session: 40, weekly: 40)
        let next = snapshot(providerID: "claude", session: 80, weekly: 80)

        state.apply(first, sequence: 3)
        // Same attempt republishing (degraded then recovered) still lands.
        state.apply(retry, sequence: 3)
        XCTAssertEqual(state.snapshots["claude"], retry)

        state.apply(next, sequence: 4)
        XCTAssertEqual(state.snapshots["claude"], next)
    }

    private func snapshot(providerID: String, session: Double, weekly: Double) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: providerID,
            fetchedAt: Date(),
            status: .ok,
            metrics: [
                UsageMetric(
                    id: "session", label: "Session", kind: .rateLimitWindow,
                    used: session, limit: 100, unit: .percent,
                    window: MetricWindow(duration: 18_000, resetsAt: nil)
                ),
                UsageMetric(
                    id: "weekly", label: "Weekly", kind: .rateLimitWindow,
                    used: weekly, limit: 100, unit: .percent,
                    window: MetricWindow(duration: 604_800, resetsAt: nil)
                ),
            ]
        )
    }
}

private struct StubProvider: UsageProvider {
    let id: String
    var descriptor: ProviderDescriptor {
        ProviderDescriptor(displayName: id.capitalized, systemImage: "gauge", menuBarGlyph: "T")
    }
    let refreshInterval: TimeInterval = 300

    func fetchSnapshot() async throws -> ProviderSnapshot {
        ProviderSnapshot(providerID: id, fetchedAt: Date(), status: .ok, metrics: [])
    }
}
