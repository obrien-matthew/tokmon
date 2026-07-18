import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: SettingsStore

    private var providerInfos: [ProviderInfo] {
        ProviderRegistry.allProviders().map {
            ProviderInfo(id: $0.id, descriptor: $0.descriptor)
        }
    }

    var body: some View {
        Form {
            Section("Providers") {
                ForEach(providerInfos) { info in
                    Toggle(info.descriptor.displayName, isOn: binding(for: info.id))
                }
            }
            Text("Provider changes take effect after relaunch.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 340)
        .fixedSize()
    }

    private func binding(for providerID: String) -> Binding<Bool> {
        Binding(
            get: { store.settings.isEnabled(providerID) },
            set: { store.setEnabled(providerID, $0) }
        )
    }
}
