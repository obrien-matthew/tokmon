import Foundation

enum ProviderRegistry {
    /// Every provider tokmon knows about, in display order.
    static func allProviders() -> [any UsageProvider] {
        [
            ClaudeSubscriptionProvider(),
            AnthropicAPIProvider(),
            MockProvider(),
            MockDegradingProvider(),
        ]
    }

    static func enabledProviders(settings: AppSettings) -> [any UsageProvider] {
        allProviders().filter {
            settings.isEnabled($0.id, default: $0.enabledByDefault)
        }
    }
}
