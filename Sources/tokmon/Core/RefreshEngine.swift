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
    private var lastAttempt: [String: Date] = [:]
    private var consecutiveFailures: [String: Int] = [:]
    private var loops: [Task<Void, Never>] = []
    private var wakeObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    private var networkWasDown = false

    private static let menuOpenDebounce: TimeInterval = 15
    private static let maxBackoff: TimeInterval = 1800

    init(
        providers: [any UsageProvider],
        cache: SnapshotCache,
        initial: [String: ProviderSnapshot],
        publish: @escaping @Sendable (ProviderSnapshot) async -> Void
    ) {
        self.providers = providers
        self.cache = cache
        self.lastGood = initial
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
        guard inFlight[id] == nil else { return }
        if !force, let last = lastAttempt[id],
           Date().timeIntervalSince(last) < Self.menuOpenDebounce {
            return
        }
        lastAttempt[id] = Date()
        inFlight[id] = Task {
            await self.performFetch(provider)
            self.clearInFlight(id)
        }
    }

    private func clearInFlight(_ id: String) {
        inFlight[id] = nil
    }

    private func performFetch(_ provider: any UsageProvider) async {
        let id = provider.id
        do {
            let snapshot = try await provider.fetchSnapshot()
            // Drop results older than what we already published.
            if let previous = lastGood[id], previous.fetchedAt > snapshot.fetchedAt {
                return
            }
            consecutiveFailures[id] = 0
            lastGood[id] = snapshot
            cache.update(snapshot)
            await publish(snapshot)
        } catch ProviderError.authRequired(let hint) {
            consecutiveFailures[id, default: 0] += 1
            await publishDegraded(id, status: .authRequired(hint: hint))
        } catch {
            consecutiveFailures[id, default: 0] += 1
            await publishDegraded(id, status: .error(message: error.localizedDescription))
        }
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
            Task { await self.refreshAll(force: true) }
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
                refreshAll(force: true)
            }
        } else {
            networkWasDown = true
        }
    }
}
