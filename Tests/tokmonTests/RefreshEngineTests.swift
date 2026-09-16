import Foundation
import XCTest
@testable import tokmon

/// Regression coverage for the wedge observed in the field: one fetch that
/// never returns parked a provider's polling loop for 938s, and every
/// recovery path (loop, menu open, wake, network restore) no-opped because
/// it was gated on the in-flight entry.
final class RefreshEngineTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokmon-engine-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testHungFetchIsAbandonedAndTheProviderStillRecovers() async throws {
        let provider = HangingProvider(id: "hang")
        let collector = Collector()
        let engine = RefreshEngine(
            providers: [provider],
            cache: SnapshotCache(directory: directory),
            initial: [:],
            fetchDeadline: 0.2,
            publish: { await collector.append($0) }
        )

        // First fetch hangs well past the deadline.
        await engine.refreshAll(force: true)
        try await Task.sleep(for: .seconds(0.6))

        let degraded = await collector.snapshots
        XCTAssertEqual(degraded.count, 1, "the deadline must end the fetch instead of hanging")
        XCTAssertFalse(try XCTUnwrap(degraded.first).status.isOK)

        // The slot must be free again: a later refresh has to go through,
        // which is exactly what the wedge prevented.
        await provider.release()
        await engine.refreshAll(force: true)
        try await Task.sleep(for: .seconds(0.4))

        let recovered = await collector.snapshots
        XCTAssertTrue(
            recovered.contains { $0.status.isOK },
            "provider must be reachable again after a hung fetch"
        )
        let attempts = await provider.attempts
        XCTAssertGreaterThanOrEqual(attempts, 2)
    }

    /// The polling loop awaits its own in-flight task, so the deadline
    /// must be enforced inside the fetch — not only by the overdue-cancel
    /// in `startRefresh`, which needs an external nudge (menu open, wake,
    /// network restore) to fire. Here `start()` is the only trigger and
    /// nothing else touches the engine.
    func testPollingLoopIterationEndsWithoutAnExternalTrigger() async throws {
        let provider = HangingProvider(id: "hang")
        let collector = Collector()
        let engine = RefreshEngine(
            providers: [provider],
            cache: SnapshotCache(directory: directory),
            initial: [:],
            fetchDeadline: 0.2,
            publish: { await collector.append($0) }
        )

        await engine.start()
        try await Task.sleep(for: .seconds(0.8))

        let published = await collector.snapshots
        XCTAssertFalse(
            published.isEmpty,
            "the loop must come back from a hung fetch on its own"
        )
        XCTAssertFalse(try XCTUnwrap(published.first).status.isOK)
    }

    func testCachePersistsSuccessesToItsOwnDirectory() async throws {
        let provider = HangingProvider(id: "hang")
        await provider.release()
        let engine = RefreshEngine(
            providers: [provider],
            cache: SnapshotCache(directory: directory),
            initial: [:],
            fetchDeadline: 1,
            publish: { _ in }
        )

        await engine.refreshAll(force: true)
        try await Task.sleep(for: .seconds(0.4))

        let reloaded = SnapshotCache(directory: directory).load()
        XCTAssertEqual(reloaded["hang"]?.metrics.count, 1)
    }
}

private actor Collector {
    var snapshots: [ProviderSnapshot] = []

    func append(_ snapshot: ProviderSnapshot) {
        snapshots.append(snapshot)
    }
}

/// Hangs until released, mimicking a connection that dies across sleep.
/// Deliberately ignores cancellation for the first call — the real hang
/// (a synchronous Keychain `security` call, or a socket the OS has not
/// given up on) cannot be cancelled either.
private actor Hang {
    var released = false

    func release() {
        released = true
    }
}

private final class HangingProvider: UsageProvider, @unchecked Sendable {
    let id: String
    let descriptor: ProviderDescriptor
    let refreshInterval: TimeInterval = 300
    private let hang = Hang()
    private let counter = Counter()

    var attempts: Int {
        get async { await counter.value }
    }

    init(id: String) {
        self.id = id
        self.descriptor = ProviderDescriptor(displayName: id, systemImage: "gauge", menuBarGlyph: "H")
    }

    func release() async {
        await hang.release()
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        await counter.increment()
        while await !hang.released {
            // Uncancellable sleep: the engine's deadline, not cooperative
            // cancellation, is what must end this.
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return ProviderSnapshot(
            providerID: id,
            fetchedAt: Date(),
            status: .ok,
            metrics: [UsageMetric(
                id: "m", label: "M", kind: .spend,
                used: 1, limit: nil, unit: .usd, window: nil
            )]
        )
    }
}

private actor Counter {
    var value = 0

    func increment() {
        value += 1
    }
}
