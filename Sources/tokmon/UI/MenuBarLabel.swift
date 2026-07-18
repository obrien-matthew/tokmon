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
        // Always 2x: NSImage.size stays in points, so this just adds a
        // Retina representation. NSScreen.main tracks whichever display is
        // key and can report 1x while the menu bar sits on a Retina screen.
        renderer.scale = 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = false
        dumpDebugImage(image)
        return image
    }

    /// Writes the composed label next to the snapshot cache so rendering
    /// problems can be diagnosed by looking at the actual produced image.
    private static func dumpDebugImage(_ image: NSImage) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: Storage.directory.appendingPathComponent("menubar-debug.png"))
    }
}

struct MenuBarRowsView: View {
    let rows: [MenuBarRow]
    let baseColor: Color

    /// Single-row layout gets larger type; two rows must share ~22pt.
    private var compact: Bool { rows.count > 1 }

    var body: some View {
        // Total height must stay under ~18pt or the status item clips.
        VStack(alignment: .leading, spacing: 1) {
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
        .frame(height: compact ? 8 : 14)
    }

    private var barWidth: CGFloat { compact ? 16 : 22 }
    private var barHeight: CGFloat { compact ? 3 : 4 }
}
