import Foundation
import XCTest
@testable import tokmon

/// Opt-in live smoke: proves the omp-sourced credentials are accepted by
/// the real usage endpoints, exercising the same headers the providers
/// send. Skipped unless TOKMON_LIVE_SMOKE=1 (never runs in CI); requires
/// a signed-in omp on this machine. Never prints tokens.
final class OmpLiveSmokeTests: XCTestCase {
    private func requireSmoke() throws {
        guard ProcessInfo.processInfo.environment["TOKMON_LIVE_SMOKE"] == "1" else {
            throw XCTSkip("Set TOKMON_LIVE_SMOKE=1 to run live endpoint smoke")
        }
    }

    func testAnthropicUsageEndpointAcceptsOmpToken() async throws {
        try requireSmoke()
        guard let credential = OmpCredentialStore.credential(provider: "anthropic"),
              !credential.isExpired()
        else {
            throw XCTSkip("No unexpired omp anthropic credential on this machine")
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)

        let usage = try ClaudeSubscriptionProvider.makeDecoder()
            .decode(ClaudeSubscriptionProvider.OAuthUsage.self, from: data)
        XCTAssertFalse(ClaudeSubscriptionProvider.metrics(from: usage).isEmpty)
    }

    func testWhamUsageEndpointAcceptsOmpToken() async throws {
        try requireSmoke()
        guard let credential = OmpCredentialStore.credential(provider: "openai-codex"),
              !credential.isExpired(),
              let accountId = credential.accountId
        else {
            throw XCTSkip("No unexpired omp openai-codex credential on this machine")
        }

        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("tokmon/0.1.0 (github.com/obrien-matthew/tokmon)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let usage = try decoder.decode(CodexProvider.WhamUsage.self, from: data)
        XCTAssertFalse(CodexProvider.metrics(from: usage).isEmpty)
    }
}
