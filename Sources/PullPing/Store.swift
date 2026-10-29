import AppKit
import Observation
import PullPingCore

/// Main-window sidebar filters.
enum Filter: Hashable {
    case all, mine, toReview, involved, recentlyClosed, muted
    case account(UUID)

    static let fixed: [Filter] = [.all, .mine, .toReview, .involved, .recentlyClosed, .muted]

    var title: String {
        switch self {
        case .all: "All"
        case .mine: "Mine"
        case .toReview: "To Review"
        case .involved: "Involved"
        case .recentlyClosed: "Recently Closed"
        case .muted: "Muted"
        case .account: "Account"
        }
    }

    var symbol: String {
        switch self {
        case .all: "tray.full"
        case .mine: "person"
        case .toReview: "eye"
        case .involved: "bubble.left.and.bubble.right"
        case .recentlyClosed: "archivebox"
        case .muted: "bell.slash"
        case .account: "person.crop.circle"
        }
    }

    func matches(_ pr: TrackedPR) -> Bool {
        switch self {
        case .all: true
        case .mine: Attention.group(pr) == .mine
        case .toReview: Attention.group(pr) == .toReview
        case .involved: Attention.group(pr) == .involved
        case .recentlyClosed: pr.state != .open
        case .muted: pr.muted
        case .account(let id): pr.accountID == id
        }
    }
}

enum Snooze: CaseIterable {
    case minutes15, hour1, hours3, tomorrow

    var title: String {
        switch self {
        case .minutes15: "15 Minutes"
        case .hour1: "1 Hour"
        case .hours3: "3 Hours"
        case .tomorrow: "Tomorrow at 9:00"
        }
    }

    func until(from now: Date) -> Date {
        switch self {
        case .minutes15: now.addingTimeInterval(15 * 60)
        case .hour1: now.addingTimeInterval(3600)
        case .hours3: now.addingTimeInterval(3 * 3600)
        case .tomorrow:
            Calendar.current.date(bySettingHour: 9, minute: 0, second: 0,
                                  of: Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now) ?? now.addingTimeInterval(86_400)
        }
    }
}

extension PRGroup {
    var title: String {
        switch self {
        case .mine: "Mine"
        case .toReview: "To Review"
        case .involved: "Involved"
        }
    }
}

extension AccountStatus {
    var word: String {
        switch self {
        case .ok: "Connected"
        case .syncing: "Syncing"
        case .badToken: "Token rejected"
        case .missingScope(let scope): "Missing \(scope) scope"
        case .ssoRequired: "Needs SSO"
        case .rateLimited(let resetAt): "Rate limited until \(resetAt.formatted(date: .omitted, time: .shortened))"
        case .offline: "Offline"
        case .failed(let message): "Failed: \(message)"
        }
    }

    var isError: Bool {
        switch self {
        case .ok, .syncing, .offline: false
        default: true
        }
    }
}

/// UI facade over Core. The StateStore does not publish: every change goes through `mutate`, which re-reads it.
@MainActor @Observable
final class Store {
    @ObservationIgnored let state: StateStore
    @ObservationIgnored let undoManager = UndoManager()
    /// false = demo and screenshots: accounts and settings are never written to UserDefaults.
    @ObservationIgnored private let persist: Bool
    @ObservationIgnored private var poller: Poller?
    @ObservationIgnored private var clock: Timer?

    var accounts: [Account] { didSet { if persist { Account.save(accounts) } } }
    var settings: AppSettings { didSet { if persist { settings.save() } } }
    private(set) var tracked: TrackedState
    var statuses: [UUID: AccountStatus] = [:]
    var syncing = false
    var offline = false
    /// Re-read every 30 s so relative times stay current without a per-view timer.
    private(set) var now = Date()
    var filter: Filter? = .all
    /// Main-window selection; the Pull Request menu acts on it.
    var selectedID: String?

    init(state: StateStore, accounts: [Account], settings: AppSettings, persist: Bool) {
        self.state = state
        self.accounts = accounts
        self.settings = settings
        self.persist = persist
        tracked = state.state
    }

    /// The running app: the real state file, or a memory-only fixture store with `PULLPING_DEMO=1`.
    static func launch() -> Store {
        if ProcessInfo.processInfo.environment["PULLPING_DEMO"] == "1" {
            let store = Fixtures.sampleStore()
            store.startClock()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                store.show(Fixtures.demoEvents(store))
            }
            return store
        }
        let store = Store(state: StateStore(url: StateStore.defaultURL), accounts: Account.load(), settings: AppSettings.load(), persist: true)
        store.start()
        return store
    }

    func start() {
        let poller = Poller(transport: URLSessionTransport(), tokenProvider: { Keychain.get($0.tokenService) },
                            state: state, settings: { AppSettings.load() })
        self.poller = poller
        syncing = !accounts.filter(\.enabled).isEmpty
        Task { await poller.start(accounts: { await self.accounts }, onReport: { await self.handle($0) }) }
        startClock()
    }

    private func startClock() {
        let timer = Timer(timeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
        timer.tolerance = 3
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    // MARK: Derived

    var enabledIDs: Set<UUID> { Set(accounts.filter(\.enabled).map(\.id)) }

    /// PRs of enabled accounts: attention first, then open before closed, newest first.
    var prs: [TrackedPR] {
        let enabled = enabledIDs
        return tracked.prs.values.filter { enabled.contains($0.accountID) }.sorted {
            let a = (Attention.isAttention($0), $0.state == .open), b = (Attention.isAttention($1), $1.state == .open)
            if a != b { return a.0 != b.0 ? a.0 : a.1 }
            return $0.updatedAt > $1.updatedAt
        }
    }

    var badgeCount: Int { Attention.badgeCount(Array(tracked.prs.values), enabledAccounts: enabledIDs) }
    var multiAccount: Bool { accounts.count > 1 }
    var lastPollAt: Date? { tracked.lastPollAt.filter { enabledIDs.contains($0.key) }.values.max() }
    var selectedPR: TrackedPR? { selectedID.flatMap { tracked.prs[$0] } }
    var errorAccounts: [Account] { accounts.filter { $0.enabled && statuses[$0.id]?.isError == true } }
    var hasError: Bool { !errorAccounts.isEmpty }
    /// Enabled accounts that have never finished a poll.
    var firstSync: [Account] { accounts.filter { $0.enabled && tracked.lastPollAt[$0.id] == nil } }

    func account(_ id: UUID) -> Account? { accounts.first { $0.id == id } }
    func login(for pr: TrackedPR) -> String? { multiAccount ? account(pr.accountID).map { "@\($0.login)" } : nil }

    var menuBarLabel: String {
        if hasError { return "PullPing, account error" }
        if offline { return "PullPing, offline" }
        return badgeCount > 0 ? "PullPing, \(badgeCount) need attention" : "PullPing"
    }

    var freshness: String {
        if syncing { return "Syncing…" }
        let age = lastPollAt.map { relativeAge($0, now: now) }
        if offline { return age.map { "Offline — showing data from \($0)" } ?? "Offline" }
        return age.map { "Updated \($0)" } ?? "Not updated yet"
    }

    // MARK: Polling

    func refresh() { poll(.manual) }

    func poll(_ reason: PollReason) {
        guard let poller else { return }
        syncing = true
        let accounts = self.accounts
        Task {
            handle(await poller.pollAll(accounts: accounts, reason: reason))
        }
    }

    func setPaused(_ paused: Bool) {
        guard let poller else { return }
        Task { await poller.setPaused(paused) }
        if !paused { poll(.wake) }
    }

    func handle(_ report: PollReport) {
        syncing = false
        offline = report.offline
        for (id, result) in report.results { statuses[id] = result.status }
        reload()
        show(report.events.filter { !$0.isOwn })
    }

    private func reload() {
        tracked = state.state
        now = Date()
    }

    private func mutate(_ body: (inout TrackedState) -> Void) {
        state.update(body)
        reload()
    }

    // MARK: Notifications and reminders

    /// Groups by PR, drops off/muted/snoozed, one panel per PR, one sound per batch.
    func show(_ events: [PREvent]) {
        guard settings.notificationsEnabled else { return }
        let t = Date()
        var shown = false
        let byPR = Dictionary(grouping: events, by: \.prID).sorted { ($0.value.map(\.at).max() ?? t) < ($1.value.map(\.at).max() ?? t) }
        for (prID, group) in byPR {
            guard let pr = tracked.prs[prID], enabledIDs.contains(pr.accountID), !pr.muted, (pr.snoozedUntil ?? .distantPast) <= t else { continue }
            let styled = group.map { ($0, settings.style(for: $0.kind, mine: pr.roles.contains(.author))) }.filter { $0.1 != .off }
            guard !styled.isEmpty else { continue }
            NotificationPanels.shared.show(pr: pr, events: styled.map(\.0), alert: styled.contains { $0.1 == .alert },
                                           account: login(for: pr), autoHide: settings.autoHideSeconds)
            shown = true
        }
        if shown && settings.playSound { NSSound(named: "Pop")?.play() }
    }

    private func tick() {
        reload()
        var due: [PREvent] = []
        for pr in tracked.prs.values where enabledIDs.contains(pr.accountID) {
            if let next = Reminders.nextReminder(pr: pr, settings: settings, now: now), next <= now {
                due.append(Reminders.event(for: pr, now: now))
            }
        }
        guard !due.isEmpty else { return }
        let ids = Set(due.map(\.prID)), t = now
        mutate { for id in ids { $0.prs[id]?.lastReminderAt = t } }
        show(due)
    }

    // MARK: Pull request actions

    func open(_ id: String) {
        guard let pr = tracked.prs[id] else { return }
        NSWorkspace.shared.open(pr.url)
        markRead([id])
        NotificationPanels.shared.dismiss(prID: id)
    }

    func markRead(_ ids: Set<String>) {
        let t = Date()
        mutate { for id in ids { $0.prs[id]?.lastReadAt = t } }
    }

    func markAllRead() { markRead(Set(tracked.prs.keys)) }

    func setMuted(_ ids: Set<String>, _ muted: Bool) {
        mutate { for id in ids { $0.prs[id]?.muted = muted } }
        if muted { ids.forEach { NotificationPanels.shared.dismiss(prID: $0) } }
    }

    func snooze(_ ids: Set<String>, _ option: Snooze) {
        let until = option.until(from: Date())
        mutate { for id in ids { $0.prs[id]?.snoozedUntil = until } }
        ids.forEach { NotificationPanels.shared.dismiss(prID: $0) }
    }

    /// Removes the rows and ignores the ids; Edit > Undo puts them back (UND-1).
    func stopTracking(_ ids: Set<String>) {
        let removed = ids.compactMap { tracked.prs[$0] }
        guard !removed.isEmpty else { return }
        mutate { state in
            for pr in removed { state.prs[pr.id] = nil; state.ignoredIDs.insert(pr.id) }
        }
        if selectedID.map(ids.contains) == true { selectedID = nil }
        ids.forEach { NotificationPanels.shared.dismiss(prID: $0) }
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { store.restore(removed) }
        }
        undoManager.setActionName("Stop Tracking")
    }

    private func restore(_ prs: [TrackedPR]) {
        mutate { state in
            for pr in prs { state.prs[pr.id] = pr; state.ignoredIDs.remove(pr.id) }
        }
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { store.stopTracking(Set(prs.map(\.id))) }
        }
        undoManager.setActionName("Stop Tracking")
    }

    var ignoredCount: Int { tracked.ignoredIDs.count }

    func resetIgnored() {
        let ignored = tracked.ignoredIDs
        mutate { $0.ignoredIDs = [] }
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { store.mutate { $0.ignoredIDs.formUnion(ignored) } }
        }
        undoManager.setActionName("Reset Ignored Pull Requests")
    }

    // MARK: Accounts

    /// Stores the token in the keychain, then polls the new account (its first sync is silent).
    func addAccount(_ viewer: Viewer, token: String, kind: AuthKind) {
        let account = Account(login: viewer.login, avatarURL: viewer.avatarURL, authKind: kind)
        Keychain.set(account.tokenService, token)
        accounts.append(account)
        statuses[account.id] = viewer.status
        poll(.accountAdded)
    }

    /// Deletes the keychain item and the account's tracked pull requests.
    func removeAccount(_ id: UUID) {
        guard let account = account(id) else { return }
        Keychain.set(account.tokenService, "")
        accounts.removeAll { $0.id == id }
        statuses[id] = nil
        mutate { state in
            state.prs = state.prs.filter { $0.value.accountID != id }
            state.baselinedAccounts.remove(id)
            state.lastPollAt[id] = nil
        }
    }

    /// Fixtures and screenshots only.
    func setTracked(_ body: (inout TrackedState) -> Void) { mutate(body) }
}
