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
    /// nil = auto; otherwise restricts the menu bar title to one provider.
    let headlineProviderID: String?
    @Published private(set) var snapshots: [String: ProviderSnapshot]

    init(
        providers: [any UsageProvider],
        cached: [String: ProviderSnapshot],
        headlineProviderID: String? = nil
    ) {
        self.providers = providers.map { ProviderInfo(id: $0.id, descriptor: $0.descriptor) }
        self.headlineProviderID = headlineProviderID
        self.snapshots = cached
    }

    func apply(_ snapshot: ProviderSnapshot) {
        snapshots[snapshot.providerID] = snapshot
    }

    /// One row per provider that has rate-limit data, in registry order so
    /// positions stay stable at a glance. Open-ended counters never qualify.
    /// Capped at two rows — that's what fits in the menu bar's 22pt height.
    var menuBarRows: [MenuBarRow] {
        var rows: [MenuBarRow] = []
        for info in providers {
            if let headlineProviderID, info.id != headlineProviderID { continue }
            guard let snapshot = snapshots[info.id] else { continue }
            let worst = snapshot.metrics
                .filter { $0.kind == .rateLimitWindow }
                .compactMap(\.fraction)
                .max()
            guard let worst else { continue }
            rows.append(MenuBarRow(
                id: info.id,
                glyph: info.descriptor.menuBarGlyph,
                fraction: worst,
                degraded: !snapshot.status.isOK
            ))
        }
        return Array(rows.prefix(2))
    }
}
