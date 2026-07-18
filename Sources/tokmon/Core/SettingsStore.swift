import Foundation

struct AppSettings: Codable, Sendable, Equatable {
    /// Providers are enabled by default; this records explicit opt-outs so
    /// newly added providers appear without a settings migration.
    var disabledProviderIDs: Set<String> = []

    func isEnabled(_ providerID: String) -> Bool {
        !disabledProviderIDs.contains(providerID)
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
        if enabled {
            settings.disabledProviderIDs.remove(providerID)
        } else {
            settings.disabledProviderIDs.insert(providerID)
        }
    }

    private func save() {
        Storage.ensureDirectoryExists()
        if let data = try? Storage.makeEncoder().encode(settings) {
            try? data.write(to: Self.url, options: .atomic)
        }
    }
}
