import Foundation

/// Last-known-good snapshots persisted to disk, so the widget shows stale
/// data with a timestamp instead of going blank on launch or fetch failure.
struct SnapshotCache: Sendable {
    private var url: URL {
        Storage.directory.appendingPathComponent("snapshots.json")
    }

    func load() -> [String: ProviderSnapshot] {
        guard let data = try? Data(contentsOf: url),
              let snapshots = try? Storage.makeDecoder().decode([String: ProviderSnapshot].self, from: data)
        else { return [:] }
        return snapshots
    }

    /// Merge-updates so snapshots for currently disabled providers survive.
    func update(_ snapshot: ProviderSnapshot) {
        var all = load()
        all[snapshot.providerID] = snapshot
        Storage.ensureDirectoryExists()
        if let data = try? Storage.makeEncoder().encode(all) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
