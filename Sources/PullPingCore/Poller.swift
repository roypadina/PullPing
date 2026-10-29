import Foundation
import Network
import os

public enum PollReason: Sendable { case timer, manual, wake, networkBack, accountAdded }

/// Counts for logs and smoke mode.
public struct PollStats: Sendable, Equatable {
    public var login = ""
    public var involved = 0, requested = 0, reviewed = 0, pages = 0, discoverCost = 0
    public var tracked = 0, changed = 0, new = 0, dropped = 0
    public var batches = 0, refreshed = 0, refreshCost = 0
    public var rateLimit: RateLimit?
    /// First sync of the account: state filled, no events emitted.
    public var baseline = false
}

public struct AccountResult: Sendable {
    public var status: AccountStatus
    public var events: [PREvent]
    public var stats: PollStats
}

public struct PollReport: Sendable {
    public var results: [UUID: AccountResult]
    /// New events of every polled account, own ones included (`isOwn`); the App decides what to show.
    public var events: [PREvent]
    public var startedAt: Date
    public var finishedAt: Date
    public var offline: Bool
}

public actor Poller {
    static let log = Logger(subsystem: "com.padina.pullping", category: "poller")
    static let minRemaining = 300
    static let maxBackoff: TimeInterval = 30 * 60
    static let manualGap: TimeInterval = 10

    private let transport: GraphQLTransport
    private let tokenProvider: @Sendable (Account) -> String?
    private let store: StateStore
    private let settings: @Sendable () -> AppSettings
    private let now: @Sendable () -> Date
    private var busy: Set<UUID> = []
    private var failures: [UUID: Int] = [:]
    private var notBefore: [UUID: Date] = [:]
    private var lastManual: Date?
    private var paused = false
    private var loop: Task<Void, Never>?
    private let monitor = NWPathMonitor()
    public private(set) var isOffline = false

    public init(transport: GraphQLTransport, tokenProvider: @escaping @Sendable (Account) -> String?, state: StateStore,
                settings: @escaping @Sendable () -> AppSettings, now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.tokenProvider = tokenProvider
        self.store = state
        self.settings = settings
        self.now = now
    }

    /// Timer loop + network monitor, once per app run. `accounts` is read before every poll; every report goes to `onReport`
    /// (offline changes send an empty report with `offline` set).
    public func start(accounts: @escaping @Sendable () async -> [Account], onReport: @escaping @Sendable (PollReport) async -> Void) {
        guard loop == nil else { return }
        monitor.pathUpdateHandler = { _ in
            Task { await self.networkChanged(accounts: accounts, onReport: onReport) }
        }
        monitor.start(queue: .global(qos: .utility))
        loop = Task {
            while !Task.isCancelled {
                if !paused && !isOffline { await onReport(await pollAll(accounts: await accounts(), reason: .timer)) }
                let interval = Double(settings().pollIntervalMinutes * 60)
                try? await Task.sleep(for: .seconds(interval), tolerance: .seconds(interval / 10))
            }
        }
    }

    /// The App pauses on `willSleep` and resumes + polls (`.wake`) on `didWake`.
    public func setPaused(_ paused: Bool) { self.paused = paused }

    private func networkChanged(accounts: @Sendable () async -> [Account], onReport: @Sendable (PollReport) async -> Void) async {
        // The current path, not the one the update carried: these Tasks can reach the actor out of order.
        let online = monitor.currentPath.status == .satisfied
        guard isOffline == online else { return }
        isOffline = !online
        if online {
            await onReport(await pollAll(accounts: await accounts(), reason: .networkBack))
        } else {
            let t = now()
            await onReport(PollReport(results: [:], events: [], startedAt: t, finishedAt: t, offline: true))
        }
    }

    /// Enabled accounts in parallel. Timer polls skip offline and backed-off accounts; manual polls run at most every 10 s.
    public func pollAll(accounts: [Account], reason: PollReason) async -> PollReport {
        let start = now()
        var report = PollReport(results: [:], events: [], startedAt: start, finishedAt: start, offline: isOffline)
        if reason == .manual {
            if let lastManual, start.timeIntervalSince(lastManual) < Self.manualGap { return report }
            lastManual = start
        }
        if reason == .timer && isOffline { return report }
        let due = accounts.filter { $0.enabled && (reason != .timer || (notBefore[$0.id] ?? .distantPast) <= start) }
        await withTaskGroup(of: (UUID, AccountResult?).self) { group in
            for account in due { group.addTask { (account.id, await self.poll(account: account)) } }
            for await (id, result) in group {
                guard let result else { continue }
                report.results[id] = result
                report.events += result.events
            }
        }
        report.finishedAt = now()
        return report
    }

    /// One account; nil when a poll of that account is already running.
    public func poll(account: Account) async -> AccountResult? {
        guard busy.insert(account.id).inserted else { return nil }
        defer { busy.remove(account.id) }
        let result = await pollOnce(account)
        updateBackoff(account.id, result.status)
        Self.log.info("poll: status=\(String(describing: result.status), privacy: .public) changed=\(result.stats.changed) refreshed=\(result.stats.refreshed) events=\(result.events.count) cost=\(result.stats.discoverCost + result.stats.refreshCost) remaining=\(result.stats.rateLimit?.remaining ?? -1)")
        return result
    }

    /// ×2 per consecutive failure, from one interval up to 30 min.
    static func backoff(failures: Int, interval: TimeInterval) -> TimeInterval {
        min(interval * pow(2, Double(failures)), maxBackoff)
    }

    private func updateBackoff(_ id: UUID, _ status: AccountStatus) {
        let interval = Double(settings().pollIntervalMinutes * 60)
        switch status {
        case .failed, .rateLimited:
            let count = (failures[id] ?? 0) + 1
            failures[id] = count
            var until = now().addingTimeInterval(Self.backoff(failures: count, interval: interval))
            if case .rateLimited(let resetAt) = status { until = max(until, resetAt) }
            notBefore[id] = until
        case .ok, .ssoRequired, .missingScope:
            failures[id] = nil
            notBefore[id] = nil
        default:
            break
        }
    }

    private func pollOnce(_ account: Account) async -> AccountResult {
        var stats = PollStats()
        guard let token = tokenProvider(account), !token.isEmpty else { return AccountResult(status: .badToken, events: [], stats: stats) }
        let client = GitHubClient(transport: transport, token: token)
        do {
            // 1. Discover open PRs.
            let found = try await client.discover()
            stats.login = found.login
            (stats.involved, stats.requested, stats.reviewed, stats.pages) = (found.involved, found.requested, found.reviewed, found.pages)
            stats.discoverCost = client.cost
            let before = store.state
            var stamps = found.stamps.filter { !before.ignoredIDs.contains($0.key) }

            // 2. Stamps for tracked PRs the searches missed (closed ones in retention, search lag).
            let tracked = before.prs.values.filter { $0.accountID == account.id }
            stats.tracked = tracked.count
            let (extra, dropped) = try await client.stamps(tracked.map(\.id).filter { stamps[$0] == nil })
            for stamp in extra { stamps[stamp.id] = stamp }
            stats.dropped = dropped.count

            // 3. Changed = new, updated, state changed, or CI still pending (CI completion does not bump updatedAt),
            // or the requested search disagrees with the team-request role (the search index lags the PR).
            // shortcut: a PR seen by two accounts is one entry, owned by whichever account refreshed it last.
            let changed = stamps.values.filter { stamp in
                guard let old = before.prs[stamp.id] else { return true }
                return old.updatedAt != stamp.updatedAt || old.state != stamp.state || (old.state == .open && old.ci == .pending)
                    || (stamp.inRequested != old.roles.contains(.teamReviewRequested) && !old.roles.contains(.reviewRequested))
            }.map(\.id).sorted()
            let fresh = changed.filter { before.prs[$0] == nil }
            let known = changed.filter { before.prs[$0] != nil }
            stats.changed = changed.count
            stats.new = fresh.count
            stats.rateLimit = client.rateLimit
            if let limit = client.rateLimit, limit.remaining < Self.minRemaining {
                return AccountResult(status: .rateLimited(resetAt: limit.resetAt), events: [], stats: stats)
            }

            // 4. Refresh in batches of 20: known PRs since their watermark, new ones with 24 h of history.
            let t = now()
            var snapshots: [PRSnapshot] = []
            for batch in known.chunked(GitHubClient.refreshBatch) {
                let since = batch.compactMap { before.prs[$0]?.lastSeenAt }.min().map { $0.addingTimeInterval(-60) }
                snapshots += try await client.refresh(batch, since: since)
                stats.batches += 1
            }
            for batch in fresh.chunked(GitHubClient.refreshBatch) {
                snapshots += try await client.refresh(batch, since: t.addingTimeInterval(-86_400))
                stats.batches += 1
            }
            stats.refreshed = snapshots.count
            stats.refreshCost = client.cost - stats.discoverCost
            stats.rateLimit = client.rateLimit

            // 5–8. Diff, prune, persist; the first sync of an account is silent and marks everything read.
            let retention = settings().retentionDays
            var events: [PREvent] = []
            stats.baseline = store.update { state -> Bool in
                for id in dropped { state.prs[id] = nil }
                for snapshot in snapshots where !state.ignoredIDs.contains(snapshot.id) {
                    let stamp = stamps[snapshot.id]
                    let (pr, new) = EventEngine.diff(old: state.prs[snapshot.id], snapshot: snapshot, me: found.login, accountID: account.id,
                                                     inRequestedSearch: stamp?.inRequested ?? false, inReviewedSearch: stamp?.inReviewed ?? false, now: t)
                    state.prs[snapshot.id] = pr
                    events += new
                }
                StateStore.prune(&state, retentionDays: retention, now: t)
                state.lastPollAt[account.id] = t
                guard state.baselinedAccounts.insert(account.id).inserted else { return false }
                for id in state.prs.keys where state.prs[id]?.accountID == account.id { state.prs[id]?.lastReadAt = t }
                return true
            }
            return AccountResult(status: client.warning ?? .ok, events: stats.baseline ? [] : events, stats: stats)
        } catch {
            stats.rateLimit = client.rateLimit
            return AccountResult(status: GitHubClient.status(for: error), events: [], stats: stats)
        }
    }
}
