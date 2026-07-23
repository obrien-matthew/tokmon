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
