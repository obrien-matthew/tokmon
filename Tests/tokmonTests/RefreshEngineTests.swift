import Foundation
import XCTest
@testable import tokmon

/// Regression coverage for the wedge observed in the field: one fetch that
/// never returned parked a provider's polling loop for 938s, because every
/// recovery path (loop, menu open, wake, network restore) is gated on the
/// provider's in-flight entry.
///
/// Synchronisation is by signal, not by sleeping long enough: the provider
/// announces each attempt and the collector awaits publications, so a
/// loaded CI runner slows these tests down rather than failing them.
final class RefreshEngineTests: XCTestCase {
    private var directory: URL!
    private var engine: RefreshEngine?

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokmon-engine-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        // start() installs a wake observer, an NWPathMonitor, and a
        // per-provider loop; without this they outlive the test.
        await engine?.stop()
        engine = nil
        try FileManager.default.removeItem(at: directory)
    }

    private func makeEngine(
        providers: [any UsageProvider],
        fetchDeadline: TimeInterval,
        collector: Collector
    ) -> RefreshEngine {
        let engine = RefreshEngine(
            providers: providers,
            cache: SnapshotCache(directory: directory),
            initial: [:],
            fetchDeadline: fetchDeadline,
            publish: { await collector.append($0) }
        )
        self.engine = engine
        return engine
    }

    func testHungFetchIsAbandonedAndTheProviderStillRecovers() async throws {
        let provider = ControllableProvider(id: "hang")
        let collector = Collector()
        let engine = makeEngine(providers: [provider], fetchDeadline: 0.2, collector: collector)

        await engine.refreshAll(force: true)
        let degraded = try await collector.next()
        XCTAssertFalse(degraded.status.isOK, "the deadline must end the fetch instead of hanging")

        // The slot must be free again: a later refresh has to go through,
        // which is exactly what the wedge prevented.
        await provider.release()
        await engine.refreshAll(force: true)
        let recovered = try await collector.next()
        XCTAssertTrue(recovered.status.isOK, "provider must be reachable after a hung fetch")
        let attempts = await provider.attempts
        XCTAssertGreaterThanOrEqual(attempts, 2)
    }

    /// The polling loop awaits its own in-flight task, so the deadline
    /// must be enforced inside the fetch — not only by the overdue-cancel
    /// in `startRefresh`, which needs an external nudge to fire. Here
    /// `start()` is the only trigger and nothing else touches the engine.
    func testPollingLoopIterationEndsWithoutAnExternalTrigger() async throws {
        let provider = ControllableProvider(id: "hang")
        let collector = Collector()
        let engine = makeEngine(providers: [provider], fetchDeadline: 0.2, collector: collector)

        await engine.start()

        let published = try await collector.next()
        XCTAssertFalse(published.status.isOK, "the loop must come back from a hung fetch on its own")
    }

    /// A fetch abandoned at the deadline keeps running. When it finally
    /// fails, it must not overwrite the result its replacement already
    /// published, nor count as a failure against the current attempt.
    func testSupersededFetchCannotClobberItsReplacement() async throws {
        let provider = ControllableProvider(id: "hang")
        let collector = Collector()
        let engine = makeEngine(providers: [provider], fetchDeadline: 0.2, collector: collector)

        // Attempt 1 hangs past the deadline and is abandoned.
        await engine.refreshAll(force: true)
        let timedOut = try await collector.next()
        XCTAssertFalse(timedOut.status.isOK)

        // Attempt 2 succeeds while attempt 1 is still running.
        await provider.release()
        await engine.refreshAll(force: true)
        let succeeded = try await collector.next()
        XCTAssertTrue(succeeded.status.isOK)

        // Now let the abandoned attempt 1 fail. Its failure belongs to a
        // generation nobody is waiting on and must be dropped.
        await provider.failOutstanding()
        try await Task.sleep(for: .seconds(0.3))

        let all = await collector.snapshots
        XCTAssertTrue(
            try XCTUnwrap(all.last).status.isOK,
            "a superseded fetch must not republish over a newer success"
        )
        XCTAssertEqual(all.filter { !$0.status.isOK }.count, 1, "stale failure must not re-degrade")
    }

    /// The overdue-cancel path in `startRefresh` clears the in-flight slot
    /// before the debounce check, so the debounce must not then decline to
    /// start the replacement. It is defensive: while `performFetch`
    /// self-enforces the deadline, the slot is always cleared by the fetch
    /// itself, so the branch is unreachable today. Asserting it needs a
    /// stuck `performFetch`, which the deadline exists to prevent — the
    /// guard stays as protection against a future change that reintroduces
    /// one, and `testHungFetchIsAbandonedAndTheProviderStillRecovers`
    /// covers the path a user actually takes.

    func testCachePersistsSuccessesToItsOwnDirectory() async throws {
        let provider = ControllableProvider(id: "hang")
        await provider.release()
        let collector = Collector()
        let engine = makeEngine(providers: [provider], fetchDeadline: 1, collector: collector)

        await engine.refreshAll(force: true)
        _ = try await collector.next()

        let reloaded = SnapshotCache(directory: directory).load()
        XCTAssertEqual(reloaded["hang"]?.metrics.count, 1)
    }
}

private struct CollectorTimeout: LocalizedError {
    let seconds: TimeInterval
    var errorDescription: String? { "No snapshot published within \(seconds)s" }
}

/// Awaits publications instead of sleeping for them.
private actor Collector {
    var snapshots: [ProviderSnapshot] = []
    private var consumed = 0
    private var waiter: CheckedContinuation<ProviderSnapshot?, Never>?

    func append(_ snapshot: ProviderSnapshot) {
        snapshots.append(snapshot)
        if let waiter {
            self.waiter = nil
            consumed += 1
            waiter.resume(returning: snapshot)
        }
    }

    /// The next publication not yet returned by `next()`. Fails fast
    /// rather than hanging the suite: a cancelled task cannot resume a
    /// checked continuation, so the timeout resumes the waiter itself.
    func next(timeout: TimeInterval = 5) async throws -> ProviderSnapshot {
        if consumed < snapshots.count {
            defer { consumed += 1 }
            return snapshots[consumed]
        }
        let deadline = Task { [weak self] in
            try await Task.sleep(for: .seconds(timeout))
            await self?.timeOutWaiter()
        }
        defer { deadline.cancel() }
        guard let snapshot = await withCheckedContinuation({ continuation in
            waiter = continuation
        }) else {
            throw CollectorTimeout(seconds: timeout)
        }
        return snapshot
    }

    private func timeOutWaiter() {
        guard let waiter else { return }
        self.waiter = nil
        waiter.resume(returning: nil)
    }
}

/// Hangs until released, mimicking a connection that dies across sleep.
/// Deliberately ignores cancellation: the real hangs this guards against
/// (an OS-level socket, a blocked `security` child) cannot be cancelled
/// either, and a cooperative stub would not exercise the deadline.
private final class ControllableProvider: UsageProvider, @unchecked Sendable {
    let id: String
    let descriptor: ProviderDescriptor
    let refreshInterval: TimeInterval = 300
    private let state = State()

    var attempts: Int {
        get async { await state.attempts }
    }

    init(id: String) {
        self.id = id
        self.descriptor = ProviderDescriptor(displayName: id, systemImage: "gauge", menuBarGlyph: "H")
    }

    func release() async {
        await state.set(.succeed)
    }

    /// Lets a still-running abandoned attempt finish, as a failure.
    func failOutstanding() async {
        await state.set(.fail)
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        await state.recordAttempt()
        while await state.mode == .hang {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if await state.mode == .fail {
            throw URLError(.cannotConnectToHost)
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

    private actor State {
        enum Mode { case hang, succeed, fail }
        var mode: Mode = .hang
        var attempts = 0

        func set(_ mode: Mode) {
            self.mode = mode
        }

        func recordAttempt() {
            attempts += 1
        }
    }
}
