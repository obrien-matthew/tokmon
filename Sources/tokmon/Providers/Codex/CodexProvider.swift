import Foundation

/// Codex/ChatGPT rate limits, read from the rate_limits payloads Codex CLI
/// persists in its session files (~/.codex/sessions/**/rollout-*.jsonl,
/// token_count events).
///
/// Chosen over replaying the ChatGPT OAuth token from auth.json: local
/// parsing needs no undocumented endpoint and no token handling. The
/// tradeoff is freshness — data is as of the last Codex turn — which the
/// UI reports honestly because fetchedAt is the event's own timestamp.
struct CodexProvider: UsageProvider {
    let id = "codex"
    let descriptor = ProviderDescriptor(displayName: "Codex", systemImage: "chevron.left.forwardslash.chevron.right", menuBarGlyph: "X")
    let refreshInterval: TimeInterval = 300

    private static var sessionsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        guard let event = Self.latestRateLimitEvent() else {
            throw ProviderError.authRequired(hint: "Run Codex once to record usage")
        }
        return ProviderSnapshot(
            providerID: id,
            fetchedAt: event.timestamp,
            status: .ok,
            metrics: Self.metrics(from: event.rateLimits)
        )
    }

    // MARK: - Session file scanning

    struct RateLimitEvent {
        let timestamp: Date
        let rateLimits: RateLimits
    }

    struct RateLimits: Decodable {
        struct Window: Decodable {
            let usedPercent: Double?
            let windowMinutes: Double?
            let resetsAt: Double?  // unix seconds
        }
        let primary: Window?
        let secondary: Window?
        let planType: String?
    }

    private struct Line: Decodable {
        struct Payload: Decodable {
            let type: String?
            let rateLimits: RateLimits?
        }
        let timestamp: String?
        let payload: Payload?
    }

    /// Newest session files first; the newest file may predate rate-limit
    /// reporting or contain no turns, so fall through a few before giving up.
    static func latestRateLimitEvent() -> RateLimitEvent? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }

        var files: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("rollout-"),
                  url.pathExtension == "jsonl",
                  let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                      .contentModificationDate
            else { continue }
            files.append((url, modified))
        }
        files.sort { $0.modified > $1.modified }

        for file in files.prefix(5) {
            if let event = lastRateLimitEvent(in: file.url) {
                return event
            }
        }
        return nil
    }

    private static func lastRateLimitEvent(in url: URL) -> RateLimitEvent? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // Last matching line wins — it's the freshest snapshot in the file.
        for lineText in contents.split(separator: "\n").reversed() {
            guard lineText.contains("\"rate_limits\""),
                  let data = lineText.data(using: .utf8),
                  let line = try? decoder.decode(Line.self, from: data),
                  let rateLimits = line.payload?.rateLimits
            else { continue }
            let timestamp = line.timestamp.flatMap {
                iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0)
            } ?? .distantPast
            return RateLimitEvent(timestamp: timestamp, rateLimits: rateLimits)
        }
        return nil
    }

    // MARK: - Mapping

    static func metrics(from limits: RateLimits) -> [UsageMetric] {
        var metrics: [UsageMetric] = []
        for (id, window) in [("primary", limits.primary), ("secondary", limits.secondary)] {
            guard let window, let usedPercent = window.usedPercent else { continue }
            let duration = window.windowMinutes.map { $0 * 60 }
            metrics.append(UsageMetric(
                id: id,
                label: label(forWindowMinutes: window.windowMinutes),
                kind: .rateLimitWindow,
                used: usedPercent,
                limit: 100,
                unit: .percent,
                window: MetricWindow(
                    duration: duration,
                    resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: $0) }
                )
            ))
        }
        return metrics
    }

    private static func label(forWindowMinutes minutes: Double?) -> String {
        switch minutes {
        case .some(300): "Session"
        case .some(10080): "Weekly"
        case .some(let m): "\(Int(m / 60))h window"
        case nil: "Usage"
        }
    }
}
