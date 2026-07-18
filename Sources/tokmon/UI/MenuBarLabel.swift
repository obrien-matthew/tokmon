import AppKit
import SwiftUI

/// Menu bar title: one stacked row per provider (up to two), each showing
/// glyph + micro gauge bar + percent. Rendered to a non-template NSImage
/// via ImageRenderer because MenuBarExtra text labels are drawn as
/// monochrome templates — this is the only way to keep the escalation
/// colors and fit two rows in the menu bar's height.
///
/// Non-template images don't auto-adapt to the menu bar's appearance, so
/// the base color follows the environment colorScheme. Edge case accepted
/// for personal use: wallpaper-tinted menu bars that disagree with the
/// system appearance may reduce contrast.
struct MenuBarLabel: View {
    @ObservedObject var state: AppState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let rows = state.menuBarRows
        if rows.isEmpty {
            Image(systemName: "gauge.with.needle")
        } else if let image = Self.render(rows: rows, darkMenuBar: colorScheme == .dark) {
            Image(nsImage: image)
        } else {
            // ImageRenderer failure fallback: plain (template) text.
            Text(rows.map { "\($0.glyph)\($0.percent)" }.joined(separator: " "))
                .monospacedDigit()
        }
    }

    @MainActor
    static func render(rows: [MenuBarRow], darkMenuBar: Bool) -> NSImage? {
        let base: Color = darkMenuBar ? .white : Color(white: 0.15)
        let renderer = ImageRenderer(
            content: MenuBarRowsView(rows: rows, baseColor: base)
        )
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = false
        return image
    }
}

struct MenuBarRowsView: View {
    let rows: [MenuBarRow]
    let baseColor: Color

    /// Single-row layout gets larger type; two rows must share ~22pt.
    private var compact: Bool { rows.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(rows) { row in
                rowView(row)
                    .opacity(row.degraded ? 0.5 : 1)
            }
        }
        .foregroundStyle(baseColor)
        .padding(.horizontal, 1)
    }

    private func rowView(_ row: MenuBarRow) -> some View {
        HStack(spacing: 3) {
            Text(row.glyph)
                .font(.system(size: compact ? 8 : 11, weight: .bold, design: .monospaced))
                .frame(width: compact ? 7 : 9, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(baseColor.opacity(0.25))
                    .frame(width: barWidth, height: barHeight)
                Capsule()
                    .fill(MetricGaugeRow.escalationColor(for: row.fraction))
                    .frame(width: max(barWidth * row.fraction, 2), height: barHeight)
            }
            Text("\(row.percent)")
                .font(.system(size: compact ? 8 : 11, weight: .semibold, design: .monospaced))
                .frame(width: compact ? 13 : 17, alignment: .trailing)
        }
    }

    private var barWidth: CGFloat { compact ? 16 : 22 }
    private var barHeight: CGFloat { compact ? 3 : 4 }
}
