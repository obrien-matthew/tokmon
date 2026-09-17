import Foundation

/// The session every provider fetches through.
///
/// `URLSession.shared` defaults `timeoutIntervalForResource` to 604800 —
/// seven days — so a connection that half-dies across a sleep/wake or a
/// DNS blackhole hangs effectively forever. Observed in the wild: single
/// requests outstanding for 939s and 1061s, which parked the provider's
/// whole polling loop.
///
/// These gauges are polled every 5 minutes and nothing downstream cares
/// about a missed cycle, so failing fast is strictly better than waiting:
/// the next tick retries.
enum HTTPSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // No response body within 15s means the far end is gone.
        configuration.timeoutIntervalForRequest = 15
        // Hard ceiling on one fetch, including redirects and retries.
        configuration.timeoutIntervalForResource = 30
        // Fail now rather than parking the request until connectivity
        // returns; the polling loop is the retry mechanism.
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()
}
