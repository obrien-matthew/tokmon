import SwiftUI

@main
struct TokmonApp: App {
    @StateObject private var state: AppState
    @StateObject private var settingsStore: SettingsStore
    private let engine: RefreshEngine

    init() {
        Storage.ensureDirectoryExists()

        let settingsStore = SettingsStore()
        let providers = ProviderRegistry.enabledProviders(settings: settingsStore.settings)
        let cache = SnapshotCache()
        let enabledIDs = Set(providers.map(\.id))
        let cached = cache.load().filter { enabledIDs.contains($0.key) }

        let state = AppState(providers: providers, cached: cached)
        let engine = RefreshEngine(providers: providers, cache: cache, initial: cached) { snapshot in
            await state.apply(snapshot)
        }

        _state = StateObject(wrappedValue: state)
        _settingsStore = StateObject(wrappedValue: settingsStore)
        self.engine = engine

        // No app bundle, so no LSUIElement plist entry; hide the Dock icon
        // programmatically instead.
        NSApplication.shared.setActivationPolicy(.accessory)

        Task { await engine.start() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(state: state, engine: engine)
        } label: {
            MenuBarLabel(state: state)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: settingsStore)
        }
    }
}
