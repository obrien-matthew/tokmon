import Foundation

struct AppSettings: Codable, Sendable, Equatable {
    /// Explicit per-provider overrides only; anything unrecorded falls back
    /// to the provider's own default, so new providers appear (and mock
    /// providers stay hidden) without a settings migration.
    var providerOverrides: [String: Bool] = [:]
    /// Missing provider key = Auto (session-first, then most constrained).
    var headlineMetricOverrides: [String: String] = [:]

    private enum CodingKeys: String, CodingKey {
        case providerOverrides
        case headlineMetricOverrides
    }

    init(
        providerOverrides: [String: Bool] = [:],
        headlineMetricOverrides: [String: String] = [:]
    ) {
        self.providerOverrides = providerOverrides
        self.headlineMetricOverrides = headlineMetricOverrides
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerOverrides = try container.decodeIfPresent(
            [String: Bool].self, forKey: .providerOverrides
        ) ?? [:]
        headlineMetricOverrides = try container.decodeIfPresent(
            [String: String].self, forKey: .headlineMetricOverrides
        ) ?? [:]
    }

    func isEnabled(_ providerID: String, default defaultValue: Bool) -> Bool {
        providerOverrides[providerID] ?? defaultValue
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet { save() }
    }

    private static var url: URL {
        Storage.directory.appendingPathComponent("settings.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.url),
           let settings = try? Storage.makeDecoder().decode(AppSettings.self, from: data) {
            self.settings = settings
        } else {
            self.settings = AppSettings()
        }
    }

    func setEnabled(_ providerID: String, _ enabled: Bool) {
        settings.providerOverrides[providerID] = enabled
    }

    func setHeadlineMetric(_ metricID: String?, for providerID: String) {
        if let metricID {
            settings.headlineMetricOverrides[providerID] = metricID
        } else {
            settings.headlineMetricOverrides.removeValue(forKey: providerID)
        }
    }

    private func save() {
        Storage.ensureDirectoryExists()
        if let data = try? Storage.makeEncoder().encode(settings) {
            try? data.write(to: Self.url, options: .atomic)
        }
    }
}
