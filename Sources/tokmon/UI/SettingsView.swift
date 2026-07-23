import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var state: AppState
    @State private var launchAtLogin = LaunchAgent.isInstalled
    @State private var launchAtLoginError: String?

    private struct Row: Identifiable {
        let id: String
        let displayName: String
        let enabledByDefault: Bool
    }

    private struct MetricOption: Identifiable {
        let id: String
        let label: String
    }

    private var rows: [Row] {
        ProviderRegistry.allProviders().map {
            Row(id: $0.id, displayName: $0.descriptor.displayName, enabledByDefault: $0.enabledByDefault)
        }
    }

    var body: some View {
        Form {
            Section("Providers") {
                ForEach(rows) { row in
                    Toggle(row.displayName, isOn: binding(for: row))
                }
            }
            Section("Menu bar") {
                ForEach(state.providers) { provider in
                    Picker("\(provider.descriptor.displayName) bar", selection: headlineMetricBinding(for: provider.id)) {
                        Text("Auto").tag(String?.none)
                        ForEach(metricOptions(for: provider.id)) { option in
                            Text(option.label).tag(String?.some(option.id))
                        }
                        if let selected = store.settings.headlineMetricOverrides[provider.id],
                           !metricOptions(for: provider.id).contains(where: { $0.id == selected }) {
                            Text("Unavailable (using Auto)").tag(String?.some(selected))
                        }
                    }
                }
            }
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        toggleLaunchAtLogin(enabled)
                    }
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Text("Provider changes take effect after relaunch; menu bar choices apply immediately.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 340)
        .fixedSize()
    }

    private func headlineMetricBinding(for providerID: String) -> Binding<String?> {
        Binding(
            get: { store.settings.headlineMetricOverrides[providerID] },
            set: { metricID in
                store.setHeadlineMetric(metricID, for: providerID)
                state.setHeadlineMetric(metricID, for: providerID)
            }
        )
    }

    private func metricOptions(for providerID: String) -> [MetricOption] {
        (state.snapshots[providerID]?.metrics ?? [])
            .filter { $0.kind == .rateLimitWindow && $0.fraction != nil }
            .map { MetricOption(id: $0.id, label: $0.label) }
    }

    private func toggleLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try LaunchAgent.install()
            } else {
                LaunchAgent.uninstall()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Failed: \(error.localizedDescription)"
            launchAtLogin = LaunchAgent.isInstalled
        }
    }

    private func binding(for row: Row) -> Binding<Bool> {
        Binding(
            get: { store.settings.isEnabled(row.id, default: row.enabledByDefault) },
            set: { store.setEnabled(row.id, $0) }
        )
    }
}
