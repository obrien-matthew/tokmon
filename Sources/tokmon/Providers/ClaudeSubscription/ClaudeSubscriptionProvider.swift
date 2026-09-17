import Foundation

/// Claude subscription limits (5h session, weekly) via the same usage
/// endpoint the /usage command reads, authenticated with the first working
/// credential from an ordered list: Claude Code's Keychain OAuth token,
/// then oh-my-pi's stored token for the same account (fallback for when
/// Claude Code's token expires unused because work happens in omp).
///
/// tokmon never refreshes or writes tokens — refresh-token rotation would
/// invalidate the owning harness's copy. All candidates expired surfaces as
/// authRequired with cached gauges retained; that is a normal state between
/// coding sessions, not an error.
///
/// Known limitation: nothing enforces that omp is signed into the same
/// account as Claude Code. If it isn't, a fallback fetch reports the omp
/// account's usage under this gauge.
struct ClaudeSubscriptionProvider: UsageProvider {
    let id = "claude-subscription"
    let descriptor = ProviderDescriptor(displayName: "Claude", systemImage: "asterisk.circle", menuBarGlyph: "C")
    // A 5h window doesn't need finer resolution, and this is an undocumented
    // endpoint being called by a foreign client — keep the cadence polite.
    let refreshInterval: TimeInterval = 300

    private static let keychainService = "Claude Code-credentials"
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let signInHint = "Open Claude Code or omp to sign in"
    private static let refreshHint = "Open Claude Code or omp to refresh login"

    func fetchSnapshot() async throws -> ProviderSnapshot {
        let keychainJSON = try? await SecurityCLI.findGenericPassword(service: Self.keychainService)
        let omp = OmpCredentialStore.credential(provider: "anthropic")
        let resolution = Self.resolveTokens(
            keychainJSON: keychainJSON,
            omp: omp,
            now: Date()
        )
        Diag.claude.log("""
        resolve keychain=\(keychainJSON?.count ?? -1, privacy: .public) \
        omp=\(omp != nil, privacy: .public) \
        ompExpired=\(omp?.isExpired() ?? false, privacy: .public) \
        candidates=\(resolution.tokens.count, privacy: .public) \
        anyExpired=\(resolution.anyExpired, privacy: .public)
        """)
        guard !resolution.tokens.isEmpty else {
            throw ProviderError.authRequired(hint: resolution.anyExpired ? Self.refreshHint : Self.signInHint)
        }

        // A 401/403 with one candidate advances to the next (expiry-checked
        // tokens can still be revoked). At most two requests per poll, and
        // only on that path — the cadence stays polite.
        for token in resolution.tokens {
            var request = URLRequest(url: Self.usageURL)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

            let (data, response) = try await HTTPSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            switch http.statusCode {
            case 200:
                let usage = try Self.makeDecoder().decode(OAuthUsage.self, from: data)
                return ProviderSnapshot(
                    providerID: id,
                    fetchedAt: Date(),
                    status: .ok,
                    metrics: Self.metrics(from: usage)
                )
            case 401, 403:
                continue
            default:
                throw URLError(.badServerResponse, userInfo: [
                    NSLocalizedDescriptionKey: "Usage endpoint returned HTTP \(http.statusCode)"
                ])
            }
        }
        // Every candidate passed the expiry check yet was rejected — the
        // tokens exist but are no longer valid, so "refresh" is the hint.
        throw ProviderError.authRequired(hint: Self.refreshHint)
    }

    // MARK: - Credentials

    struct Credentials: Decodable {
        struct OAuth: Decodable {
            let accessToken: String
            let expiresAt: Double?  // milliseconds since epoch
        }
        let claudeAiOauth: OAuth
    }

    struct TokenResolution: Equatable {
        var tokens: [String]
        var anyExpired: Bool
    }

    /// Pure candidate assembly: Claude Code's Keychain credential first
    /// (existing behavior preserved), omp second. Expired or undecodable
    /// candidates are skipped; `anyExpired` records whether a credential
    /// existed but was stale, which selects the "refresh" hint over the
    /// "sign in" one.
    static func resolveTokens(
        keychainJSON: String?,
        omp: OmpOAuthCredential?,
        now: Date
    ) -> TokenResolution {
        var resolution = TokenResolution(tokens: [], anyExpired: false)

        if let json = keychainJSON,
           let data = json.data(using: .utf8),
           let credentials = try? JSONDecoder().decode(Credentials.self, from: data) {
            if let expiresAt = credentials.claudeAiOauth.expiresAt,
               expiresAt / 1000 < now.timeIntervalSince1970 {
                resolution.anyExpired = true
            } else {
                resolution.tokens.append(credentials.claudeAiOauth.accessToken)
            }
        }

        if let omp {
            if omp.isExpired(now: now) {
                resolution.anyExpired = true
            } else if !resolution.tokens.contains(omp.accessToken) {
                resolution.tokens.append(omp.accessToken)
            }
        }

        return resolution
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

        let reportedUsed = usage.spend?.used?.dollars
        let reportedLimit = usage.spend?.limit?.dollars
        let used = reportedUsed.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let limit = reportedLimit.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        if used != nil || limit != nil {
            metrics.append(UsageMetric(
                id: "extra-credits", label: "Extra credits", kind: .spend,
                used: used ?? 0, limit: limit, unit: .usd,
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
