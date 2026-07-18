import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @State private var adminKeyInput = ""
    @State private var launchAtLogin = LaunchAgent.isInstalled
    @State private var launchAtLoginError: String?
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
            Section("Menu bar") {
                Picker("Title shows", selection: headlineBinding) {
                    Text("Most constrained (auto)").tag(String?.none)
                    ForEach(rows) { row in
                        Text(row.displayName).tag(String?.some(row.id))
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
            Text("Provider and menu bar changes take effect after relaunch.")
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

    private var headlineBinding: Binding<String?> {
        Binding(
            get: { store.settings.headlineProviderID },
            set: { store.settings.headlineProviderID = $0 }
        )
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
