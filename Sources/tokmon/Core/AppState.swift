import Foundation

struct ProviderInfo: Identifiable, Equatable {
    let id: String
    let descriptor: ProviderDescriptor
}

struct Headline: Equatable {
    var metric: UsageMetric
    var degraded: Bool

    var percent: Int {
        Int(((metric.fraction ?? 0) * 100).rounded())
    }
}

@MainActor
final class AppState: ObservableObject {
    let providers: [ProviderInfo]
    @Published private(set) var snapshots: [String: ProviderSnapshot]

    init(providers: [any UsageProvider], cached: [String: ProviderSnapshot]) {
        self.providers = providers.map { ProviderInfo(id: $0.id, descriptor: $0.descriptor) }
        self.snapshots = cached
    }

    func apply(_ snapshot: ProviderSnapshot) {
        snapshots[snapshot.providerID] = snapshot
    }

    /// The single most-constrained rate-limit metric across all providers —
    /// what the menu bar title shows. Open-ended counters never qualify.
    var headline: Headline? {
        var best: Headline?
        for info in providers {
            guard let snapshot = snapshots[info.id] else { continue }
            for metric in snapshot.metrics where metric.kind == .rateLimitWindow {
                guard let fraction = metric.fraction else { continue }
                if best == nil || fraction > (best!.metric.fraction ?? 0) {
                    best = Headline(metric: metric, degraded: !snapshot.status.isOK)
                }
            }
        }
        return best
    }
}
