import Foundation

/// Exercises every metric kind and unit the universal UI must render.
/// Values drift with wall-clock time so refreshes visibly change the UI.
struct MockProvider: UsageProvider {
    let id = "mock-claude"
    let descriptor = ProviderDescriptor(displayName: "Mock Claude", systemImage: "sparkle")
    let refreshInterval: TimeInterval = 30
    let enabledByDefault = false

    func fetchSnapshot() async throws -> ProviderSnapshot {
        try await Task.sleep(for: .milliseconds(300))
        let now = Date()
        let t = now.timeIntervalSince1970
        let sessionResets = Date(timeIntervalSince1970: (t / 18_000).rounded(.up) * 18_000)
        let weeklyResets = Date(timeIntervalSince1970: (t / 604_800).rounded(.up) * 604_800)

        return ProviderSnapshot(
            providerID: id,
            fetchedAt: now,
            status: .ok,
            metrics: [
                UsageMetric(
                    id: "session",
                    label: "Session",
                    kind: .rateLimitWindow,
                    used: 55 + 30 * sin(t / 900),
                    limit: 100,
                    unit: .percent,
                    window: MetricWindow(duration: 18_000, resetsAt: sessionResets)
                ),
                UsageMetric(
                    id: "weekly",
                    label: "Weekly",
                    kind: .rateLimitWindow,
                    used: 41 + 5 * sin(t / 3600),
                    limit: 100,
                    unit: .percent,
                    window: MetricWindow(duration: 604_800, resetsAt: weeklyResets)
                ),
                UsageMetric(
                    id: "spend-mtd",
                    label: "Spend (MTD)",
                    kind: .spend,
                    used: 12.34 + t.truncatingRemainder(dividingBy: 86_400) / 86_400 * 5,
                    limit: nil,
                    unit: .usd,
                    window: nil
                ),
                UsageMetric(
                    id: "token-quota",
                    label: "Token quota",
                    kind: .quota,
                    used: 340_000 + 1000 * (t.truncatingRemainder(dividingBy: 3600)),
                    limit: 10_000_000,
                    unit: .tokens,
                    window: nil
                ),
            ]
        )
    }
}

/// Succeeds once, then reports authRequired forever — exercises the
/// "cached gauges shown alongside an auth hint" path and the degraded
/// menu bar title, since its session gauge starts most-constrained.
final class MockDegradingProvider: UsageProvider, Sendable {
    let id = "mock-degrading"
    let descriptor = ProviderDescriptor(displayName: "Mock Codex", systemImage: "terminal")
    let refreshInterval: TimeInterval = 45
    let enabledByDefault = false

    private let fetchCounter = Counter()

    func fetchSnapshot() async throws -> ProviderSnapshot {
        try await Task.sleep(for: .milliseconds(200))
        let count = await fetchCounter.next()
        guard count == 1 else {
            throw ProviderError.authRequired(hint: "Open Mock CLI to sign in")
        }
        let now = Date()
        return ProviderSnapshot(
            providerID: id,
            fetchedAt: now,
            status: .ok,
            metrics: [
                UsageMetric(
                    id: "session",
                    label: "Session",
                    kind: .rateLimitWindow,
                    used: 88,
                    limit: 100,
                    unit: .percent,
                    window: MetricWindow(duration: 18_000, resetsAt: now.addingTimeInterval(4200))
                ),
                UsageMetric(
                    id: "weekly",
                    label: "Weekly",
                    kind: .rateLimitWindow,
                    used: 63,
                    limit: 100,
                    unit: .percent,
                    window: MetricWindow(duration: 604_800, resetsAt: now.addingTimeInterval(3.2 * 86_400))
                ),
            ]
        )
    }
}

private actor Counter {
    private var n = 0

    func next() -> Int {
        n += 1
        return n
    }
}
