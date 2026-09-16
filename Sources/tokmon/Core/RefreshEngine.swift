import AppKit
import Foundation
import Network

/// Runs one polling loop per provider, with exponential backoff on failure,
/// per-provider in-flight dedup, and immediate refresh on menu open, system
/// wake, and network restoration.
actor RefreshEngine {
    private let providers: [any UsageProvider]
    private let cache: SnapshotCache
    private let publish: @Sendable (ProviderSnapshot) async -> Void

    /// Last successful snapshot per provider; failures republish these
    /// metrics under a degraded status so the UI never goes blank.
    private var lastGood: [String: ProviderSnapshot]
    private var inFlight: [String: Task<Void, Never>] = [:]
    /// Bumped per started fetch so a completing task only clears its own
    /// `inFlight` entry. Without it, a cancelled straggler finishing after
    /// its replacement started would clear the replacement's slot and
    /// leave the watchdog blind.
    private var generation: [String: Int] = [:]
    private var lastAttempt: [String: Date] = [:]
    private var consecutiveFailures: [String: Int] = [:]
    private var loops: [Task<Void, Never>] = []
    private var wakeObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    private var networkWasDown = false

    private static let menuOpenDebounce: TimeInterval = 15
    private static let maxBackoff: TimeInterval = 1800
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
        publish: @escaping @Sendable (ProviderSnapshot) async -> Void
    ) {
        self.providers = providers
        self.cache = cache
        self.lastGood = initial
        self.fetchDeadline = fetchDeadline
        self.publish = publish
    }

    func start() {
        guard loops.isEmpty else { return }
        for provider in providers {
            loops.append(Task { await self.runLoop(for: provider) })
        }
        observeWake()
        observeNetwork()
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
        let id = provider.id
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
        }
        if !force, let last = lastAttempt[id],
           Date().timeIntervalSince(last) < Self.menuOpenDebounce {
            return
        }
        lastAttempt[id] = Date()
        let mine = (generation[id] ?? 0) + 1
        generation[id] = mine
        inFlight[id] = Task {
            await self.performFetch(provider)
            await self.clearInFlight(id, generation: mine)
        }
    }

    /// Only the newest fetch owns the slot; a cancelled straggler
    /// finishing later must not clear its replacement's entry.
    private func clearInFlight(_ id: String, generation: Int) {
        guard self.generation[id] == generation else { return }
        inFlight[id] = nil
    }

    private func performFetch(_ provider: any UsageProvider) async {
        let id = provider.id
        let started = Date()
        do {
            let snapshot = try await fetchWithDeadline(provider)
            // Drop results older than what we already published.
            if let previous = lastGood[id], previous.fetchedAt > snapshot.fetchedAt {
                Diag.refresh.log("fetch id=\(id, privacy: .public) dropped=stale")
                return
            }
            consecutiveFailures[id] = 0
            lastGood[id] = snapshot
            cache.update(snapshot)
            await publish(snapshot)
            Diag.refresh.log("""
            fetch id=\(id, privacy: .public) ok \
            metrics=\(snapshot.metrics.count, privacy: .public) \
            took=\(String(format: "%.2f", Date().timeIntervalSince(started)), privacy: .public)s
            """)
        } catch ProviderError.authRequired(let hint) {
            consecutiveFailures[id, default: 0] += 1
            await publishDegraded(id, status: .authRequired(hint: hint))
            Diag.refresh.error("""
            fetch id=\(id, privacy: .public) authRequired hint=\(hint, privacy: .public) \
            failures=\(self.consecutiveFailures[id] ?? 0, privacy: .public) \
            took=\(String(format: "%.2f", Date().timeIntervalSince(started)), privacy: .public)s
            """)
        } catch {
            consecutiveFailures[id, default: 0] += 1
            await publishDegraded(id, status: .error(message: error.localizedDescription))
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
    /// cancellation — a socket the OS has not given up on, or the
    /// synchronous Keychain `security` call blocking a thread — would hold
    /// the deadline hostage and reproduce the very wedge this fixes.
    /// Cancellation is still requested; if it is ignored, that task leaks
    /// until it finishes on its own, which is the price of a loop that
    /// always comes back.
    private func fetchWithDeadline(_ provider: any UsageProvider) async throws -> ProviderSnapshot {
        let deadline = fetchDeadline
        let rendezvous = FirstResult()

        let work = Task {
            do {
                await rendezvous.finish(.success(try await provider.fetchSnapshot()))
            } catch {
                await rendezvous.finish(.failure(error))
            }
        }
        let timer = Task {
            try? await Task.sleep(for: .seconds(deadline))
            guard !Task.isCancelled else { return }
            await rendezvous.finish(.failure(FetchTimeout(seconds: deadline)))
        }
        defer {
            work.cancel()
            timer.cancel()
        }
        return try await rendezvous.value().get()
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
    }

    /// Republish last-known-good metrics under a degraded status; fetchedAt
    /// stays at the old value so the UI's staleness note is truthful.
    private func publishDegraded(_ id: String, status: ProviderStatus) async {
        let previous = lastGood[id]
        let snapshot = ProviderSnapshot(
            providerID: id,
            fetchedAt: previous?.fetchedAt ?? .distantPast,
            status: status,
            metrics: previous?.metrics ?? []
        )
        await publish(snapshot)
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
