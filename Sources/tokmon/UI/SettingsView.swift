import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: SettingsStore

    private struct Row: Identifiable {
        let id: String
        let displayName: String
        let enabledByDefault: Bool
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
            Text("Provider changes take effect after relaunch.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 340)
        .fixedSize()
    }

    private func binding(for row: Row) -> Binding<Bool> {
        Binding(
            get: { store.settings.isEnabled(row.id, default: row.enabledByDefault) },
            set: { store.setEnabled(row.id, $0) }
        )
    }
}
