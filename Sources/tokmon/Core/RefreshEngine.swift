import AppKit
import Foundation
import Network

/// Runs one polling loop per provider, with exponential backoff on failure,
/// per-provider in-flight dedup, and immediate refresh on menu open, system
/// wake, and network restoration.
actor RefreshEngine {
    private let providers: [any UsageProvider]
    private let cache: SnapshotCache
    /// Takes the attempt's sequence number so the consumer can drop a
    /// straggler that lands after a newer attempt already applied.
    private let publish: @Sendable (ProviderSnapshot, Int) async -> Void

    /// Last successful snapshot per provider; failures republish these
    /// metrics under a degraded status so the UI never goes blank.
    private var lastGood: [String: ProviderSnapshot]
    private var inFlight: [String: Task<Void, Never>] = [:]
    /// Bumped per started fetch so a completing task only clears its own
    /// `inFlight` entry. Without it, a cancelled straggler finishing after
    /// its replacement started would clear the replacement's slot and
    /// leave the watchdog blind.
    private var generation: [String: Int] = [:]
    /// Fetches that outlived their deadline and were abandoned, counted
    /// per provider so abandonment stays bounded.
    private struct Key: Hashable {
        let id: String
        let generation: Int
    }
    /// Live fetch tasks, so orphan bookkeeping is bounded by outstanding
    /// work rather than accumulating one entry per poll forever.
    private var pendingWork: Set<Key> = []
    private var orphaned: Set<Key> = []
    private var orphans: [String: Int] = [:]
    /// Fetch and deadline tasks by key, so `stop()` can cancel the work
    /// that actually holds a provider rather than just its wrapper.
    private var liveTasks: [Key: Task<Void, Never>] = [:]
    /// Terminal: a stopped engine starts no further fetches.
    private var stopped = false
    private var lastAttempt: [String: Date] = [:]
    private var consecutiveFailures: [String: Int] = [:]
    private var loops: [Task<Void, Never>] = []
    private var wakeObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    private var networkWasDown = false

    private static let menuOpenDebounce: TimeInterval = 15
    private static let maxBackoff: TimeInterval = 1800
    /// Abandoned fetches tolerated per provider before new work stops
    /// being started for it. Only reachable when a provider's fetch
    /// ignores cancellation; the count drains as those tasks finish.
    private static let maxOrphans = 3
    /// Ceiling on one fetch, above the 30s transport timeout so the
    /// network layer normally reports the real error first. This is the
    /// backstop for a fetch that blocks off-network — e.g. the
    /// synchronous Keychain `security` call, which cancellation cannot
    /// interrupt.
    let fetchDeadline: TimeInterval

    init(
        providers: [any UsageProvider],
        cache: SnapshotCache,
        initial: [String: ProviderSnapshot],
        fetchDeadline: TimeInterval = 45,
        publish: @escaping @Sendable (ProviderSnapshot, Int) async -> Void
    ) {
        self.providers = providers
        self.cache = cache
        self.lastGood = initial
        self.fetchDeadline = fetchDeadline
        self.publish = publish
    }

    func start() {
        guard !stopped, loops.isEmpty else { return }
        for provider in providers {
            loops.append(Task { await self.runLoop(for: provider) })
        }
        observeWake()
        observeNetwork()
    }

    /// Tears down loops, outstanding work, and system observers. The app
    /// never stops the engine; tests must, or `start()` leaves a live
    /// NWPathMonitor, a wake observer, and a 5-minute loop running past
    /// the test that created them. Terminal by design: a stopped engine
    /// refuses to start new fetches, so a queued wake/network callback
    /// cannot resurrect work after teardown.
    func stop() {
        stopped = true
        loops.forEach { $0.cancel() }
        loops.removeAll()
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        // The fetch and its deadline timer are what actually hold a
        // provider's work; cancelling only the wrapper above would leave
        // them running and still able to publish after teardown.
        liveTasks.values.forEach { $0.cancel() }
        liveTasks.removeAll()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    /// Called from the menu content's onAppear; debounced so reopening the
    /// menu repeatedly doesn't hammer providers.
    func menuOpened() {
        for provider in providers {
            startRefresh(provider, force: false)
        }
    }

    func refreshAll(force: Bool) {
        for provider in providers {
            startRefresh(provider, force: force)
        }
    }

    // MARK: - Loop

    private func runLoop(for provider: any UsageProvider) async {
        while !Task.isCancelled {
            await awaitRefresh(provider)
            let failures = consecutiveFailures[provider.id] ?? 0
            let delay = failures == 0
                ? provider.refreshInterval
                : min(provider.refreshInterval * pow(2, Double(failures)), Self.maxBackoff)
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func awaitRefresh(_ provider: any UsageProvider) async {
        // Coalesce onto an already-running fetch rather than stacking a second.
        if let existing = inFlight[provider.id] {
            await existing.value
            return
        }
        startRefresh(provider, force: true)
        if let task = inFlight[provider.id] {
            await task.value
        }
    }

    private func startRefresh(_ provider: any UsageProvider, force: Bool) {
        guard !stopped else { return }
        let id = provider.id
        var replacingOverdue = false
        if inFlight[id] != nil {
            let age = lastAttempt[id].map { Date().timeIntervalSince($0) } ?? 0
            guard age >= fetchDeadline else {
                // Normal coalescing: a fetch is running and still young.
                Diag.refresh.log("""
                skip id=\(id, privacy: .public) reason=inflight \
                inflightAge=\(String(format: "%.1f", age), privacy: .public)s
                """)
                return
            }
            // Overdue. Every refresh path is gated on `inFlight`, so
            // leaving this in place parks the provider indefinitely —
            // observed in the wild at 938.5s. Cancel and replace it.
            Diag.refresh.error("""
            cancel id=\(id, privacy: .public) reason=overdue \
            age=\(String(format: "%.1f", age), privacy: .public)s
            """)
            inFlight[id]?.cancel()
            inFlight[id] = nil
            replacingOverdue = true
        }
        // Debounce only suppresses a *new* fetch. Having just cancelled an
        // overdue one, returning here would leave the provider with no
        // fetch at all — the wedge again, by a different route. Reachable
        // whenever fetchDeadline < menuOpenDebounce.
        if !force, !replacingOverdue, let last = lastAttempt[id],
           Date().timeIntervalSince(last) < Self.menuOpenDebounce {
            return
        }
        guard orphans[id, default: 0] < Self.maxOrphans else {
            // Abandoned fetches are unbounded only if we keep starting
            // new ones on top of them; a provider whose work ignores
            // cancellation would otherwise leak a task per poll.
            Diag.refresh.error("""
            skip id=\(id, privacy: .public) reason=orphan-cap \
            orphans=\(self.orphans[id] ?? 0, privacy: .public)
            """)
            return
        }
        lastAttempt[id] = Date()
        let mine = (generation[id] ?? 0) + 1
        generation[id] = mine
        inFlight[id] = Task {
            await self.performFetch(provider, generation: mine)
            self.clearInFlight(id, generation: mine)
        }
    }

    /// Only the newest fetch owns the slot; a cancelled straggler
    /// finishing later must not clear its replacement's entry.
    private func clearInFlight(_ id: String, generation: Int) {
        guard self.generation[id] == generation else { return }
        inFlight[id] = nil
    }

    /// A superseded fetch must not publish. Its result describes a world
    /// its replacement has already moved past, so committing it would
    /// overwrite fresh state with stale status and inflate backoff with
    /// failures nobody is waiting on.
    ///
    /// A stopped engine is never current: `stop()` cancels in-flight work,
    /// which surfaces as a fetch failure, and publishing that would hand
    /// a callback to an owner that has already torn down.
    private func isCurrent(_ id: String, _ generation: Int) -> Bool {
        !stopped && self.generation[id] == generation
    }

    private func performFetch(_ provider: any UsageProvider, generation: Int) async {
        let id = provider.id
        let started = Date()
        do {
            let snapshot = try await fetchWithDeadline(provider, generation: generation)
            guard isCurrent(id, generation) else {
                Diag.refresh.log("fetch id=\(id, privacy: .public) dropped=superseded")
                return
            }
            // Drop results older than what we already published.
            if let previous = lastGood[id], previous.fetchedAt > snapshot.fetchedAt {
                Diag.refresh.log("fetch id=\(id, privacy: .public) dropped=stale")
                return
            }
            consecutiveFailures[id] = 0
            lastGood[id] = snapshot
            cache.update(snapshot)
            await publish(snapshot, generation)
            Diag.refresh.log("""
            fetch id=\(id, privacy: .public) ok \
            metrics=\(snapshot.metrics.count, privacy: .public) \
            took=\(String(format: "%.2f", Date().timeIntervalSince(started)), privacy: .public)s
            """)
        } catch ProviderError.authRequired(let hint) {
            guard isCurrent(id, generation) else { return }
            consecutiveFailures[id, default: 0] += 1
            await publishDegraded(id, status: .authRequired(hint: hint), generation: generation)
            Diag.refresh.error("""
            fetch id=\(id, privacy: .public) authRequired hint=\(hint, privacy: .public) \
            failures=\(self.consecutiveFailures[id] ?? 0, privacy: .public) \
            took=\(String(format: "%.2f", Date().timeIntervalSince(started)), privacy: .public)s
            """)
        } catch {
            guard isCurrent(id, generation) else { return }
            consecutiveFailures[id, default: 0] += 1
            await publishDegraded(id, status: .error(message: error.localizedDescription), generation: generation)
            Diag.refresh.error("""
            fetch id=\(id, privacy: .public) error=\(error.localizedDescription, privacy: .public) \
            failures=\(self.consecutiveFailures[id] ?? 0, privacy: .public) \
            took=\(String(format: "%.2f", Date().timeIntervalSince(started)), privacy: .public)s
            """)
        }
    }

    struct FetchTimeout: LocalizedError {
        let seconds: TimeInterval
        var errorDescription: String? { "Timed out after \(Int(seconds))s" }
    }

    /// One-shot rendezvous: whichever of the fetch or the deadline
    /// finishes first wins, later results are dropped.
    private actor FirstResult {
        private var result: Result<ProviderSnapshot, Error>?
        private var waiter: CheckedContinuation<Result<ProviderSnapshot, Error>, Never>?

        func finish(_ value: Result<ProviderSnapshot, Error>) {
            guard result == nil else { return }
            result = value
            if let waiter {
                self.waiter = nil
                waiter.resume(returning: value)
            }
        }

        func value() async -> Result<ProviderSnapshot, Error> {
            if let result { return result }
            return await withCheckedContinuation { continuation in
                waiter = continuation
            }
        }
    }

    /// Self-enforcing deadline: the polling loop awaits the in-flight
    /// task, so a fetch that never returns would stall the loop even with
    /// the watchdog in `startRefresh` (which only fires when some other
    /// path asks for a refresh).
    ///
    /// The fetch deliberately runs as an *unstructured* task that nothing
    /// awaits on the way out. A structured task group would be tidier but
    /// awaits its children at scope exit, so a fetch that ignores
    /// cancellation would hold the deadline hostage and reproduce the very
    /// wedge this fixes. Cancellation is still requested; if it is
    /// ignored, that task is counted as an orphan until it finishes, and
    /// `startRefresh` stops starting new work for a provider holding
    /// `maxOrphans` of them — abandonment is bounded, not unlimited.
    private func fetchWithDeadline(
        _ provider: any UsageProvider,
        generation: Int
    ) async throws -> ProviderSnapshot {
        let deadline = fetchDeadline
        let id = provider.id
        let rendezvous = FirstResult()

        let key = Key(id: id, generation: generation)
        pendingWork.insert(key)
        let work = Task {
            do {
                await rendezvous.finish(.success(try await provider.fetchSnapshot()))
            } catch {
                await rendezvous.finish(.failure(error))
            }
            self.workFinished(id, generation: generation)
        }
        // Registered so `stop()` can cancel work that outlived its
        // deadline; the entry is removed when the task reports back.
        liveTasks[key] = work
        let timer = Task {
            try? await Task.sleep(for: .seconds(deadline))
            guard !Task.isCancelled else { return }
            await rendezvous.finish(.failure(FetchTimeout(seconds: deadline)))
        }
        defer {
            work.cancel()
            timer.cancel()
        }
        let result = await rendezvous.value()
        if case .failure(let error) = result, error is FetchTimeout {
            markOrphaned(id, generation: generation)
        }
        return try result.get()
    }

    /// The fetch outlived its deadline; its task may still be running and
    /// may never stop. Count it until it reports back — unless it already
    /// did, which is a real race: the work can finish just as the timer
    /// wins the rendezvous, and counting a finished task as orphaned would
    /// leak the counter and eventually trip the cap forever.
    private func markOrphaned(_ id: String, generation: Int) {
        let key = Key(id: id, generation: generation)
        guard pendingWork.contains(key) else { return }
        orphaned.insert(key)
        orphans[id, default: 0] += 1
        Diag.refresh.error("""
        orphan id=\(id, privacy: .public) created \
        outstanding=\(self.orphans[id] ?? 0, privacy: .public)
        """)
    }

    /// Called by every fetch task when it finally completes, on time or
    /// long after being abandoned. Bookkeeping tracks only live work, so
    /// it stays bounded by the number of outstanding fetches rather than
    /// growing by one entry per poll for the life of the process.
    private func workFinished(_ id: String, generation: Int) {
        let key = Key(id: id, generation: generation)
        pendingWork.remove(key)
        liveTasks[key] = nil
        guard orphaned.remove(key) != nil else { return }
        orphans[id, default: 1] -= 1
        Diag.refresh.log("""
        orphan id=\(id, privacy: .public) finished \
        outstanding=\(self.orphans[id] ?? 0, privacy: .public)
        """)
    }

    /// Wake and network restoration invalidate the reason a provider was
    /// backing off, so the penalty is cleared rather than served out —
    /// otherwise a provider that failed while asleep waits up to 30
    /// minutes after connectivity is already back.
    private func resetBackoff() {
        guard !consecutiveFailures.isEmpty else { return }
        Diag.refresh.log("""
        backoff reset providers=\(self.consecutiveFailures.count, privacy: .public)
        """)
        consecutiveFailures.removeAll()
        // Clearing the counter does not shorten a sleep already in
        // progress: `runLoop` computed its delay before going to sleep, so
        // a provider that failed while the machine was asleep would sit
        // out the full 30-minute penalty after connectivity returned.
        // Restarting the loops cancels those sleeps; the fresh loop fetches
        // immediately and then resumes the provider's normal interval.
        restartLoops()
    }

    private func restartLoops() {
        guard !stopped, !loops.isEmpty else { return }
        loops.forEach { $0.cancel() }
        loops = providers.map { provider in
            Task { await self.runLoop(for: provider) }
        }
    }

    /// Republish last-known-good metrics under a degraded status; fetchedAt
    /// stays at the old value so the UI's staleness note is truthful.
    private func publishDegraded(_ id: String, status: ProviderStatus, generation: Int) async {
        let previous = lastGood[id]
        let snapshot = ProviderSnapshot(
            providerID: id,
            fetchedAt: previous?.fetchedAt ?? .distantPast,
            status: status,
            metrics: previous?.metrics ?? []
        )
        await publish(snapshot, generation)
    }

    // MARK: - Wake / network recovery

    // Task.sleep loops don't fire while the machine sleeps, so without this
    // the app shows hours-stale data after an overnight gap.
    private func observeWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task {
                await self.resetBackoff()
                await self.refreshAll(force: true)
            }
        }
    }

    // The first fetch right after wake usually races the network coming up
    // and fails; refreshing again when the path is restored covers that.
    private func observeNetwork() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            Task { await self.networkPathChanged(satisfied: path.status == .satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "tokmon.network-monitor"))
        pathMonitor = monitor
    }

    private func networkPathChanged(satisfied: Bool) {
        if satisfied {
            if networkWasDown {
                networkWasDown = false
                resetBackoff()
                refreshAll(force: true)
            }
        } else {
            networkWasDown = true
        }
    }
}
