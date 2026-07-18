import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @State private var adminKeyInput = ""
    @State private var adminKeyStatus = SecurityCLI.hasGenericPassword(
        service: AnthropicAPIProvider.keychainService,
        account: AnthropicAPIProvider.keychainAccount
    ) ? "A key is stored in the Keychain." : "No key stored."

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
            Section("Anthropic API") {
                SecureField("Admin API key (sk-ant-admin01-...)", text: $adminKeyInput)
                HStack {
                    Button("Save key") { saveAdminKey() }
                        .disabled(adminKeyInput.isEmpty)
                    Text(adminKeyStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Requires an organization account; see docs/action-items/001.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 340)
        .fixedSize()
    }

    private func saveAdminKey() {
        do {
            try SecurityCLI.addGenericPassword(
                service: AnthropicAPIProvider.keychainService,
                account: AnthropicAPIProvider.keychainAccount,
                secret: adminKeyInput
            )
            adminKeyInput = ""
            adminKeyStatus = "Key saved. Takes effect on next refresh."
        } catch {
            adminKeyStatus = "Save failed: \(error.localizedDescription)"
        }
    }

    private func binding(for row: Row) -> Binding<Bool> {
        Binding(
            get: { store.settings.isEnabled(row.id, default: row.enabledByDefault) },
            set: { store.setEnabled(row.id, $0) }
        )
    }
}
