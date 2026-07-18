import Foundation

/// Month-to-date Anthropic API spend via the Admin cost report endpoint.
///
/// Requires an Admin API key (sk-ant-admin01-...) stored under the tokmon
/// Keychain service; the Admin API is unavailable for individual (non-org)
/// Console accounts. Amounts arrive as decimal strings in cents, bucketed
/// daily, paginated via has_more/next_page. Data lags real usage by ~5 min,
/// so a 15-minute poll is plenty.
struct AnthropicAPIProvider: UsageProvider {
    let id = "anthropic-api"
    let descriptor = ProviderDescriptor(displayName: "Anthropic API", systemImage: "dollarsign.circle", menuBarGlyph: "$")
    let refreshInterval: TimeInterval = 900

    static let keychainService = "tokmon"
    static let keychainAccount = "anthropic-admin-key"

    private static let baseURL = "https://api.anthropic.com/v1/organizations/cost_report"
    private static let keyHint = "Add an Admin API key in Settings"

    func fetchSnapshot() async throws -> ProviderSnapshot {
        guard let key = try? SecurityCLI.findGenericPassword(
            service: Self.keychainService, account: Self.keychainAccount
        ) else {
            throw ProviderError.authRequired(hint: Self.keyHint)
        }

        let now = Date()
        let totalCents = try await fetchMonthToDateCents(key: key, now: now)

        return ProviderSnapshot(
            providerID: id,
            fetchedAt: now,
            status: .ok,
            metrics: [
                UsageMetric(
                    id: "spend-mtd",
                    label: "Spend (MTD)",
                    kind: .spend,
                    used: totalCents / 100,
                    limit: nil,
                    unit: .usd,
                    window: nil
                )
            ]
        )
    }

    private func fetchMonthToDateCents(key: String, now: Date) async throws -> Double {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let monthStart = utcCalendar.date(
            from: utcCalendar.dateComponents([.year, .month], from: now)
        )!

        var total = 0.0
        var page: String?
        // Bounded loop: a month has at most 31 daily buckets, so a handful of
        // pages; the cap guards against a pagination bug looping forever.
        for _ in 0..<20 {
            var components = URLComponents(string: Self.baseURL)!
            components.queryItems = [
                URLQueryItem(name: "starting_at", value: formatter.string(from: monthStart)),
                URLQueryItem(name: "ending_at", value: formatter.string(from: now)),
                URLQueryItem(name: "bucket_width", value: "1d"),
            ]
            if let page {
                components.queryItems?.append(URLQueryItem(name: "page", value: page))
            }

            var request = URLRequest(url: components.url!)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            switch http.statusCode {
            case 200:
                break
            case 401, 403:
                throw ProviderError.authRequired(hint: "Admin key rejected; check it in Settings")
            default:
                throw URLError(.badServerResponse, userInfo: [
                    NSLocalizedDescriptionKey: "Cost report returned HTTP \(http.statusCode)"
                ])
            }

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let report = try decoder.decode(CostReportPage.self, from: data)
            for bucket in report.data ?? [] {
                for result in bucket.results ?? [] {
                    if let amount = result.amount, let cents = Double(amount) {
                        total += cents
                    }
                }
            }
            guard report.hasMore == true, let next = report.nextPage else {
                return total
            }
            page = next
        }
        return total
    }

    struct CostReportPage: Decodable {
        struct Bucket: Decodable {
            struct Result: Decodable {
                let amount: String?
                let currency: String?
            }
            let results: [Result]?
        }
        let data: [Bucket]?
        let hasMore: Bool?
        let nextPage: String?
    }
}
