import Foundation

/// Claude subscription limits (5h session, weekly) via Claude Code's OAuth
/// credentials and the same usage endpoint the /usage command reads.
///
/// tokmon never refreshes or writes tokens — refresh-token rotation would
/// invalidate Claude Code's copy. An expired token surfaces as authRequired
/// with cached gauges retained; that is a normal state between Claude Code
/// sessions, not an error.
struct ClaudeSubscriptionProvider: UsageProvider {
    let id = "claude-subscription"
    let descriptor = ProviderDescriptor(displayName: "Claude", systemImage: "asterisk.circle")
    // A 5h window doesn't need finer resolution, and this is an undocumented
    // endpoint being called by a foreign client — keep the cadence polite.
    let refreshInterval: TimeInterval = 300

    private static let keychainService = "Claude Code-credentials"
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let signInHint = "Open Claude Code to sign in"

    func fetchSnapshot() async throws -> ProviderSnapshot {
        let token = try loadAccessToken()
        var request = URLRequest(url: Self.usageURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            throw ProviderError.authRequired(hint: Self.signInHint)
        default:
            throw URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "Usage endpoint returned HTTP \(http.statusCode)"
            ])
        }

        let usage = try Self.makeDecoder().decode(OAuthUsage.self, from: data)
        return ProviderSnapshot(
            providerID: id,
            fetchedAt: Date(),
            status: .ok,
            metrics: Self.metrics(from: usage)
        )
    }

    // MARK: - Credentials

    private struct Credentials: Decodable {
        struct OAuth: Decodable {
            let accessToken: String
            let expiresAt: Double?  // milliseconds since epoch
        }
        let claudeAiOauth: OAuth
    }

    private func loadAccessToken() throws -> String {
        let json: String
        do {
            json = try SecurityCLI.findGenericPassword(service: Self.keychainService)
        } catch {
            throw ProviderError.authRequired(hint: Self.signInHint)
        }
        guard let data = json.data(using: .utf8),
              let credentials = try? JSONDecoder().decode(Credentials.self, from: data)
        else {
            throw ProviderError.authRequired(hint: Self.signInHint)
        }
        if let expiresAt = credentials.claudeAiOauth.expiresAt,
           expiresAt / 1000 < Date().timeIntervalSince1970 {
            throw ProviderError.authRequired(hint: "Open Claude Code to refresh login")
        }
        return credentials.claudeAiOauth.accessToken
    }

    // MARK: - Response mapping

    // Shape verified empirically 2026-07-18. The `limits` array is the
    // general source (new limit kinds appear there without client changes);
    // five_hour/seven_day are the fallback for older response shapes.
    struct OAuthUsage: Decodable {
        struct Window: Decodable {
            let utilization: Double?
            let resetsAt: Date?
        }
        struct LimitEntry: Decodable {
            struct Scope: Decodable {
                struct Model: Decodable { let displayName: String? }
                let model: Model?
            }
            let kind: String?
            let group: String?
            let percent: Double?
            let resetsAt: Date?
            let scope: Scope?
        }
        struct Money: Decodable {
            let amountMinor: Double?
            let exponent: Int?

            var dollars: Double? {
                guard let amountMinor else { return nil }
                return amountMinor / pow(10, Double(exponent ?? 2))
            }
        }
        struct Spend: Decodable {
            let used: Money?
            let limit: Money?
        }
        let fiveHour: Window?
        let sevenDay: Window?
        let limits: [LimitEntry]?
        let spend: Spend?
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        // Timestamps carry fractional seconds, which stock .iso8601 rejects.
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: string) { return date }
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Unrecognized date: \(string)"
            ))
        }
        return decoder
    }

    static func metrics(from usage: OAuthUsage) -> [UsageMetric] {
        var metrics: [UsageMetric] = []

        let limitEntries = (usage.limits ?? []).filter { $0.percent != nil }
        if !limitEntries.isEmpty {
            for entry in limitEntries {
                metrics.append(metric(from: entry))
            }
        } else {
            if let session = usage.fiveHour, let utilization = session.utilization {
                metrics.append(UsageMetric(
                    id: "session", label: "Session", kind: .rateLimitWindow,
                    used: utilization, limit: 100, unit: .percent,
                    window: MetricWindow(duration: 18_000, resetsAt: session.resetsAt)
                ))
            }
            if let weekly = usage.sevenDay, let utilization = weekly.utilization {
                metrics.append(UsageMetric(
                    id: "weekly", label: "Weekly", kind: .rateLimitWindow,
                    used: utilization, limit: 100, unit: .percent,
                    window: MetricWindow(duration: 604_800, resetsAt: weekly.resetsAt)
                ))
            }
        }

        if let used = usage.spend?.used?.dollars, used > 0 {
            metrics.append(UsageMetric(
                id: "extra-credits", label: "Extra credits", kind: .spend,
                used: used, limit: usage.spend?.limit?.dollars, unit: .usd,
                window: nil
            ))
        }

        return metrics
    }

    private static func metric(from entry: OAuthUsage.LimitEntry) -> UsageMetric {
        let kind = entry.kind ?? "limit"
        let modelName = entry.scope?.model?.displayName
        let label: String
        switch kind {
        case "session":
            label = "Session"
        case "weekly_all":
            label = "Weekly"
        case "weekly_scoped":
            label = modelName.map { "Weekly (\($0))" } ?? "Weekly (scoped)"
        default:
            // Unknown limit kinds still render rather than being dropped.
            label = kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
        let duration: TimeInterval? = switch entry.group {
        case "session": 18_000
        case "weekly": 604_800
        default: nil
        }
        return UsageMetric(
            id: modelName.map { "\(kind)-\($0)" } ?? kind,
            label: label,
            kind: .rateLimitWindow,
            used: entry.percent ?? 0,
            limit: 100,
            unit: .percent,
            window: MetricWindow(duration: duration, resetsAt: entry.resetsAt)
        )
    }
}
