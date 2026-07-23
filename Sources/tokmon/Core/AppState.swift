import Foundation

struct ProviderInfo: Identifiable, Equatable {
    let id: String
    let descriptor: ProviderDescriptor
}

/// One provider's line in the menu bar title: its most-constrained
/// rate-limit window reduced to a fill fraction.
struct MenuBarRow: Identifiable, Equatable {
    let id: String
    let glyph: String
    let fraction: Double
    let degraded: Bool

    var percent: Int {
        Int((fraction * 100).rounded())
    }
}

@MainActor
final class AppState: ObservableObject {
    let providers: [ProviderInfo]
    @Published private(set) var snapshots: [String: ProviderSnapshot]
    @Published private(set) var headlineMetricOverrides: [String: String]

    init(
        providers: [any UsageProvider],
        cached: [String: ProviderSnapshot],
        headlineMetricOverrides: [String: String] = [:]
    ) {
        self.providers = providers.map { ProviderInfo(id: $0.id, descriptor: $0.descriptor) }
        self.snapshots = cached
        self.headlineMetricOverrides = headlineMetricOverrides
    }

    func apply(_ snapshot: ProviderSnapshot) {
        snapshots[snapshot.providerID] = snapshot
    }

    func setHeadlineMetric(_ metricID: String?, for providerID: String) {
        if let metricID {
            headlineMetricOverrides[providerID] = metricID
        } else {
            headlineMetricOverrides.removeValue(forKey: providerID)
        }
    }

    /// One row per provider that has rate-limit data, in registry order so
    /// positions stay stable at a glance. Open-ended counters never qualify.
    /// Capped at two rows — that's what fits in the menu bar's 22pt height.
    var menuBarRows: [MenuBarRow] {
        var rows: [MenuBarRow] = []
        for info in providers {
            guard let snapshot = snapshots[info.id] else { continue }
            let rateMetrics = snapshot.metrics.filter { $0.kind == .rateLimitWindow }
            let selected = headlineMetricOverrides[info.id].flatMap { selectedID in
                rateMetrics.first { $0.id == selectedID && $0.fraction != nil }
            }
            // Prefer the 5h session window; providers without one (e.g.
            // Codex reporting only weekly) fall back to most constrained.
            let session = rateMetrics.first {
                $0.window?.duration == 18_000 || $0.id == "session"
            }
            guard let fraction = selected?.fraction
                    ?? session?.fraction
                    ?? rateMetrics.compactMap(\.fraction).max()
            else { continue }
            rows.append(MenuBarRow(
                id: info.id,
                glyph: info.descriptor.menuBarGlyph,
                fraction: fraction,
                degraded: !snapshot.status.isOK
            ))
        }
        return Array(rows.prefix(2))
    }
}
