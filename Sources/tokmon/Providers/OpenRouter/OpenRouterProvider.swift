import Foundation

/// OpenRouter per-key spend cap and prepaid credit balance.
///
/// Two independent endpoints, both authenticated with the same bare API
/// key (read-only; tokmon never writes or rotates keys):
///
/// - `/api/v1/key` — the calling key's own spend cap. `limit` and
///   `limit_remaining` are a real, API-enforced meter, so this is the
///   gauge. Keys without a cap report `limit: null` and get no bar.
/// - `/api/v1/credits` — lifetime `total_credits` purchased and
///   `total_usage` spent; the difference is the account balance. Both
///   figures are lifetime cumulative, so there is no honest denominator
///   to draw a bar against: it renders as an open-ended counter, the
///   same shape as Codex's credit balance. It is also the only
///   account-wide number here — the key meter cannot see spend through
///   other keys. The docs say this route wants a management key, but
///   ordinary inference keys are accepted today, so a 403 is a soft
///   failure: the cap gauge still stands alone.
///
/// Key resolution order: omp's credential store (`api_key` row for
/// provider "openrouter"), then a Keychain generic password under
/// service "tokmon-openrouter". No environment variable — a GUI app
/// launched from Finder or launchd inherits no shell environment, so
/// `OPENROUTER_API_KEY` would silently work only under `swift run`.
struct OpenRouterProvider: UsageProvider {
    let id = "openrouter"
    let descriptor = ProviderDescriptor(
        displayName: "OpenRouter",
        systemImage: "arrow.triangle.branch",
        menuBarGlyph: "O"
    )
    let refreshInterval: TimeInterval = 300
    /// Needs a key most users won't have; opting in avoids showing them
    /// an auth hint for an account they don't own.
    let enabledByDefault = false

    private static let creditsURL = URL(string: "https://openrouter.ai/api/v1/credits")!
    private static let keyURL = URL(string: "https://openrouter.ai/api/v1/key")!
    private static let authHint = "Add an OpenRouter key to omp or Keychain (tokmon-openrouter)"

    func fetchSnapshot() async throws -> ProviderSnapshot {
        guard let key = Self.resolveKey() else {
            throw ProviderError.authRequired(hint: Self.authHint)
        }

        async let creditsCall = Self.fetch(Credits.self, from: Self.creditsURL, key: key)
        async let keyCall = Self.fetch(KeyInfo.self, from: Self.keyURL, key: key)
        let credits = await creditsCall
        let keyInfo = await keyCall

        let metrics = Self.metrics(credits: credits.value, key: keyInfo.value)
        guard !metrics.isEmpty else {
            // Both calls came back empty. A 401 anywhere means the key
            // itself is the problem and cached gauges should show a
            // hint; anything else is transient and degrades instead.
            if credits.unauthorized || keyInfo.unauthorized {
                throw ProviderError.authRequired(hint: Self.authHint)
            }
            throw credits.error ?? keyInfo.error ?? URLError(.cannotParseResponse)
        }
        return ProviderSnapshot(providerID: id, fetchedAt: Date(), status: .ok, metrics: metrics)
    }

    // MARK: - Credentials

    static func resolveKey() -> String? {
        if let key = OmpCredentialStore.apiKey(provider: "openrouter"), !key.isEmpty {
            return key
        }
        guard let keychain = try? SecurityCLI.findGenericPassword(service: "tokmon-openrouter"),
              !keychain.isEmpty
        else {
            return nil
        }
        return keychain
    }

    // MARK: - Payloads

    /// Both endpoints wrap their payload in `data`.
    private struct Envelope<Payload: Decodable>: Decodable {
        let data: Payload
    }

    struct Credits: Decodable {
        let totalCredits: Double?
        let totalUsage: Double?

        var balance: Double? {
            guard let totalCredits, let totalUsage,
                  totalCredits.isFinite, totalUsage.isFinite
            else { return nil }
            return totalCredits - totalUsage
        }
    }

    struct KeyInfo: Decodable {
        let limit: Double?
        let limitRemaining: Double?
        let limitReset: String?
    }

    private struct Outcome<Payload> {
        var value: Payload?
        var error: Error?
        var unauthorized = false
    }

    private static func fetch<Payload: Decodable>(
        _ type: Payload.Type,
        from url: URL,
        key: String
    ) async -> Outcome<Payload> {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("tokmon/0.1.0 (github.com/obrien-matthew/tokmon)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return Outcome(error: URLError(.badServerResponse))
            }
            guard http.statusCode == 200 else {
                return Outcome(
                    error: URLError(.badServerResponse),
                    unauthorized: http.statusCode == 401
                )
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return Outcome(value: try decoder.decode(Envelope<Payload>.self, from: data).data)
        } catch {
            return Outcome(error: error)
        }
    }

    // MARK: - Mapping

    /// Pure: the provider's entire display logic, testable without network.
    /// Cap first — it is the gauge; the balance is context below it.
    static func metrics(credits: Credits?, key: KeyInfo?) -> [UsageMetric] {
        var metrics: [UsageMetric] = []
        if let cap = keyCapMetric(key) {
            metrics.append(cap)
        }
        if let balance = balanceMetric(credits?.balance) {
            metrics.append(balance)
        }
        return metrics
    }

    /// `used` comes from the API's own arithmetic (`limit - limit_remaining`)
    /// rather than a `usage_*` field: the two disagree by rounding (a
    /// `usage_monthly` of 25.006 against a 25 cap would render the
    /// self-inconsistent `$25.01 / $25.00`), and only the difference is
    /// what OpenRouter enforces.
    ///
    /// No `resetsAt`: `limit_reset` names a cadence, not a boundary, and
    /// nothing says whether it is calendar- or key-anniversary-based, so
    /// a countdown would be invented.
    static func keyCapMetric(_ key: KeyInfo?) -> UsageMetric? {
        guard let key, let limit = key.limit, limit.isFinite, limit > 0 else { return nil }
        let remaining = key.limitRemaining.flatMap { $0.isFinite ? $0 : nil } ?? limit
        return UsageMetric(
            id: "key-cap",
            label: keyCapLabel(reset: key.limitReset),
            kind: .spend,
            used: min(max(limit - remaining, 0), limit),
            limit: limit,
            unit: .usd,
            window: nil
        )
    }

    /// Open-ended by design: lifetime totals give no honest denominator.
    static func balanceMetric(_ balance: Double?) -> UsageMetric? {
        guard let balance, balance.isFinite else { return nil }
        return UsageMetric(
            id: "credits",
            label: "Balance",
            kind: .spend,
            used: max(balance, 0),
            limit: nil,
            unit: .usd,
            window: nil
        )
    }

    private static func keyCapLabel(reset: String?) -> String {
        guard let reset, !reset.isEmpty else { return "Key spend (lifetime)" }
        return "Key spend (\(reset))"
    }
}
