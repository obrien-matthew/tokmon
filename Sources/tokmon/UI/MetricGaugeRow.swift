import SwiftUI

/// The single universal component: a gauge row for limited metrics, a plain
/// counter row for open-ended ones (limit == nil).
struct MetricGaugeRow: View {
    let metric: UsageMetric
    let dimmed: Bool

    var body: some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(metric.label)
                    .font(.callout)
                Spacer(minLength: 8)
                if let resetsAt = metric.window?.resetsAt {
                    CountdownText(resetsAt: resetsAt)
                }
                Text(Self.valueText(for: metric))
                    .font(.callout)
                    .monospacedDigit()
            }
            if let fraction = metric.fraction {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.12))
                        Capsule()
                            .fill(Self.escalationColor(for: fraction))
                            .frame(width: max(geo.size.width * fraction, 4))
                    }
                }
                .frame(height: 5)
            }
        }
        .opacity(dimmed ? 0.5 : 1)
    }

    static func escalationColor(for fraction: Double) -> Color {
        switch fraction {
        case 0.9...: .red
        case 0.7...: .orange
        default: .accentColor
        }
    }

    static func valueText(for metric: UsageMetric) -> String {
        switch metric.unit {
        case .percent:
            "\(Int(metric.used.rounded()))%"
        case .usd:
            if let limit = metric.limit {
                "\(dollarAmount(metric.used)) / \(dollarAmount(limit))"
            } else {
                dollarAmount(metric.used)
            }
        case .credits:
            "\(Self.creditAmount(metric.used)) credits"
        case .tokens:
            if let limit = metric.limit {
                "\(Self.abbreviated(metric.used)) / \(Self.abbreviated(limit))"
            } else {
                Self.abbreviated(metric.used)
            }
        case .requests:
            if let limit = metric.limit {
                "\(Int(metric.used)) / \(Int(limit))"
            } else {
                "\(Int(metric.used))"
            }
        }
    }

    private static func dollarAmount(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    static func creditAmount(_ value: Double) -> String {
        var text = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
        while text.last == "0" { text.removeLast() }
        if text.last == "." { text.removeLast() }
        return text
    }

    static func abbreviated(_ value: Double) -> String {
        switch value {
        case 1_000_000_000...: String(format: "%.1fB", value / 1e9)
        case 1_000_000...: String(format: "%.1fM", value / 1e6)
        case 1_000...: String(format: "%.1fK", value / 1e3)
        default: "\(Int(value))"
        }
    }
}

/// Countdown derives from resetsAt on a UI timer, so it stays correct even
/// when the underlying data is stale (e.g. after sleep or during an outage).
struct CountdownText: View {
    let resetsAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let text = Self.remaining(until: resetsAt, from: context.date) {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func remaining(until date: Date, from now: Date) -> String? {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "resetting" }
        let minutes = Int(seconds / 60)
        let days = minutes / 1440
        let hours = (minutes / 60) % 24
        let mins = minutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }
}
