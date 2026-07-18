import SwiftUI

struct MenuContentView: View {
    @ObservedObject var state: AppState
    let engine: RefreshEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(state.providers) { info in
                ProviderSection(info: info, snapshot: state.snapshots[info.id])
            }
            Divider()
            HStack {
                SettingsLink {
                    Text("Settings")
                }
                .simultaneousGesture(TapGesture().onEnded {
                    // Accessory apps don't come forward on their own.
                    NSApplication.shared.activate(ignoringOtherApps: true)
                })
                Button {
                    Task { await engine.refreshAll(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh all providers now")
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 300)
        .onAppear {
            Task { await engine.menuOpened() }
        }
    }
}

struct ProviderSection: View {
    let info: ProviderInfo
    let snapshot: ProviderSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: info.descriptor.systemImage)
                    .foregroundStyle(.secondary)
                Text(info.descriptor.displayName)
                    .font(.headline)
                Spacer()
                staleness
            }
            if let snapshot {
                statusLine(snapshot.status)
                if snapshot.metrics.isEmpty {
                    Text("No data")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.metrics) { metric in
                        MetricGaugeRow(metric: metric, dimmed: !snapshot.status.isOK)
                    }
                }
            } else {
                Text("Loading")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var staleness: some View {
        if let snapshot, snapshot.fetchedAt > .distantPast {
            // Live-updating relative timestamp; honest even when the last
            // fetch failed, because degraded snapshots keep the old date.
            (Text("as of ") + Text(snapshot.fetchedAt, style: .relative) + Text(" ago"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func statusLine(_ status: ProviderStatus) -> some View {
        switch status {
        case .ok:
            EmptyView()
        case .authRequired(let hint):
            Label(hint, systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.orange)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }
}
