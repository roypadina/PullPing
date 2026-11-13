import AppKit
import Observation
import PullPingCore

/// Sidebar rows and status panel filters: whose turn it is (0.7.0 design §2.1). Needs Me gathers the items that need me
/// from the other rows; every item lives in one of the others (`home`). Hidden items show only under Muted & Hidden.
/// Raw values are stored (panel filter); an unknown one falls back to Needs Me.
enum Filter: String, CaseIterable {
    case needsMe, myPRs, reviews, issues, watching, closed, mutedHidden

    var title: String {
        switch self {
        case .needsMe: "Needs Me"
        case .myPRs: "My Pull Requests"
        case .reviews: "Reviews"
        case .issues: "Issues"
        case .watching: "Watching"
        case .closed: "Closed"
        case .mutedHidden: "Muted & Hidden"
        }
    }

    var symbol: String {
        switch self {
        case .needsMe: "tray"
        case .myPRs: "person"
        case .reviews: "eye"
        case .issues: "smallcircle.filled.circle"
        case .watching: "bubble.left.and.bubble.right"
        case .closed: "archivebox"
        case .mutedHidden: "bell.slash"
        }
    }

    /// The row an item lives in: its bucket's area, or Muted & Hidden while hidden. Never Needs Me.
    static func home(_ pr: TrackedPR) -> Filter {
        if pr.hidden { return .mutedHidden }
        switch Attention.bucket(pr) {
        case .fix, .merge, .waitingReview, .waitingCI, .waitingMerge, .draft: return .myPRs
        case .review, .reReview, .teamReview, .reviewed: return .reviews
        case .issueAssigned, .issueMine, .issueMentioned: return .issues
        case .watching: return .watching
        case .closed: return .closed
        }
    }

    /// `counting`: the reasons that count (Settings > General), for Needs Me.
    func matches(_ pr: TrackedPR, counting: Set<NeedReason>) -> Bool {
        switch self {
        case .needsMe: Attention.needReason(pr, counting: counting) != nil
        case .mutedHidden: pr.muted || pr.hidden
        default: Filter.home(pr) == self
        }
    }

    /// The row's badge counts only its "your turn" sections (Waiting on Others, Reviewed and the rest never count).
    func badges(_ pr: TrackedPR) -> Bool {
        switch self {
        case .needsMe, .issues: true
        case .myPRs: [.fix, .merge].contains(Attention.bucket(pr))
        case .reviews: [.review, .reReview, .teamReview].contains(Attention.bucket(pr))
        case .watching, .closed, .mutedHidden: false
        }
    }

    /// The list's sections in order, empty ones dropped. `prs` come in `Attention.sorted` order; sections that are not
    /// somebody's queue (Waiting on Others, Reviewed, Watching, Closed…) are re-sorted by latest activity.
    func sections(_ prs: [TrackedPR]) -> [ListSection] {
        func by(_ pr: TrackedPR) -> String {
            let bucket = Attention.bucket(pr)
            switch self {
            case .needsMe:
                if [.review, .reReview, .teamReview].contains(bucket) { return "To Review" }
                return !pr.isIssue && pr.roles.contains(.author) ? "Your Pull Requests" : "Mentions & Assigned"
            case .myPRs: return [.fix, .merge].contains(bucket) ? "Your Turn" : bucket == .draft ? "Drafts" : "Waiting on Others"
            case .reviews: return [.review, .reReview].contains(bucket) ? "Needs Your Review" : bucket == .teamReview ? "Team Requests" : "Reviewed"
            case .issues: return bucket == .issueAssigned ? "Assigned to Me" : bucket == .issueMine ? "Opened by Me" : "Mentioned"
            case .watching, .closed: return ""
            case .mutedHidden: return pr.hidden ? "Hidden" : "Muted"
            }
        }
        let order: [String] = switch self {
        case .needsMe: ["To Review", "Your Pull Requests", "Mentions & Assigned"]
        case .myPRs: ["Your Turn", "Waiting on Others", "Drafts"]
        case .reviews: ["Needs Your Review", "Team Requests", "Reviewed"]
        case .issues: ["Assigned to Me", "Opened by Me", "Mentioned"]
        case .watching, .closed: [""]
        case .mutedHidden: ["Muted", "Hidden"]
        }
        let queues: Set<String> = ["To Review", "Your Pull Requests", "Mentions & Assigned", "Your Turn", "Needs Your Review", "Team Requests",
                                   "Assigned to Me", "Opened by Me", "Mentioned"]
        let grouped = Dictionary(grouping: prs, by: by)
        return order.compactMap { title in
            grouped[title].map { ListSection(title: title, prs: queues.contains(title) ? $0 : Attention.sorted($0, counting: []), collapsed: title == "Drafts") }
        }
    }
}

/// One titled part of a list ("" = untitled); `collapsed` until opened (Drafts).
struct ListSection {
    let title: String
    let prs: [TrackedPR]
    var collapsed = false
}

/// Which accounts a list shows.
enum Scope: Hashable {
    case all, account(UUID)

    func matches(_ pr: TrackedPR) -> Bool {
        if case .account(let id) = self { return pr.accountID == id }
        return true
    }

    func matches(_ entry: ActivityEntry) -> Bool {
        if case .account(let id) = self { return entry.accountID == id }
        return true
    }

    /// `DefaultsKey.panelAccount` value: empty for All Accounts.
    var key: String {
        if case .account(let id) = self { return id.uuidString }
        return ""
    }
}

/// A main-window sidebar row: All Accounts or one account, plus a filter or Activity.
struct SidebarItem: Hashable {
    var scope: Scope
    var filter: Filter
    /// The scope's activity log instead of a pull request list (`filter` unused).
    var activity = false
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
    /// Background runs whose process runs now, by run id (at most `BackgroundSettings.maxRunning`).
    @ObservationIgnored private var backgroundJobs: [String: BackgroundJob] = [:]
    /// Everything PullPing saw and did (`activity.jsonl`); memory only when `!persist`.
    @ObservationIgnored let activityLog: ActivityLog
    @ObservationIgnored private var activityCompactedAt = Date.distantPast
    /// The activity log, oldest first; the file's copy, updated after each write.
    private(set) var activity: [ActivityEntry] = []
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
    var selection: SidebarItem? = SidebarItem(scope: .all, filter: .needsMe)
    /// Main-window selection; the Pull Request menu acts on it.
    var selectedID: String?
    /// Activity entries after this are new: the sidebar dot and the feed's New section. Set when the feed is left.
    var activitySeenAt: Date { didSet { if persist { UserDefaults.standard.set(activitySeenAt, forKey: DefaultsKey.activitySeenAt) } } }
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
        activityLog = ActivityLog(url: persist ? ActivityLog.defaultURL() : nil)
        activitySeenAt = persist ? UserDefaults.standard.object(forKey: DefaultsKey.activitySeenAt) as? Date ?? Date() : Date()
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
        compactActivity()
        // Runs that were running when PullPing quit stay interrupted; the queue goes on.
        automationStore.mutate { BackgroundQueue.recover(&$0.runs, now: Date()) }
        reload()
        pumpBackground()
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

    func prs(_ scope: Scope, _ filter: Filter) -> [TrackedPR] {
        prs.filter { scope.matches($0) && filter.matches($0, counting: settings.badgeReasons) }
    }

    /// Sidebar badges (the row's "your turn" sections) and panel segments (`filter` nil: every row), by the menu-bar measure
    /// ("all unread" when the count is off).
    func count(_ scope: Scope, _ filter: Filter? = nil) -> Int {
        let enabled = enabledIDs, needsMe = settings.badgeMode == .needsMe, counting = settings.badgeReasons
        return tracked.prs.values.filter { pr in
            enabled.contains(pr.accountID) && scope.matches(pr) && (filter.map { $0.matches(pr, counting: counting) && $0.badges(pr) } ?? true)
                && (needsMe ? Attention.needsMe(pr, counting: counting) : Attention.isAttention(pr))
        }.count
    }

    /// The sidebar row the list shows: per-account layout has no All Accounts rows, a removed account falls back.
    var listSelection: SidebarItem {
        var item = selection ?? SidebarItem(scope: .all, filter: .needsMe)
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

    /// The scope has activity after `activitySeenAt` (the log is oldest first).
    func hasNewActivity(_ scope: Scope) -> Bool { (activity.last { scope.matches($0) }?.at ?? .distantPast) > activitySeenAt }

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
            await handle(await poller.pollAll(accounts: accounts, reason: reason))
        }
    }

    func setPaused(_ paused: Bool) {
        guard let poller else { return }
        Task { await poller.setPaused(paused) }
        if !paused { poll(.wake) }
    }

    func handle(_ report: PollReport) async {
        syncing = false
        offline = report.offline
        for (id, result) in report.results { statuses[id] = result.status }
        reload()
        let plan = AutomationMatcher.plan(events: report.events, prs: tracked.prs, automations: automationFile.automations, runs: automationFile.runs,
                                          settingsEnabled: automationFile.enabled, paused: isPaused, accounts: accounts, now: now,
                                          sessions: automationFile.sessions, background: automationFile.background.enabled)
        // An automatic run never types into or focuses a session the user may be typing in: one open in Ghostex becomes an
        // offer with Go to Session.
        var live: [AutomationMatcher.Match] = []
        for match in plan.auto {
            if let id = ghostexSession(match), await AgentLauncher.runsInGhostex(sessionID: id) { live.append(match) } else {
                run(match.automation, prID: match.pr.id, event: match.event, auto: true)
            }
        }
        record(live.map { match in
            var entry = ActivityEntry(run: match.automation, pr: match.pr, account: account(match.pr.accountID)?.login ?? "", event: match.event.kind,
                                      error: nil, at: Date())
            entry.ok = nil
            entry.error = "session is running in Ghostex: asked instead"
            return entry
        })
        // A new pull request's seeded history stays out of panels and the activity log. Own events go on: `show` logs them
        // and shows one only when an automation offers to run on it ("when I merge it, …").
        show(report.events.filter { $0.seeded != true }, offers: plan.offers + live, live: live)
    }

    /// The agent session an automatic run would resume in Ghostex (its pull request's link, or a hook's own session), else nil.
    private func ghostexSession(_ match: AutomationMatcher.Match) -> String? {
        let a = match.automation
        guard a.launcher == .ghostex, a.backgroundAction == nil else { return nil }
        let id = a.usesLinkedSession ? link(for: match.pr)?.sessionID : a.sessionID
        return id.flatMap { $0.isEmpty ? nil : $0 }
    }

    private func reload() {
        tracked = state.state
        automationFile = automationStore.load()
        now = Date()
        noticeCLIAutomations()
        noticeCLIBackground()
    }

    /// `pullping background on` from a shell (an agent session, say): one note and an Activity line, so it never goes unseen.
    private func noticeCLIBackground() {
        guard persist, let by = automationFile.background.turnedOnBy else { return }
        automationStore.mutate { $0.background.turnedOnBy = nil }
        automationFile = automationStore.load()
        guard automationFile.background.enabled else { return }
        let who = by.isEmpty ? "" : by.count > 12 ? String(by.prefix(12)) + "…" : by
        record([ActivityEntry(setting: "Background Runs", what: "Turned on", by: who, at: Date())])
        NotificationPanels.shared.show(
            note: "Turned on from the command line\(who.isEmpty ? "" : " (by \(who))"). Review in Background and Summarize can now start your agent without a terminal; rules with a background action run too. It posts nothing by itself.",
            title: "Background Runs are on", id: Automation.backgroundID,
            actions: [PanelAction(id: Automation.backgroundID, title: "Open Settings") { SettingsWindow.shared.show(tab: "Automations") }])
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
            let does = a.backgroundAction.map { "drafts a \($0 == .review ? "review" : "summary") in the background (it posts nothing)" }
                ?? (a.usesLinkedSession ? "resumes the pull request's linked session" : "starts \(AutomationCLI.agentWord(a)) in \(a.launcher.title)")
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

    /// Groups by PR, drops own/activity-only/off/muted/snoozed/paused (`ActivityEntry.Quiet`), one panel per PR, one sound per
    /// batch. A panel's style is its reasons' (`Notify.reason`, Settings > Notifications). Phone pushes go out per event. Every
    /// event goes to the activity log with what happened to it.
    /// `offers` (ask-mode automations) add Run buttons and make the panel an alert, whatever the reason's style (`live`: Go to
    /// Session, an automatic run whose session is open in Ghostex). Handle with Agent adds its buttons after them, without
    /// making the panel an alert.
    func show(_ events: [PREvent], offers: [AutomationMatcher.Match] = [], live: [AutomationMatcher.Match] = []) {
        let t = Date()
        push(events, now: t)
        var shown = false
        var logged: [ActivityEntry] = []
        defer { record(logged) }
        let byPR = Dictionary(grouping: events, by: \.prID).sorted { ($0.value.map(\.at).max() ?? t) < ($1.value.map(\.at).max() ?? t) }
        for (prID, group) in byPR {
            guard let pr = tracked.prs[prID], enabledIDs.contains(pr.accountID) else { continue }
            let prOffers = offers.filter { $0.pr.id == prID }
            let offered = Set(prOffers.map(\.event.id))
            let quiet = group.map { ActivityEntry.Quiet.reason($0, pr: pr, settings: settings, offered: offered.contains($0.id), now: t) }
            let styled = zip(group, quiet).filter { $0.1 == nil }.map { event, _ in (event, Notify.reason(event, pr: pr).map(settings.needStyle) ?? .alert) }
            let alert = !prOffers.isEmpty || styled.contains { $0.1 == .alert }
            let user = account(pr.accountID)?.login ?? ""
            logged += zip(group, quiet).map { event, quiet in
                ActivityEntry(event: event, pr: pr, account: user, panel: quiet != nil ? .notShown : alert ? .alert : .banner, quiet: quiet,
                              phone: settings.pushesToPhone(event, pr: pr, now: t), at: t)
            }
            guard !styled.isEmpty else { continue }
            let actions = prOffers.map { match in
                PanelAction(id: match.automation.id, title: live.contains(match) ? "Go to Session" : match.automation.backgroundAction?.title ?? "Run \(match.automation.name)") { [weak self] in
                    self?.run(match.automation, prID: match.pr.id, event: match.event)
                }
            } + (handler.handlerEvent(in: styled.map(\.0)).map { handlerActions(pr, event: $0, scenario: Scenario.derive(events: styled.map(\.0), pr: pr)) } ?? [])
            NotificationPanels.shared.show(pr: pr, events: styled.map(\.0), alert: alert,
                                           account: login(for: pr), autoHide: settings.autoHideSeconds, actions: actions)
            shown = true
        }
        if shown && settings.playSound { NSSound(named: "Pop")?.play() }
    }

    private var ntfyConfig: NtfyConfig {
        NtfyConfig(server: settings.ntfyServer, topic: settings.ntfyTopic, token: ntfyToken, fallbackURL: ntfyFallbackURL)
    }

    /// One push per opted-in event, independent of the panel style. An event whose reason (`Notify.reason`) is Alert in
    /// Settings > Notifications goes out at priority 4, the rest at 3.
    private func push(_ events: [PREvent], now: Date) {
        let config = ntfyConfig
        for event in events {
            guard let pr = tracked.prs[event.prID], enabledIDs.contains(pr.accountID), settings.pushesToPhone(event, pr: pr, now: now) else { continue }
            let message = Ntfy.Message(
                title: "\(event.kind.label): \(pr.repo) #\(pr.number)",
                body: pr.title + "\n" + (event.summary.isEmpty ? event.line : "\(event.actor): \(event.summary)")
                    + (login(for: pr).map { "\nAccount: \($0)" } ?? ""),
                priority: Notify.reason(event, pr: pr).map(settings.needStyle) == .alert ? 4 : 3,
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

    /// Adds to the activity log; `activity` follows once written.
    func record(_ entries: [ActivityEntry]) { activityLog.append(entries, done: activitySetter) }

    /// Re-reads the activity log (`pullping run` appends too) and drops what is past Keep activity for. Launch, daily, and when
    /// the Activity list appears.
    func compactActivity() {
        activityCompactedAt = Date()
        activityLog.compact(days: settings.activityDays, now: activityCompactedAt, done: activitySetter)
    }

    /// From the log's background queue to `activity`, in order.
    private var activitySetter: @Sendable ([ActivityEntry]) -> Void {
        { all in DispatchQueue.main.async { MainActor.assumeIsolated { self.activity = all } } }
    }

    private func tick() {
        let pruneAt = Date()
        if pruneAt.timeIntervalSince(activityCompactedAt) > 86_400 { compactActivity() }
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
        pumpBackground()  // runs queued from the command line, and its cancels
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
        guard let pr = tracked.prs[id],
              listSelection.activity || !(listSelection.scope.matches(pr) && listSelection.filter.matches(pr, counting: settings.badgeReasons)) else { return }
        selection = SidebarItem(scope: settings.inboxLayout == .unified ? .all : .account(pr.accountID), filter: Filter.home(pr))
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
        // launcher / customCommand mirror the target: a change of the default is not an edit of this automation.
        func plain(_ a: Automation?) -> Automation? { a.map { var a = $0; a.source = ""; a.by = ""; a.autoNoticeAt = nil; a.launcher = .terminal; a.customCommand = ""; return a } }
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

    /// Settings → Automations → Open With and Prompts, changed on the stored value.
    func mutateAutomationFile(_ body: (inout AutomationFile) -> Void) {
        automationStore.mutate(body)
        reload()
    }

    /// Handle with Agent › Look for earlier sessions.
    func setFindSessions(_ on: Bool) {
        automationStore.mutate { $0.findSessions = on }
        reload()
    }

    /// `repoIndex`, rescanned when older than a minute or the roots changed.
    func index(_ folders: RepoFolders) -> RepoIndex {
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
        if candidate != nil, let pr = tracked.prs[prID] {
            NotificationPanels.shared.replaceHandlerActions(prID: prID, handlerActions(pr, event: event, scenario: nil))
        }
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
    func resumeFound(_ c: SessionCandidate, prID: String, event: PREvent?, target: String? = nil, scenario: Scenario? = nil) {
        guard let pr = tracked.prs[prID] else { return }
        guard let link = c.link(pr: PRRef(repo: pr.repo, number: pr.number), now: Date(), by: "") else {
            NotificationPanels.shared.show(note: "Not resumed: its folders are gone.", title: "Earlier session · \(pr.repo) #\(pr.number)",
                                           id: Automation.handlerID, actions: [])
            return
        }
        automationStore.mutate { $0.setLink(link) }
        reload()
        runHandler(prID: prID, mode: .resume, event: event, target: target, scenario: scenario)
    }

    func removeLink(_ link: SessionLink) {
        automationStore.mutate { $0.sessions.removeAll { $0.pr.matches(link.pr.repo, link.pr.number) } }
        reload()
    }

    /// Handle with Agent on a panel: one button, or Resume Session + New Session when the pull request has a linked session,
    /// all on the default target; then a chevron with every choice (`HandlerMenu`) when there is more than the buttons hold.
    /// `scenario`: from the panel's events (nil: the handler's event and the pull request).
    private func handlerActions(_ pr: TrackedPR, event: PREvent?, scenario: Scenario?) -> [PanelAction] {
        guard handlerShown else { return [] }
        let id = pr.id
        let linked = link(for: pr) != nil
        let more = linked || automationFile.targets.count > 1 || backgroundOn
            ? [PanelAction(id: Automation.handlerMenuActionID, title: "More agent options", run: {}) { [weak self] in
                self.map { HandlerMenu.nsMenu(store: $0, pr: pr, event: event, scenario: scenario) } ?? NSMenu()
            }] : []
        guard linked else {
            if let found = foundSession(for: pr) {
                return [PanelAction(id: Automation.handlerResumeActionID, title: "Resume Earlier") { [weak self] in self?.resumeFound(found, prID: id, event: event, scenario: scenario) },
                        PanelAction(id: Automation.handlerID, title: "New Session") { [weak self] in self?.runHandler(prID: id, mode: .new, event: event, scenario: scenario) }] + more
            }
            findSession(prID: id, event: event)
            return [PanelAction(id: Automation.handlerID, title: "Handle with Agent") { [weak self] in self?.runHandler(prID: id, mode: .handle, event: event, scenario: scenario) }] + more
        }
        return [PanelAction(id: Automation.handlerResumeActionID, title: "Resume Session") { [weak self] in self?.runHandler(prID: id, mode: .resume, event: event, scenario: scenario) },
                PanelAction(id: Automation.handlerID, title: "New Session") { [weak self] in self?.runHandler(prID: id, mode: .new, event: event, scenario: scenario) }] + more
    }

    /// Handle with Agent's choices for a pull request, by target (`HandlerMenuModel`).
    /// Then In Background, with Background Runs on.
    func handlerSections(_ pr: TrackedPR) -> [HandlerMenuSection] {
        (handlerShown ? HandlerMenuModel.sections(targets: automationFile.targets, linked: link(for: pr)?.sessionID,
                                                  earlier: foundSession(for: pr).map { "\($0.sessionID.prefix(4))…, \(relativeAge($0.modifiedAt, now: now))" }) : [])
            + (backgroundOn ? HandlerMenuModel.background(actions: BackgroundAction.allCases.filter { BackgroundQueue.eligible($0, pr: pr) == nil },
                                                          running: backgroundRun(for: pr).flatMap { $0.status?.isActive == true ? $0.background : nil }) : [])
    }

    /// The Handle with Agent menus show: the handler on, or Background Runs (their In Background section).
    var agentMenuShown: Bool { handlerShown || backgroundOn }

    /// A menu choice (`HandlerChoice`) on a pull request.
    func perform(_ choice: HandlerChoice, prID: String, event: PREvent?, scenario: Scenario? = nil) {
        switch choice {
        case .handle(let target): runHandler(prID: prID, mode: .handle, event: event, target: target, scenario: scenario)
        case .resume(let target, let prompt): runHandler(prID: prID, mode: .resume, event: event, target: target, prompt: prompt, scenario: scenario)
        case .new(let target): runHandler(prID: prID, mode: .new, event: event, target: target, scenario: scenario)
        case .resumeEarlier(let target):
            if let pr = tracked.prs[prID], let found = foundSession(for: pr) { resumeFound(found, prID: prID, event: event, target: target, scenario: scenario) }
        case .findEarlier: findEarlierSession(prID: prID)
        case .background(let action): startBackground(action, prID: prID, event: event)
        case .cancelBackground: if let pr = tracked.prs[prID], let id = backgroundRun(for: pr)?.runID { cancelBackground(id) }
        }
    }

    /// `handle`: resume the linked session when there is one, else a new session.
    enum HandlerMode { case handle, resume, new }

    /// A click on Handle with Agent, Resume Session or New Session (`edited`: the editor's Try, unsaved). Needs Run Automations
    /// and the handler on; no caps but a double-click guard. `target`: an Open With choice (nil: the default); `prompt` false:
    /// Resume Without Prompt; `scenario` nil: from `event` and the pull request.
    func runHandler(prID: String, mode: HandlerMode, event: PREvent?, edited: Automation? = nil, target: String? = nil, prompt: Bool = true,
                    scenario: Scenario? = nil) {
        let t = Date()
        guard let pr = tracked.prs[prID], let account = account(pr.accountID) else { return }
        let file = automationStore.load()
        guard file.enabled, edited != nil || file.handler.enabled else {
            AgentLauncher.log.info("handler skipped: Handle with Agent or Run Automations is off")
            runFailed("Handle with Agent didn't run", "Turn on Run Automations and Handle with Agent in Settings → Automations.", id: Automation.handlerID)
            return
        }
        var handler = edited ?? file.handler
        let resume = mode == .resume || (mode == .handle && file.link(for: pr.repo, number: pr.number) != nil)
        handler.sessionID = resume ? Automation.linkedSession : nil
        launch(handler, pr: pr, login: account.login, event: event, eventID: "manual:\(t.ISO8601Format())", key: "handler|\(prID)", file: file, at: t,
               target: target, prompt: prompt || !resume, scenario: scenario)
    }

    /// A run that didn't start: a beep alone went unnoticed, so a note panel says why (Recent Runs and the log keep it too).
    private func runFailed(_ title: String, _ message: String, id: UUID) {
        NSSound.beep()
        NotificationPanels.shared.show(note: message, title: title, id: id, actions: [])
    }

    /// Plans, launches and records one run. `event` nil = manual (Run menu, Try). Every run checks the duplicate and
    /// max-runs caps; the cooldown and per-poll budget were applied by `AutomationMatcher.plan` for automatic ones.
    /// Event runs (Run buttons, automatic) launch the automation as saved now, and not at all once it is off, removed or expired.
    /// `auto`: started on its own (never focuses or types into a running session).
    func run(_ automation: Automation, prID: String, event: PREvent?, auto: Bool = false) {
        let t = Date()
        guard let pr = tracked.prs[prID], let account = account(pr.accountID) else { return }
        let file = automationStore.load()
        guard file.enabled else { return }
        var automation = automation
        if event != nil {
            guard let current = AutomationMatcher.current(automation.id, in: file.automations, now: t) else {
                AgentLauncher.log.info("run skipped: the automation was turned off, removed or expired")
                runFailed("\(automation.name) didn't run", "It was turned off, removed or expired.", id: automation.id)
                return
            }
            automation = current
        }
        let eventID = event?.id ?? "manual:\(t.ISO8601Format())"
        let key = "\(automation.id)|\(prID)|\(eventID)"
        if launching.contains(key) { return }
        if let reason = AutomationMatcher.blocked(automation, prID: prID, eventID: eventID, runs: file.runs, now: t, manual: true) {
            AgentLauncher.log.info("run skipped: \(reason, privacy: .public)")
            runFailed("\(automation.name) didn't run", reason, id: automation.id)
            return
        }
        // A background rule ends in a draft: no terminal, no target, session or prompt of its own.
        if let action = automation.backgroundAction { return startBackground(action, prID: prID, event: event, rule: automation, auto: auto) }
        launch(automation, pr: pr, login: account.login, event: event, eventID: eventID, key: key, file: file, at: t, auto: auto)
    }

    /// Resolves a linked session and the target, plans, launches and records one run. A new Claude session starts with an id
    /// PullPing picks and, once launched, is the pull request's linked session. `scenario` nil: from `event` and the pull request.
    private func launch(_ automation: Automation, pr: TrackedPR, login: String, event: PREvent?, eventID: String, key: String,
                        file: AutomationFile, at t: Date, auto: Bool = false, target: String? = nil, prompt: Bool = true, scenario: Scenario? = nil) {
        if launching.contains(key) { return }
        if automation.usesLinkedSession && file.link(for: pr.repo, number: pr.number) == nil {
            AgentLauncher.log.info("run skipped: \(LaunchError.noLinkedSession.localizedDescription, privacy: .public)")
            runFailed("\(automation.name) didn't run", "\(pr.repo) #\(pr.number): \(LaunchError.noLinkedSession.localizedDescription)", id: automation.id)
            return
        }
        launching.insert(key)
        let scenario = scenario ?? Scenario.derive(events: event.map { [$0] } ?? [], pr: pr)
        let record = { [weak self] (a: Automation, error: String?, link: SessionLink?, note: String) in
            guard let self else { return }
            let name = AutomationCLI.runName(a, scenario: scenario, prompt: prompt)
            self.automationStore.mutate {
                $0.runs.append(RunRecord(automationID: a.id, prID: pr.id, eventID: eventID, at: t, ok: error == nil, detail: error ?? a.launcher.title + note,
                                         label: "\(name) · \(pr.repo) #\(pr.number)"))
                if error == nil, let link { $0.setLink(link) }
            }
            self.record([ActivityEntry(run: a, pr: pr, account: login, event: event?.kind, error: error, at: t, scenario: scenario, prompt: prompt)])
            if let error { self.runFailed("Couldn't start \(name)", "\(pr.repo) #\(pr.number): \(error)", id: a.id) }
            self.launching.remove(key)
            self.reload()
        }
        do {
            let index = index(file.repoFolders)
            let (a, relinked, note, opens) = try file.resolved(automation, target: target, repo: pr.repo, number: pr.number, headRef: pr.headRef,
                                                               env: ProcessInfo.processInfo.environment, index: index)
            if let relinked { automationStore.mutate { $0.setLink(relinked) } }
            let newID = LaunchPlanner.newSessionID(for: a)
            // Where the pull request's code is: its linked session's folder, else a found session's (`RepoLocator` hints).
            let candidate = found[pr.id]?.candidate
            let hints = [file.link(for: pr.repo, number: pr.number)?.cwd, candidate?.workDir, candidate?.launchDir].compactMap { $0 }
            var plan = try LaunchPlanner.plan(a, pr: pr, event: event, account: login, runID: UUID().uuidString,
                                              runsDir: AgentLauncher.runsDir, home: NSHomeDirectory(), newSessionID: newID,
                                              folders: file.repoFolders, index: index, hints: hints, installed: { $0.isInstalled }, target: opens,
                                              prompt: prompt, scenario: scenario, task: file.task(scenario))
            if auto { plan.focusRunning = nil }  // the user may be typing in it: `handle` turned a live one into an ask already
            let link = newID.map { SessionLink(pr: PRRef(repo: pr.repo, number: pr.number), agent: .claude, sessionID: $0, cwd: plan.cwd, setAt: t, source: "app", by: "") }
            Task {
                let launched = await AgentLauncher.launch(plan)
                record(a, launched.error, link, note + launched.note)
            }
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

    // MARK: Background runs

    /// Background Runs in Settings → Automations, under Run Automations.
    var backgroundOn: Bool { automationFile.enabled && automationFile.background.enabled }

    /// The pull request's latest background run (the detail pane's Agent Draft section, Cancel in the menus).
    func backgroundRun(for pr: TrackedPR) -> RunRecord? { automationFile.runs.last { $0.prID == pr.id && $0.background != nil } }

    /// A run's draft while it exists (7 days, until discarded or posted).
    func draft(_ runID: String) -> BackgroundDraft? { persist ? BackgroundDraft.load(runID: runID, runsDir: AgentLauncher.runsDir) : nil }

    /// Review in Background or Summarize (a menu, `rule`'s background action, `auto`: a rule on its own): checks the gates and caps
    /// (`BackgroundQueue`), queues the run, starts it when a slot is free. A refusal is logged; a click also gets a note.
    func startBackground(_ action: BackgroundAction, prID: String, event: PREvent?, rule: Automation? = nil, auto: Bool = false) {
        guard let pr = tracked.prs[prID], let account = account(pr.accountID) else { return }
        let t = Date(), runID = UUID().uuidString.lowercased(), title = rule?.name ?? action.title
        let refusal = automationStore.mutate { file -> String? in
            guard file.enabled else { return "Run Automations is off" }
            if let reason = BackgroundPlanner.unsupported((rule ?? file.handler).agent) ?? BackgroundQueue.eligible(action, pr: pr)
                ?? BackgroundQueue.admit(action, pr: pr, settings: file.background, runs: file.runs, now: t, auto: auto) { return reason }
            file.runs.append(.background(action, pr: pr, rule: rule, eventID: event?.id ?? "manual:\(t.ISO8601Format())", runID: runID, at: t))
            return nil
        }
        reload()
        if let refusal {
            BackgroundRunner.log.info("background run not started: \(refusal, privacy: .public)")
            record([ActivityEntry(background: title, stage: .refused, pr: pr, account: account.login, runID: nil, error: refusal, at: t)])
            if !auto { runFailed("\(title) didn't start", "\(pr.repo) #\(pr.number): \(refusal)", id: Automation.backgroundID) }
            return
        }
        pumpBackground()
    }

    /// Starts queued runs into free slots, and stops a running one the command line cancelled. After every queue change and
    /// on the clock (runs queued from the command line).
    func pumpBackground() {
        guard persist else { return }
        for (id, job) in backgroundJobs where automationFile.runs.last(where: { $0.runID == id })?.status == .cancelled { job.stop(.cancelled) }
        for runID in BackgroundQueue.next(automationFile.runs, running: backgroundJobs.count) { begin(runID) }
    }

    private func begin(_ runID: String) {
        guard backgroundJobs[runID] == nil, backgroundJobs.count < BackgroundSettings.maxRunning,
              let run = automationFile.runs.last(where: { $0.runID == runID }), run.status == .queued, let action = run.background else { return }
        let job = BackgroundJob(runID: runID)
        backgroundJobs[runID] = job
        let file = automationStore.load()
        let rule = run.automationID == Automation.backgroundID ? nil : file.automations.first { $0.id == run.automationID }
        guard let pr = tracked.prs[run.prID], let account = account(pr.accountID) else {
            return finishBackground(runID, outcome: .init(status: .failed, error: "The pull request is no longer tracked"))
        }
        automationStore.mutate { file in
            guard let i = file.runs.lastIndex(where: { $0.runID == runID }) else { return }
            (file.runs[i].status, file.runs[i].detail) = (.running, "Running")
        }
        reload()
        record([ActivityEntry(background: rule?.name ?? action.title, stage: .started, pr: pr, account: account.login, runID: runID, at: Date())])
        let input = BackgroundRunner.Input(runID: runID, action: action, pr: pr, login: account.login, token: Keychain.get(account.tokenService),
                                           file: file, rule: rule, index: index(file.repoFolders), runsDir: AgentLauncher.runsDir)
        Task {
            let outcome = await BackgroundRunner.run(input, job: job)
            finishBackground(runID, outcome: outcome)
        }
    }

    /// Records the result (a command-line cancel stays cancelled), logs it, shows the panel, starts the next.
    private func finishBackground(_ runID: String, outcome: BackgroundRunner.Outcome) {
        backgroundJobs[runID] = nil
        let saved = automationStore.mutate { file -> RunRecord? in
            guard let i = file.runs.lastIndex(where: { $0.runID == runID }) else { return nil }
            let status = file.runs[i].status == .cancelled ? .cancelled : outcome.status
            file.runs[i].status = status
            file.runs[i].ok = status == .done
            file.runs[i].detail = status == .done ? "\(outcome.draft?.action.result.capitalized ?? "Draft") ready" : outcome.error ?? status.word.capitalized
            file.runs[i].sessionID = outcome.sessionID
            file.runs[i].head = outcome.head ?? file.runs[i].head
            file.runs[i].draft = outcome.draft.flatMap { BackgroundDraft.url(runID: $0.runID, runsDir: AgentLauncher.runsDir)?.path }
            return file.runs[i]
        }
        reload()
        guard let saved, let action = saved.background, let pr = tracked.prs[saved.prID] else { return pumpBackground() }
        let login = account(pr.accountID)?.login ?? ""
        let title = String(saved.label.split(separator: " · ").first ?? Substring(action.title))
        record([ActivityEntry(background: title, stage: saved.ok ? .ready : .failed, pr: pr, account: login, runID: runID,
                              error: saved.ok ? nil : saved.detail, at: Date())])
        if settings.notificationsEnabled && !isPaused && saved.status != .cancelled { showBackground(saved, draft: outcome.draft, pr: pr, title: title) }
        pumpBackground()
    }

    /// The result's panel (an alert: it stays): a review draft (Review Draft…, Open Session, Discard), a summary (Open
    /// Session, Copy), or a failure. The agent's summary is shown as cleaned plain text.
    private func showBackground(_ run: RunRecord, draft: BackgroundDraft?, pr: TrackedPR, title: String) {
        guard let runID = run.runID else { return }
        let id = UUID(uuidString: runID) ?? Automation.backgroundID
        let place = "\(pr.repo) #\(pr.number) · \(PromptTemplate.clean(pr.title, max: 120))"
        let open = run.sessionID == nil ? [] : [PanelAction(id: id, title: "Open Session", run: { [weak self] in self?.openBackgroundSession(runID: runID) }, symbol: "terminal")]
        guard let draft else {
            return NotificationPanels.shared.show(note: "\(place)\n\(run.detail)", title: "\(title) failed", id: id, actions: open)
        }
        if draft.action == .summarize {
            let copy = PanelAction(id: id, title: "Copy", run: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(draft.body.isEmpty ? draft.summary : draft.body, forType: .string)
            }, symbol: "doc.on.doc")
            return NotificationPanels.shared.show(note: "\(place)\n\(draft.summary)", title: "Summary ready", id: id, actions: open + [copy])
        }
        NotificationPanels.shared.show(
            note: "\(place)\nSuggests: \(draft.verdict.phrase). \(draft.summary)", title: "Review draft ready", id: id,
            actions: [PanelAction(id: id, title: "Review Draft…", run: { [weak self] in self.map { DraftWindows.shared.show(store: $0, runID: runID) } }, symbol: "doc.text.magnifyingglass")]
                + open + [PanelAction(id: id, title: "Discard", run: { [weak self] in self?.discardDraft(runID) }, symbol: "trash")])
    }

    /// Cancel Background Review: a running run's process is stopped (its result records "cancelled"); a queued one never starts.
    func cancelBackground(_ runID: String) {
        if let job = backgroundJobs[runID] { return job.stop(.cancelled) }
        let cancelled = automationStore.mutate { file -> RunRecord? in
            guard let i = file.runs.lastIndex(where: { $0.runID == runID }), file.runs[i].status == .queued else { return nil }
            (file.runs[i].status, file.runs[i].ok, file.runs[i].detail) = (.cancelled, false, "Cancelled")
            return file.runs[i]
        }
        reload()
        if let cancelled, let pr = tracked.prs[cancelled.prID] {
            record([ActivityEntry(background: cancelled.background?.title ?? "", stage: .failed, pr: pr, account: account(pr.accountID)?.login ?? "",
                                  runID: runID, error: "Cancelled", at: Date())])
        }
    }

    /// At quit: running runs stop and stay interrupted (never restarted). TERM only: the app exits before the 5-second KILL,
    /// so an agent that ignores TERM keeps running without the 10-minute limit, as after a crash or a force quit.
    func interruptBackground() {
        for job in backgroundJobs.values { job.stop(.interrupted) }
        guard !backgroundJobs.isEmpty else { return }
        let ids = Set(backgroundJobs.keys)
        automationStore.mutate { file in
            for i in file.runs.indices where ids.contains(file.runs[i].runID ?? "") && file.runs[i].status == .running {
                (file.runs[i].status, file.runs[i].ok, file.runs[i].detail) = (.interrupted, false, "Interrupted: PullPing quit")
            }
        }
    }

    /// Deletes a draft (the panel's Discard, the draft window's); its run stays in Recent Runs.
    func discardDraft(_ runID: String) {
        let gone = draft(runID)
        automationStore.mutate { file in if let i = file.runs.lastIndex(where: { $0.runID == runID }) { file.runs[i].draft = nil } }
        if let url = BackgroundDraft.url(runID: runID, runsDir: AgentLauncher.runsDir) { try? FileManager.default.removeItem(at: url) }
        reload()
        if let gone {
            record([ActivityEntry(background: gone.action.title, stage: .discarded, pr: tracked.prs[gone.prID] ?? gone.pr, account: gone.login, runID: runID, at: Date())])
        }
        UUID(uuidString: runID).map { NotificationPanels.shared.dismiss(prID: "note:\($0)") }
        DraftWindows.shared.close(runID)
    }

    /// Open Session: the run's headless session, resumed in a terminal with the default Open With target and no prompt (an
    /// interactive session: the user's own permissions apply there). Recorded as a Handle with Agent run.
    func openBackgroundSession(runID: String) {
        let file = automationStore.load()
        guard let run = file.runs.last(where: { $0.runID == runID }), let session = run.sessionID, let pr = tracked.prs[run.prID],
              let account = account(pr.accountID) else {
            return runFailed("Open Session didn't run", "The session or its pull request is gone.", id: Automation.backgroundID)
        }
        guard file.enabled else { return runFailed("Open Session didn't run", "Turn on Run Automations in Settings → Automations.", id: Automation.backgroundID) }
        let draft = draft(runID)
        let rule = file.automations.first { $0.id == run.automationID }
        var a = file.handler
        a.agent = draft?.agent ?? (rule ?? file.handler).agent
        if a.agent != file.handler.agent { a.agentCommand = rule?.agent == a.agent ? rule?.agentCommand ?? "" : "" }
        a.sessionID = session
        a.workingDirectory = draft?.cwd ?? AgentLauncher.runsDir.appendingPathComponent(runID).path
        let t = Date()
        launch(a, pr: pr, login: account.login, event: nil, eventID: "manual:\(t.ISO8601Format())", key: "background|\(runID)", file: file, at: t, prompt: false)
    }

    /// Has PullPing posted as `login` before (the one-time question was answered)?
    func postConfirmed(_ login: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: DefaultsKey.postConfirmedLogins) ?? []).contains(login.lowercased())
    }

    private func confirmPosting(_ login: String) {
        guard persist, !postConfirmed(login) else { return }
        UserDefaults.standard.set((UserDefaults.standard.stringArray(forKey: DefaultsKey.postConfirmedLogins) ?? []) + [login.lowercased()],
                                  forKey: DefaultsKey.postConfirmedLogins)
    }

    /// The draft window's Post, the only path that writes to GitHub: one review with the account that tracks the pull request,
    /// the edited body and the chosen event, pinned to the draft's commit (`DraftPost.refusal`, checked again against a fresh
    /// head right before). nil = posted (the draft is used up); else why not, and the draft stays. `askedNow`: the user just
    /// answered the one-time "Post as @login?" question; it is remembered only once the post went through.
    func postDraft(_ draft: BackgroundDraft, body: String, event: DraftPost.Event, askedNow: Bool = false) async -> String? {
        guard persist else { return "Not in the demo." }
        guard draft.action == .review else { return "Only a review draft can be posted." }
        guard askedNow || postConfirmed(draft.login) else { return "PullPing has not posted as @\(draft.login) before: confirm it first." }
        let body = BackgroundPlanner.clean(body)  // what the window showed: draft.json may have been edited since
        guard let account = account(draft.accountID) else { return "@\(draft.login) is no longer an account in PullPing." }
        let pr = tracked.prs[draft.prID]
        if let reason = DraftPost.refusal(event, body: body, draftHead: draft.head, head: pr?.headOID ?? draft.head, open: (pr?.state ?? .open) == .open) {
            return reason
        }
        let client = GitHubClient(transport: URLSessionTransport(), token: Keychain.get(account.tokenService))
        do {
            let now = try await client.pullRequestHead(prID: draft.prID)
            if let reason = DraftPost.refusal(event, body: body, draftHead: draft.head, head: now.head, open: now.open) { return reason }
            _ = try await client.postReview(prID: draft.prID, commitOID: draft.head, event: event, body: body)
        } catch {
            return "GitHub didn't take it: \((error as? AccountStatus)?.word ?? error.localizedDescription)"
        }
        confirmPosting(draft.login)
        automationStore.mutate { file in
            guard let i = file.runs.lastIndex(where: { $0.runID == draft.runID }) else { return }
            (file.runs[i].draft, file.runs[i].detail) = (nil, "Posted: \(event.title) as @\(account.login)")
        }
        if let file = BackgroundDraft.url(runID: draft.runID, runsDir: AgentLauncher.runsDir) { try? FileManager.default.removeItem(at: file) }
        reload()
        record([ActivityEntry(background: "Review: \(event.title) as @\(account.login)", stage: .posted, pr: pr ?? draft.pr, account: account.login,
                              runID: draft.runID, at: Date())])
        BackgroundRunner.log.info("posted a review (\(event.rawValue, privacy: .public)) on \(draft.repo, privacy: .public) #\(draft.number)")
        UUID(uuidString: draft.runID).map { NotificationPanels.shared.dismiss(prID: "note:\($0)") }
        return nil
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
