import Foundation

// The "narrow waist": every provider compiles its data source into these
// types, and the UI renders them blindly. No provider-specific fields may
// be added here — a provider needing richer display emits more metrics.

enum MetricKind: String, Codable, Sendable {
    case rateLimitWindow
    case spend
    case quota
}

enum MetricUnit: String, Codable, Sendable {
    case percent
    case usd
    case tokens
    case requests
}

struct MetricWindow: Codable, Sendable, Equatable {
    var duration: TimeInterval?
    var resetsAt: Date?
}

struct UsageMetric: Codable, Sendable, Equatable, Identifiable {
    /// Stable within a provider only; cross-provider keys must combine
    /// this with the provider ID.
    var id: String
    var label: String
    var kind: MetricKind
    var used: Double
    /// Convention: for `.percent` metrics this is always 100.
    /// nil means an open-ended counter: no bar, no color escalation,
    /// never eligible for the menu bar title.
    var limit: Double?
    var unit: MetricUnit
    var window: MetricWindow?

    var fraction: Double? {
        guard let limit, limit > 0 else { return nil }
        return min(max(used / limit, 0), 1)
    }
}

enum ProviderStatus: Codable, Sendable, Equatable {
    case ok
    case authRequired(hint: String)
    case error(message: String)

    var isOK: Bool {
        if case .ok = self { return true }
        return false
    }
}

struct ProviderSnapshot: Codable, Sendable, Equatable {
    var providerID: String
    var fetchedAt: Date
    var status: ProviderStatus
    var metrics: [UsageMetric]
}

struct ProviderDescriptor: Sendable, Equatable {
    var displayName: String
    var systemImage: String
}

enum ProviderError: Error {
    case authRequired(hint: String)
}

protocol UsageProvider: Sendable {
    var id: String { get }
    var descriptor: ProviderDescriptor { get }
    var refreshInterval: TimeInterval { get }
    func fetchSnapshot() async throws -> ProviderSnapshot
}
