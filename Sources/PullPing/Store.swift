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

    /// Lists that show active rows first and Done pull requests (`Attention.isDone`) in their own group below.
    var splitsDone: Bool { ![.recentlyClosed, .muted, .hidden].contains(self) }

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
    /// Rules and agent hooks, shared with the `pullping hook` CLI; memory only when `!persist`.
    @ObservationIgnored let automationStore: AutomationStore
    /// Runs being launched, by automation · pull request · event (handler: "handler|<pull request>"): a double click starts one.
    @ObservationIgnored private var launching: Set<String> = []
    /// Linked pull requests seen tracked since launch: one that leaves tracking loses its link a day later (`tick`).
    @ObservationIgnored private var trackedLinks: Set<String> = []
    /// The clones under Repository Folders (`RepoLocator`), rescanned at a launch when older than a minute or the folders changed.
    @ObservationIgnored private var repoIndex: RepoIndex?
    /// Earlier-session searches run one at a time, after the previous one.
    @ObservationIgnored private var search: Task<Void, Never>?
    @ObservationIgnored private var finding: Set<String> = []
    /// Earlier sessions found per pull request (`SessionFinder`), misses too; kept 10 minutes.
    private(set) var found: [String: (candidate: SessionCandidate?, scanned: Int, at: Date)] = [:]

    var accounts: [Account] { didSet { if persist { Account.save(accounts) } } }
    var settings: AppSettings { didSet { if persist { settings.save() } } }
    private(set) var tracked: TrackedState
    /// Re-read from disk with `tracked` (no cache): a CLI change shows within one clock tick.
    private(set) var automationFile: AutomationFile
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
        automationStore = AutomationStore(url: persist ? AutomationStore.defaultURL : nil)
        automationFile = automationStore.load()
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
                            refreshToken: { Keychain.get($0.refreshService) },
                            saveTokens: { await self.saveTokens($0, $1) },
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

    /// PRs of enabled accounts in `Attention.sorted` order.
    var prs: [TrackedPR] {
        let enabled = enabledIDs
        return Attention.sorted(tracked.prs.values.filter { enabled.contains($0.accountID) }, counting: settings.badgeReasons)
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
        let plan = AutomationMatcher.plan(events: report.events, prs: tracked.prs, automations: automationFile.automations, runs: automationFile.runs,
                                          settingsEnabled: automationFile.enabled, paused: isPaused, accounts: accounts, now: now,
                                          sessions: automationFile.sessions)
        for match in plan.auto { run(match.automation, prID: match.pr.id, event: match.event) }
        // Own events stay silent unless an automation offers to run on one ("when I merge it, …").
        show(report.events.filter { event in !event.isOwn || plan.offers.contains { $0.event.id == event.id && $0.pr.id == event.prID } },
             offers: plan.offers)
    }

    private func reload() {
        tracked = state.state
        automationFile = automationStore.load()
        now = Date()
        noticeCLIAutomations()
    }

    /// One alert per automation a `pullping` write made automatic (`autoNoticeAt` nil), stamped in the file so it shows once,
    /// also when the CLI ran while the app was closed.
    private func noticeCLIAutomations() {
        func due(_ a: Automation) -> Bool { a.source == "cli" && a.mode == .auto && a.enabled && a.autoNoticeAt == nil }
        guard persist, automationFile.automations.contains(where: due) else { return }
        let t = Date()
        let stamped = automationStore.mutate { file -> [Automation] in
            var stamped: [Automation] = []
            for i in file.automations.indices where due(file.automations[i]) {
                file.automations[i].autoNoticeAt = t
                stamped.append(file.automations[i])
            }
            return stamped
        }
        automationFile = automationStore.load()
        for a in stamped {
            let kinds = EventKind.allCases.filter(a.kinds.contains).map(\.label).joined(separator: " or ")
            let scope = switch a.scope { case .any: "pull requests"; case .mine: "your pull requests"; case .others: "others' pull requests" }
            let place = a.pr.map { "\($0.repo) #\($0.number)" } ?? scope + (a.repos.isEmpty ? "" : " in \(a.repos.joined(separator: ", "))")
            let by = a.by.isEmpty ? "" : " (by \(a.by.count > 12 ? a.by.prefix(12) + "…" : a.by))"
            let does = a.usesLinkedSession ? "resumes the pull request's linked session" : "starts \(AutomationCLI.agentWord(a)) in \(a.launcher.title)"
            NotificationPanels.shared.show(
                note: "Added from the command line\(by). PullPing \(does) without asking when \(kinds) arrives on \(place).",
                title: "\(a.name) runs automatically", id: a.id,
                actions: [PanelAction(id: a.id, title: "Open Settings") { SettingsWindow.shared.show(tab: "Automations") }])
        }
    }

    private func mutate(_ body: (inout TrackedState) -> Void) {
        state.update(body)
        reload()
    }

    // MARK: Notifications and reminders

    /// Groups by PR, drops off/muted/snoozed/paused, one panel per PR, one sound per batch. Phone pushes go out per event.
    /// `offers` (ask-mode automations) add Run buttons and make the panel an alert, whatever the kind's style. Handle with
    /// Agent adds its buttons after them, without making the panel an alert.
    func show(_ events: [PREvent], offers: [AutomationMatcher.Match] = []) {
        let t = Date()
        push(events, now: t)
        var shown = false
        let byPR = Dictionary(grouping: events, by: \.prID).sorted { ($0.value.map(\.at).max() ?? t) < ($1.value.map(\.at).max() ?? t) }
        for (prID, group) in byPR {
            guard let pr = tracked.prs[prID], enabledIDs.contains(pr.accountID), settings.allowsNotifications(for: pr, now: t) else { continue }
            let prOffers = offers.filter { $0.pr.id == prID }
            let offered = Set(prOffers.map(\.event.id))
            let styled = group.map { ($0, settings.style(for: $0.kind, mine: pr.roles.contains(.author))) }.filter { $0.1 != .off || offered.contains($0.0.id) }
            guard !styled.isEmpty else { continue }
            let actions = prOffers.map { match in
                PanelAction(id: match.automation.id, title: "Run \(match.automation.name)") { [weak self] in self?.run(match.automation, prID: match.pr.id, event: match.event) }
            } + (handler.handlerEvent(in: styled.map(\.0)).map { handlerActions(pr, event: $0) } ?? [])
            NotificationPanels.shared.show(pr: pr, events: styled.map(\.0), alert: !prOffers.isEmpty || styled.contains { $0.1 == .alert },
                                           account: login(for: pr), autoHide: settings.autoHideSeconds, actions: actions)
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
        let pruneAt = Date()
        var byRef: [String: TrackedPR] = [:]
        for pr in tracked.prs.values { byRef["\(pr.repo.lowercased())#\(pr.number)"] = pr }
        automationStore.mutate { file in
            AutomationStore.prune(&file, now: pruneAt)
            // An hour after merge or close (a "resume right after merge" click still works), or a day after leaving tracking.
            file.sessions.removeAll { link in
                let key = "\(link.pr.repo.lowercased())#\(link.pr.number)"
                guard let pr = byRef[key] else { return trackedLinks.contains(key) && pruneAt.timeIntervalSince(link.setAt) > 86_400 }
                trackedLinks.insert(key)
                return pr.state != .open && pruneAt.timeIntervalSince(pr.closedAt ?? pruneAt) > 3600
            }
        }
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

    // MARK: Automations

    /// Settings > Automations > Run Automations; in automations.json, so `pullping automations on|off` reaches it.
    var automationsEnabled: Bool { automationFile.enabled }

    func setAutomationsEnabled(_ on: Bool) {
        automationStore.mutate { $0.enabled = on }
        reload()
    }

    var rules: [Automation] { automationFile.automations.filter { !$0.isHook } }
    var hooks: [Automation] { automationFile.automations.filter(\.isHook) }

    /// The pull request's Run Automation menu: rules that fit it plus its hooks.
    func automations(for pr: TrackedPR) -> [Automation] {
        AutomationMatcher.applicable(automationFile.automations, pr: pr, sessions: automationFile.sessions)
    }

    /// Why a manual run can't start now (no linked session, or its runs on this pull request are used up), or nil.
    func runBlocked(_ automation: Automation, _ pr: TrackedPR) -> String? {
        if automation.usesLinkedSession && link(for: pr) == nil { return "No linked session" }
        return AutomationMatcher.blocked(automation, prID: pr.id, eventID: "manual:", runs: automationFile.runs, now: now, manual: true)
    }

    var handler: Automation { automationFile.handler }
    /// The handler's buttons and menu items show only with Run Automations on.
    var handlerShown: Bool { automationFile.enabled && automationFile.handler.enabled }
    var links: [SessionLink] { automationFile.sessions.sorted { $0.setAt > $1.setAt } }
    func link(for pr: TrackedPR) -> SessionLink? { automationFile.link(for: pr.repo, number: pr.number) }

    /// The editor's Save. `expecting` (the value the editor opened with) must still be the stored one, else nothing is written
    /// and false comes back: changed from the command line meanwhile. nil = no check (a new rule, Save Anyway).
    @discardableResult
    func setHandler(_ handler: Automation, expecting: Automation? = nil) -> Bool {
        var handler = handler
        handler.source = "ui"
        let saved = automationStore.mutate { file -> Bool in
            guard expecting == nil || Self.same(file.handler, expecting) else { return false }
            file.handler = handler
            return true
        }
        reload()
        return saved
    }

    /// Equal but for provenance and the auto-run notice: what a conflict check compares.
    private static func same(_ a: Automation?, _ b: Automation?) -> Bool {
        func plain(_ a: Automation?) -> Automation? { a.map { var a = $0; a.source = ""; a.by = ""; a.autoNoticeAt = nil; return a } }
        return plain(a) == plain(b)
    }

    /// One switch, changed on the stored value (a rule's Enabled, Handle with Agent): a copy held by a row would undo CLI edits.
    func setEnabled(_ id: UUID, _ on: Bool) {
        automationStore.mutate { file in
            if id == Automation.handlerID {
                file.handler.enabled = on
                file.handler.source = "ui"
            } else if let i = file.automations.firstIndex(where: { $0.id == id }) {
                file.automations[i].enabled = on
                file.automations[i].source = "ui"
            }
        }
        reload()
    }

    /// Settings → Automations → Repository Folders, changed on the stored value.
    func mutateRepoFolders(_ body: (inout RepoFolders) -> Void) {
        automationStore.mutate { body(&$0.repoFolders) }
        reload()
    }

    /// Handle with Agent › Look for earlier sessions.
    func setFindSessions(_ on: Bool) {
        automationStore.mutate { $0.findSessions = on }
        reload()
    }

    /// `repoIndex`, rescanned when older than a minute or the roots changed.
    private func index(_ folders: RepoFolders) -> RepoIndex {
        let t = Date()
        if let index = repoIndex, index.roots == folders.roots, t.timeIntervalSince(index.scannedAt) < 60 { return index }
        let index = RepoIndex.scan(roots: folders.roots, home: NSHomeDirectory(), now: t)
        repoIndex = index
        return index
    }

    // MARK: Earlier sessions

    /// The cached earlier session of a pull request without a link (any setting: Find Earlier Session… fills it too).
    func foundSession(for pr: TrackedPR) -> SessionCandidate? {
        guard link(for: pr) == nil, let entry = found[pr.id], Date().timeIntervalSince(entry.at) < 600 else { return nil }
        return entry.candidate
    }

    /// Looks for the session that last worked on a pull request without a link, in the background, one search at a time, when
    /// Look for earlier sessions is on and nothing is cached. `force` (Find Earlier Session…): always, and `done` gets the
    /// result. A candidate turns an open panel's Handle with Agent into Resume Earlier + New Session (`event`: its event).
    func findSession(prID: String, event: PREvent? = nil, force: Bool = false, done: (@MainActor (SessionCandidate?, Int) -> Void)? = nil) {
        guard let pr = tracked.prs[prID], link(for: pr) == nil else { return }
        if !force {
            guard automationFile.findSessions, !finding.contains(prID) else { return }
            if let entry = found[prID], Date().timeIntervalSince(entry.at) < 600 { return }
        }
        finding.insert(prID)
        let previous = search, env = ProcessInfo.processInfo.environment
        search = Task.detached(priority: .utility) {
            await previous?.value
            let result = SessionFinder.find(url: pr.url, repo: pr.repo, number: pr.number, headRef: pr.isIssue ? nil : pr.headRef, env: env,
                                            exclude: nil, now: Date())
            await self.foundSession(prID, result.candidates.first, scanned: result.scanned, event: event, done: done)
        }
    }

    private func foundSession(_ prID: String, _ candidate: SessionCandidate?, scanned: Int, event: PREvent?,
                              done: (@MainActor (SessionCandidate?, Int) -> Void)?) {
        finding.remove(prID)
        found[prID] = (candidate, scanned, Date())
        if candidate != nil, let pr = tracked.prs[prID] { NotificationPanels.shared.replaceHandlerActions(prID: prID, handlerActions(pr, event: event)) }
        done?(candidate, scanned)
    }

    /// Find Earlier Session…: searches now, whatever the setting, and says what it found in a note with Resume and New Session.
    func findEarlierSession(prID: String) {
        findSession(prID: prID, force: true) { [weak self] candidate, scanned in
            guard let self, let pr = self.tracked.prs[prID] else { return }
            let title = "Earlier session · \(pr.repo) #\(pr.number)"
            guard let c = candidate else {
                NotificationPanels.shared.show(note: "No earlier session found (searched \(scanned) transcripts).", title: title, id: Automation.handlerID, actions: [])
                return
            }
            let name = c.title.isEmpty ? "" : " — \u{201C}\(c.title)\u{201D}"
            NotificationPanels.shared.show(
                note: "Found \(c.agent.rawValue) \(c.sessionID.prefix(8))… \(relativeAge(c.modifiedAt, now: Date()))\(name) in \((c.launchDir as NSString).abbreviatingWithTildeInPath)"
                    + (c.mayBeOpen ? ". It may be open in another terminal." : ""),
                title: title, id: Automation.handlerID,
                actions: [PanelAction(id: Automation.handlerResumeActionID, title: "Resume") { [weak self] in self?.resumeFound(c, prID: prID, event: nil) },
                          PanelAction(id: Automation.handlerID, title: "New Session") { [weak self] in self?.runHandler(prID: prID, mode: .new, event: nil) }])
        }
    }

    /// Resume Earlier Session: links the candidate (source "found"), then Resume Session. Nothing is linked without this click.
    func resumeFound(_ c: SessionCandidate, prID: String, event: PREvent?) {
        guard let pr = tracked.prs[prID] else { return }
        guard let link = c.link(pr: PRRef(repo: pr.repo, number: pr.number), now: Date(), by: "") else {
            NotificationPanels.shared.show(note: "Not resumed: its folders are gone.", title: "Earlier session · \(pr.repo) #\(pr.number)",
                                           id: Automation.handlerID, actions: [])
            return
        }
        automationStore.mutate { $0.setLink(link) }
        reload()
        runHandler(prID: prID, mode: .resume, event: event)
    }

    func removeLink(_ link: SessionLink) {
        automationStore.mutate { $0.sessions.removeAll { $0.pr.matches(link.pr.repo, link.pr.number) } }
        reload()
    }

    /// Handle with Agent on a panel: one button, or Resume Session + New Session when the pull request has a linked session.
    private func handlerActions(_ pr: TrackedPR, event: PREvent?) -> [PanelAction] {
        guard handlerShown else { return [] }
        let id = pr.id
        guard link(for: pr) != nil else {
            if let found = foundSession(for: pr) {
                return [PanelAction(id: Automation.handlerResumeActionID, title: "Resume Earlier") { [weak self] in self?.resumeFound(found, prID: id, event: event) },
                        PanelAction(id: Automation.handlerID, title: "New Session") { [weak self] in self?.runHandler(prID: id, mode: .new, event: event) }]
            }
            findSession(prID: id, event: event)
            return [PanelAction(id: Automation.handlerID, title: "Handle with Agent") { [weak self] in self?.runHandler(prID: id, mode: .handle, event: event) }]
        }
        return [PanelAction(id: Automation.handlerResumeActionID, title: "Resume Session") { [weak self] in self?.runHandler(prID: id, mode: .resume, event: event) },
                PanelAction(id: Automation.handlerID, title: "New Session") { [weak self] in self?.runHandler(prID: id, mode: .new, event: event) }]
    }

    /// `handle`: resume the linked session when there is one, else a new session.
    enum HandlerMode { case handle, resume, new }

    /// A click on Handle with Agent, Resume Session or New Session (`edited`: the editor's Try, unsaved). Needs Run Automations
    /// and the handler on; no caps but a double-click guard.
    func runHandler(prID: String, mode: HandlerMode, event: PREvent?, edited: Automation? = nil) {
        let t = Date()
        guard let pr = tracked.prs[prID], let account = account(pr.accountID) else { return }
        let file = automationStore.load()
        guard file.enabled, edited != nil || file.handler.enabled else {
            AgentLauncher.log.info("handler skipped: Handle with Agent or Run Automations is off")
            NSSound.beep()
            return
        }
        var handler = edited ?? file.handler
        let resume = mode == .resume || (mode == .handle && file.link(for: pr.repo, number: pr.number) != nil)
        handler.sessionID = resume ? Automation.linkedSession : nil
        launch(handler, pr: pr, login: account.login, event: event, eventID: "manual:\(t.ISO8601Format())", key: "handler|\(prID)", file: file, at: t)
    }

    /// Plans, launches and records one run. `event` nil = manual (Run menu, Try). Every run checks the duplicate and
    /// max-runs caps; the cooldown and per-poll budget were applied by `AutomationMatcher.plan` for automatic ones.
    /// Event runs (Run buttons, automatic) launch the automation as saved now, and not at all once it is off, removed or expired.
    func run(_ automation: Automation, prID: String, event: PREvent?) {
        let t = Date()
        guard let pr = tracked.prs[prID], let account = account(pr.accountID) else { return }
        let file = automationStore.load()
        guard file.enabled else { return }
        var automation = automation
        if event != nil {
            guard let current = AutomationMatcher.current(automation.id, in: file.automations, now: t) else {
                AgentLauncher.log.info("run skipped: the automation was turned off, removed or expired")
                NSSound.beep()
                return
            }
            automation = current
        }
        let eventID = event?.id ?? "manual:\(t.ISO8601Format())"
        let key = "\(automation.id)|\(prID)|\(eventID)"
        if launching.contains(key) { return }
        if let reason = AutomationMatcher.blocked(automation, prID: prID, eventID: eventID, runs: file.runs, now: t, manual: true) {
            AgentLauncher.log.info("run skipped: \(reason, privacy: .public)")
            NSSound.beep()
            return
        }
        launch(automation, pr: pr, login: account.login, event: event, eventID: eventID, key: key, file: file, at: t)
    }

    /// Resolves a linked session, plans, launches and records one run. A new Claude session starts with an id PullPing picks
    /// and, once launched, is the pull request's linked session.
    private func launch(_ automation: Automation, pr: TrackedPR, login: String, event: PREvent?, eventID: String, key: String,
                        file: AutomationFile, at t: Date) {
        if launching.contains(key) { return }
        if automation.usesLinkedSession && file.link(for: pr.repo, number: pr.number) == nil {
            AgentLauncher.log.info("run skipped: \(LaunchError.noLinkedSession.localizedDescription, privacy: .public)")
            NSSound.beep()
            return
        }
        launching.insert(key)
        let record = { [weak self] (a: Automation, error: String?, link: SessionLink?, note: String) in
            guard let self else { return }
            let name = a.id == Automation.handlerID ? "\(a.name) (\(AutomationCLI.sessionWord(a)))" : a.name
            self.automationStore.mutate {
                $0.runs.append(RunRecord(automationID: a.id, prID: pr.id, eventID: eventID, at: t, ok: error == nil, detail: error ?? a.launcher.title + note,
                                         label: "\(name) · \(pr.repo) #\(pr.number)"))
                if error == nil, let link { $0.setLink(link) }
            }
            self.launching.remove(key)
            self.reload()
        }
        do {
            let index = index(file.repoFolders)
            let (a, relinked, note) = try file.resolved(automation, repo: pr.repo, number: pr.number, headRef: pr.headRef,
                                                        env: ProcessInfo.processInfo.environment, index: index)
            if let relinked { automationStore.mutate { $0.setLink(relinked) } }
            let newID = LaunchPlanner.newSessionID(for: a)
            // Where the pull request's code is: its linked session's folder, else a found session's (`RepoLocator` hints).
            let candidate = found[pr.id]?.candidate
            let hints = [file.link(for: pr.repo, number: pr.number)?.cwd, candidate?.workDir, candidate?.launchDir].compactMap { $0 }
            let plan = try LaunchPlanner.plan(a, pr: pr, event: event, account: login, runID: UUID().uuidString,
                                              runsDir: AgentLauncher.runsDir, home: NSHomeDirectory(), newSessionID: newID,
                                              folders: file.repoFolders, index: index, hints: hints, installed: { $0.isInstalled })
            let link = newID.map { SessionLink(pr: PRRef(repo: pr.repo, number: pr.number), agent: .claude, sessionID: $0, cwd: plan.cwd, setAt: t, source: "app", by: "") }
            Task { record(a, await AgentLauncher.launch(plan), link, note) }
        } catch {
            AgentLauncher.log.error("run not planned: \(error.localizedDescription, privacy: .public)")
            record(automation, error.localizedDescription, nil, "")
        }
    }

    /// The rule editor's Save; `expecting` as in `setHandler`.
    @discardableResult
    func saveAutomation(_ automation: Automation, expecting: Automation? = nil) -> Bool {
        var automation = automation
        automation.source = "ui"  // last writer; the CLI sets "cli"
        let saved = automationStore.mutate { file -> Bool in
            let index = file.automations.firstIndex { $0.id == automation.id }
            guard expecting == nil || Self.same(index.map { file.automations[$0] }, expecting) else { return false }
            if let index { file.automations[index] = automation } else { file.automations.append(automation) }
            return true
        }
        reload()
        return saved
    }

    func removeAutomation(_ id: UUID) {
        automationStore.mutate { $0.automations.removeAll { $0.id == id } }
        reload()
    }

    // MARK: Accounts

    /// Stores the token (and a Sign in with GitHub refresh token) in the keychain, then polls the new account (its first sync is silent).
    func addAccount(_ viewer: Viewer, token: String, refreshToken: String, kind: AuthKind) {
        let account = Account(login: viewer.login, avatarURL: viewer.avatarURL, authKind: kind)
        Keychain.set(account.tokenService, token)
        Keychain.set(account.refreshService, refreshToken)
        accounts.append(account)
        statuses[account.id] = viewer.status
        poll(.accountAdded)
    }

    /// Refresh token first: a stale access token is refreshed again, a stale refresh token is dead.
    /// On the main actor, like `removeAccount`, so tokens refreshed for an account removed meanwhile are dropped, not saved as orphans.
    private func saveTokens(_ account: Account, _ tokens: OAuthTokens) -> Bool {
        guard self.account(account.id) != nil else { return false }
        return Keychain.set(account.refreshService, tokens.refresh) && Keychain.set(account.tokenService, tokens.access)
    }

    /// Deletes the keychain items and the account's tracked pull requests.
    func removeAccount(_ id: UUID) {
        guard let account = account(id) else { return }
        Keychain.set(account.tokenService, "")
        Keychain.set(account.refreshService, "")
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
