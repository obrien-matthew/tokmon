import Foundation

/// Codex/ChatGPT rate limits.
///
/// Live-first: queries the same usage endpoint Codex's own /status uses
/// (endpoint + headers verified against the open codex-rs source,
/// backend-client/src/client/rate_limit_resets.rs), authenticated with
/// the first working credential from an ordered list: the ChatGPT OAuth
/// token Codex CLI stores in ~/.codex/auth.json, then oh-my-pi's stored
/// token for the same account (fallback for when the CLI token expires
/// unused because work happens in omp). Read-only — tokmon never
/// refreshes or writes either token.
///
/// Falls back to the rate_limits snapshots Codex CLI persists in its
/// session files (~/.codex/sessions/**/rollout-*.jsonl) when every live
/// candidate fails (expired tokens, offline, endpoint change). File data
/// is as of the last Codex CLI turn; its snapshot keeps the event's own
/// timestamp so the staleness label stays honest.
///
/// Known limitation: nothing enforces that omp is signed into the same
/// ChatGPT account as Codex CLI. If it isn't, a fallback fetch reports
/// the omp account's usage under this gauge.
struct CodexProvider: UsageProvider {
    let id = "codex"
    let descriptor = ProviderDescriptor(displayName: "Codex", systemImage: "chevron.left.forwardslash.chevron.right", menuBarGlyph: "X")
    let refreshInterval: TimeInterval = 300

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    private static var codexDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        // Any live failure advances to the next candidate; expiry-checked
        // tokens can still be revoked. At most two requests per poll, and
        // only on the failure path.
        for credential in Self.liveCredentials(
            authJSON: try? Data(contentsOf: Self.codexDirectory.appendingPathComponent("auth.json")),
            omp: OmpCredentialStore.credential(provider: "openai-codex"),
            now: Date()
        ) {
            if let live = try? await fetchLive(credential: credential) {
                return live
            }
        }
        guard let event = Self.latestRateLimitEvent() else {
            throw ProviderError.authRequired(hint: "Sign in to Codex (codex login) or omp")
        }
        return ProviderSnapshot(
            providerID: id,
            fetchedAt: event.timestamp,
            status: .ok,
            metrics: Self.metrics(from: event.rateLimits)
        )
    }

    // MARK: - Live endpoint

    private struct CodexAuth: Decodable {
        struct Tokens: Decodable {
            let accessToken: String?
            let accountId: String?
        }
        let tokens: Tokens?
    }

    struct LiveCredential: Equatable {
        let accessToken: String
        let accountId: String
    }

    /// Pure candidate assembly: Codex CLI's auth.json first (existing
    /// behavior preserved; it carries no expiry field, so present means
    /// candidate), omp second when unexpired and carrying the account id
    /// the ChatGPT-Account-Id header requires.
    static func liveCredentials(
        authJSON: Data?,
        omp: OmpOAuthCredential?,
        now: Date
    ) -> [LiveCredential] {
        var candidates: [LiveCredential] = []

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        if let authJSON,
           let auth = try? decoder.decode(CodexAuth.self, from: authJSON),
           let token = auth.tokens?.accessToken,
           let account = auth.tokens?.accountId {
            candidates.append(LiveCredential(accessToken: token, accountId: account))
        }

        if let omp,
           !omp.isExpired(now: now),
           let account = omp.accountId {
            let candidate = LiveCredential(accessToken: omp.accessToken, accountId: account)
            if !candidates.contains(candidate) {
                candidates.append(candidate)
            }
        }

        return candidates
    }

    struct WhamUsage: Decodable {
        struct Window: Decodable {
            let usedPercent: Double?
            let limitWindowSeconds: Double?
            let resetAt: Double?  // unix seconds
        }
        struct RateLimit: Decodable {
            let primaryWindow: Window?
            let secondaryWindow: Window?
        }
        let rateLimit: RateLimit?
        let credits: Credits?
    }

    /// Shared by the live endpoint and the persisted session snapshot.
    /// The backend currently sends balance as a decimal string, but accepting
    /// a JSON number keeps this undocumented boundary tolerant of drift.
    struct Credits: Decodable {
        let hasCredits: Bool?
        let unlimited: Bool?
        let balance: Double?

        private enum CodingKeys: String, CodingKey {
            case hasCredits
            case unlimited
            case balance
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            hasCredits = try container.decodeIfPresent(Bool.self, forKey: .hasCredits)
            unlimited = try container.decodeIfPresent(Bool.self, forKey: .unlimited)
            if let number = try? container.decode(Double.self, forKey: .balance) {
                balance = number
            } else if let string = try? container.decode(String.self, forKey: .balance) {
                balance = Double(string)
            } else {
                balance = nil
            }
        }
    }

    private func fetchLive(credential: LiveCredential) async throws -> ProviderSnapshot {
        var request = URLRequest(url: Self.usageURL)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("tokmon/0.1.0 (github.com/obrien-matthew/tokmon)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let usage = try decoder.decode(WhamUsage.self, from: data)
        let metrics = Self.metrics(from: usage)
        guard !metrics.isEmpty else {
            throw URLError(.cannotParseResponse)
        }
        return ProviderSnapshot(providerID: id, fetchedAt: Date(), status: .ok, metrics: metrics)
    }

    static func metrics(from usage: WhamUsage) -> [UsageMetric] {
        var metrics: [UsageMetric] = []
        let windows = [
            ("primary", usage.rateLimit?.primaryWindow),
            ("secondary", usage.rateLimit?.secondaryWindow),
        ]
        for (metricID, window) in windows {
            guard let window, let usedPercent = window.usedPercent else { continue }
            metrics.append(Self.windowMetric(
                id: metricID,
                usedPercent: usedPercent,
                durationSeconds: window.limitWindowSeconds,
                resetsAt: window.resetAt.map { Date(timeIntervalSince1970: $0) }
            ))
        }
        if let credits = creditsMetric(from: usage.credits) {
            metrics.append(credits)
        }
        return metrics
    }

    // MARK: - Session file fallback

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
        let credits: Credits?
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
        let sessionsDirectory = codexDirectory.appendingPathComponent("sessions", isDirectory: true)
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

    static func metrics(from limits: RateLimits) -> [UsageMetric] {
        var metrics: [UsageMetric] = []
        for (metricID, window) in [("primary", limits.primary), ("secondary", limits.secondary)] {
            guard let window, let usedPercent = window.usedPercent else { continue }
            metrics.append(windowMetric(
                id: metricID,
                usedPercent: usedPercent,
                durationSeconds: window.windowMinutes.map { $0 * 60 },
                resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: $0) }
            ))
        }
        if let credits = creditsMetric(from: limits.credits) {
            metrics.append(credits)
        }
        return metrics
    }

    static func creditsMetric(from credits: Credits?) -> UsageMetric? {
        guard let credits,
              credits.unlimited != true,
              let balance = credits.balance,
              balance.isFinite,
              balance >= 0
        else { return nil }

        return UsageMetric(
            id: "credits-remaining",
            label: "Credits remaining",
            kind: .quota,
            used: balance,
            limit: nil,
            unit: .credits,
            window: nil
        )
    }

    // MARK: - Shared mapping

    static func windowMetric(
        id: String, usedPercent: Double, durationSeconds: Double?, resetsAt: Date?
    ) -> UsageMetric {
        UsageMetric(
            id: id,
            label: label(forWindowSeconds: durationSeconds),
            kind: .rateLimitWindow,
            used: usedPercent,
            limit: 100,
            unit: .percent,
            window: MetricWindow(duration: durationSeconds, resetsAt: resetsAt)
        )
    }

    private static func label(forWindowSeconds seconds: Double?) -> String {
        switch seconds {
        case .some(18_000): "Session"
        case .some(604_800): "Weekly"
        case .some(let s): "\(Int(s / 3600))h window"
        case nil: "Usage"
        }
    }
}
