import AppKit
import Observation
import PullPingCore

/// Status panel and sidebar filters. Hidden pull requests appear only under Hidden.
enum Filter: String, CaseIterable {
    case inbox, all, mine, toReview, involved, recentlyClosed, muted, hidden

    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .all: "All"
        case .mine: "Mine"
        case .toReview: "To Review"
        case .involved: "Involved"
        case .recentlyClosed: "Recently Closed"
        case .muted: "Muted"
        case .hidden: "Hidden"
        }
    }

    var symbol: String {
        switch self {
        case .inbox: "tray"
        case .all: "tray.full"
        case .mine: "person"
        case .toReview: "eye"
        case .involved: "bubble.left.and.bubble.right"
        case .recentlyClosed: "archivebox"
        case .muted: "bell.slash"
        case .hidden: "eye.slash"
        }
    }

    /// Inbox and All hold the same rows; Inbox shows them in Mine · To Review · Involved sections.
    func matches(_ pr: TrackedPR) -> Bool {
        guard self != .hidden else { return pr.hidden }
        guard !pr.hidden else { return false }
        switch self {
        case .inbox, .all, .hidden: return true
        case .mine: return Attention.group(pr) == .mine
        case .toReview: return Attention.group(pr) == .toReview
        case .involved: return Attention.group(pr) == .involved
        case .recentlyClosed: return pr.state != .open
        case .muted: return pr.muted
        }
    }
}

/// Which accounts a list shows.
enum Scope: Hashable {
    case all, account(UUID)

    func matches(_ pr: TrackedPR) -> Bool {
        if case .account(let id) = self { return pr.accountID == id }
        return true
    }

    /// `DefaultsKey.panelAccount` value: empty for All Accounts.
    var key: String {
        if case .account(let id) = self { return id.uuidString }
        return ""
    }
}

/// A main-window sidebar row: All Accounts or one account, plus a filter.
struct SidebarItem: Hashable {
    var scope: Scope
    var filter: Filter
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
    /// Main-window sidebar row; nil only in screenshots. Read `listSelection`.
    var selection: SidebarItem? = SidebarItem(scope: .all, filter: .inbox)
    /// Main-window selection; the Pull Request menu acts on it.
    var selectedID: String?
    /// Phone notification secrets: keychain only. The demo store never reads or writes the keychain.
    var ntfyToken: String { didSet { if persist { Keychain.set(Keychain.ntfyTokenService, ntfyToken) } } }
    var ntfyFallbackURL: String { didSet { if persist { Keychain.set(Keychain.ntfyFallbackService, ntfyFallbackURL) } } }

    init(state: StateStore, accounts: [Account], settings: AppSettings, persist: Bool) {
        self.state = state
        self.accounts = accounts
        self.settings = settings
        self.persist = persist
        tracked = state.state
        ntfyToken = persist ? Keychain.get(Keychain.ntfyTokenService) : ""
        ntfyFallbackURL = persist ? Keychain.get(Keychain.ntfyFallbackService) : ""
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

    /// The menu-bar number (Settings > General > Menu bar count).
    var badgeCount: Int { Attention.badgeCount(Array(tracked.prs.values), enabledAccounts: enabledIDs, mode: settings.badgeMode, counting: settings.badgeReasons) }
    /// "2 to review · 1 ready to merge": status panel header and the status item's label.
    var breakdown: String { Attention.breakdown(prs, counting: settings.badgeReasons) }
    var isPaused: Bool { settings.isPaused(now) }

    func prs(_ scope: Scope, _ filter: Filter) -> [TrackedPR] { prs.filter { scope.matches($0) && filter.matches($0) } }

    /// Sidebar badges and panel segments, by the menu-bar measure ("all unread" when the count is off).
    func count(_ scope: Scope, _ filter: Filter = .all) -> Int {
        let enabled = enabledIDs, needsMe = settings.badgeMode == .needsMe
        return tracked.prs.values.filter {
            enabled.contains($0.accountID) && scope.matches($0) && filter.matches($0) && (needsMe ? Attention.needsMe($0, counting: settings.badgeReasons) : Attention.isAttention($0))
        }.count
    }

    /// The sidebar row the list shows: per-account layout has no All Accounts rows, a removed account falls back.
    var listSelection: SidebarItem {
        var item = selection ?? SidebarItem(scope: .all, filter: .inbox)
        item.scope = resolve(item.scope)
        return item
    }

    /// Status panel scope from its stored account id.
    func panelScope(_ key: String) -> Scope { resolve(UUID(uuidString: key).map(Scope.account) ?? .all) }

    private func resolve(_ scope: Scope) -> Scope {
        if case .account(let id) = scope, account(id) != nil { return scope }
        return settings.inboxLayout == .perAccount ? accounts.first.map { .account($0.id) } ?? .all : .all
    }
    var multiAccount: Bool { accounts.count > 1 }
    var lastPollAt: Date? { tracked.lastPollAt.filter { enabledIDs.contains($0.key) }.values.max() }
    var selectedPR: TrackedPR? { selectedID.flatMap { tracked.prs[$0] } }
    var errorAccounts: [Account] { accounts.filter { $0.enabled && statuses[$0.id]?.isError == true } }
    var hasError: Bool { !errorAccounts.isEmpty }
    /// Enabled accounts that have never finished a poll.
    var firstSync: [Account] { accounts.filter { $0.enabled && tracked.lastPollAt[$0.id] == nil } }

    func account(_ id: UUID) -> Account? { accounts.first { $0.id == id } }
    func login(for pr: TrackedPR) -> String? { multiAccount ? account(pr.accountID).map(\.displayName) : nil }

    /// Status item accessibility label and tooltip (MBX-6): what the count means, and Pause.
    var menuBarLabel: String {
        if hasError { return "PullPing, account error" }
        if offline { return "PullPing, offline" }
        var parts = ["PullPing"]
        switch settings.badgeMode {
        case .needsMe where !breakdown.isEmpty: parts.append(breakdown)
        case .allUnread where badgeCount > 0: parts.append("\(badgeCount) need attention")
        default: break
        }
        if let until = settings.pausedUntil, isPaused { parts.append("notifications paused until \(until.formatted(date: .omitted, time: .shortened))") }
        return parts.joined(separator: ", ")
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

    /// Groups by PR, drops off/muted/snoozed/paused, one panel per PR, one sound per batch. Phone pushes go out per event.
    func show(_ events: [PREvent]) {
        let t = Date()
        push(events, now: t)
        var shown = false
        let byPR = Dictionary(grouping: events, by: \.prID).sorted { ($0.value.map(\.at).max() ?? t) < ($1.value.map(\.at).max() ?? t) }
        for (prID, group) in byPR {
            guard let pr = tracked.prs[prID], enabledIDs.contains(pr.accountID), settings.allowsNotifications(for: pr, now: t) else { continue }
            let styled = group.map { ($0, settings.style(for: $0.kind, mine: pr.roles.contains(.author))) }.filter { $0.1 != .off }
            guard !styled.isEmpty else { continue }
            NotificationPanels.shared.show(pr: pr, events: styled.map(\.0), alert: styled.contains { $0.1 == .alert },
                                           account: login(for: pr), autoHide: settings.autoHideSeconds)
            shown = true
        }
        if shown && settings.playSound { NSSound(named: "Pop")?.play() }
    }

    private var ntfyConfig: NtfyConfig {
        NtfyConfig(server: settings.ntfyServer, topic: settings.ntfyTopic, token: ntfyToken, fallbackURL: ntfyFallbackURL)
    }

    /// One push per opted-in event, independent of the panel style. Alert-style kinds go out at priority 4.
    private func push(_ events: [PREvent], now: Date) {
        let config = ntfyConfig
        for event in events {
            guard let pr = tracked.prs[event.prID], enabledIDs.contains(pr.accountID), settings.pushesToPhone(event, pr: pr, now: now) else { continue }
            let message = Ntfy.Message(
                title: "\(event.kind.label): \(pr.repo) #\(pr.number)",
                body: pr.title + "\n" + (event.summary.isEmpty ? event.line : "\(event.actor): \(event.summary)")
                    + (login(for: pr).map { "\nAccount: \($0)" } ?? ""),
                priority: settings.style(for: event.kind, mine: pr.roles.contains(.author)) == .alert ? 4 : 3,
                tags: [event.kind.rawValue], click: pr.url, flow: "pr-event")
            Task { _ = await Ntfy.send(message, config: config, transport: URLSessionTransport()) }
        }
    }

    func sendTestPush() async -> Bool {
        await Ntfy.send(Ntfy.Message(title: "PullPing", body: "Phone notifications work.", priority: 3, tags: ["white_check_mark"],
                                     click: nil, flow: "test"), config: ntfyConfig, transport: URLSessionTransport())
    }

    /// nil resumes. Covers panels, phone pushes and reminders.
    func pause(until: Date?) { settings.pausedUntil = until }

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

    /// Hidden rows show only under Hidden and leave every count; Edit > Undo reverses it (UND-1).
    func setHidden(_ ids: Set<String>, _ hidden: Bool) {
        let ids = ids.filter { tracked.prs[$0].map { $0.hidden != hidden } ?? false }
        guard !ids.isEmpty else { return }
        mutate { for id in ids { $0.prs[id]?.hidden = hidden } }
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { store.setHidden(ids, !hidden) }
        }
        undoManager.setActionName(hidden ? "Hide" : "Unhide")
    }

    /// Main-window selection from outside (⌘↩, links): switches the sidebar when the pull request isn't in the current list.
    func reveal(_ id: String) {
        selectedID = id
        guard let pr = tracked.prs[id], !(listSelection.scope.matches(pr) && listSelection.filter.matches(pr)) else { return }
        selection = SidebarItem(scope: settings.inboxLayout == .unified ? .all : .account(pr.accountID), filter: pr.hidden ? .hidden : .all)
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
