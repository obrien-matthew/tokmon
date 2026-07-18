import SwiftUI

/// Compact menu bar title: the most-constrained rate-limit percentage across
/// all providers. A "!" prefix marks data from a provider in a degraded
/// state (auth required / error), i.e. the number shown is cached.
/// Note: macOS renders MenuBarExtra labels as template images, so the
/// escalation color may be stripped by the system; the "!" marker is the
/// reliable degradation signal.
struct MenuBarLabel: View {
    @ObservedObject var state: AppState

    var body: some View {
        if let headline = state.headline {
            Text(headline.degraded ? "!\(headline.percent)%" : "\(headline.percent)%")
                .monospacedDigit()
                .foregroundStyle(
                    MetricGaugeRow.escalationColor(for: headline.metric.fraction ?? 0)
                )
        } else {
            Image(systemName: "gauge.with.needle")
        }
    }
}
