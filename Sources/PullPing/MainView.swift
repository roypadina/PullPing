import PullPingCore
import SwiftUI

struct MainView: View {
    @Bindable var store: Store
    @State private var query = ""
    @State private var activityRow: Int?

    var body: some View {
        let activity = store.listSelection.activity
        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } content: {
            Group {
                if activity {
                    ActivityView(store: store, query: $query, selection: $activityRow)
                } else {
                    PRListView(store: store, query: $query)
                }
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 560)
        } detail: {
            if let pr = store.selectedPR {
                PRDetailView(store: store, pr: pr)
            } else if activity, let i = activityRow, store.activity.indices.contains(i) {
                let entry = store.activity[i]
                ContentUnavailableView {
                    Label("Not Tracked", systemImage: "archivebox")
                } description: {
                    Text(verbatim: "PullPing no longer tracks \(entry.repo) #\(entry.number).")
                } actions: {
                    if let url = entry.url { Button("Open in Browser") { NSWorkspace.shared.open(url) } }
                }
            } else {
                ContentUnavailableView("No Selection", systemImage: "arrow.triangle.pull",
                                       description: Text("Select a pull request to see its reviewers, checks and activity."))
            }
        }
        .navigationTitle(activity ? "Activity" : "Pull Requests")
        .navigationSubtitle(store.freshness)
        .frame(minWidth: 900, minHeight: 520)
        .task(id: store.selectedID) {  // selected for ≥ 1 s = read
            guard let id = store.selectedID, let pr = store.selectedPR, Attention.unread(pr) > 0 else { return }
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { store.markRead([id]) }
        }
    }
}

/// Mail pattern: unified = All Accounts, then one collapsed section per account; per account = expanded account sections only.
/// Each row is a scope plus a filter, with the menu-bar count as its badge.
struct SidebarView: View {
    @Bindable var store: Store
    @State private var expanded: [UUID: Bool] = [:]

    var body: some View {
        let unified = store.settings.inboxLayout == .unified
        List(selection: Binding(get: { store.selection.map { _ in store.listSelection } }, set: { store.selection = $0 })) {
            if unified {
                Section("All Accounts") { rows(.all) }
            }
            ForEach(store.accounts) { account in
                Section(isExpanded: Binding(get: { expanded[account.id] ?? !unified }, set: { expanded[account.id] = $0 })) {
                    rows(.account(account.id))
                } header: {
                    header(account)
                }
            }
        }
    }

    /// Issues only while tracked; Muted & Hidden only when it holds something.
    @ViewBuilder private func rows(_ scope: Scope) -> some View {
        ForEach(Filter.allCases.filter { shown($0, scope) }, id: \.self) { filter in
            Label(filter.title, systemImage: filter.symbol)
                .badge(store.count(scope, filter))
                .tag(SidebarItem(scope: scope, filter: filter))
        }
        Label("Activity", systemImage: "clock.arrow.circlepath")
            .badge(store.hasNewActivity(scope) ? Text(verbatim: "●").accessibilityLabel("New activity") : nil)
            .tag(SidebarItem(scope: scope, filter: .needsMe, activity: true))
    }

    private func shown(_ filter: Filter, _ scope: Scope) -> Bool {
        switch filter {
        case .issues: store.settings.trackIssues
        case .mutedHidden: !store.prs(scope, .mutedHidden).isEmpty
        default: true
        }
    }

    private func header(_ account: Account) -> some View {
        HStack(spacing: 6) {
            Avatar(url: account.avatarURL)
            Text(verbatim: account.displayName)
            Spacer(minLength: 0)
            if let status = store.statuses[account.id], status.isError {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.bad)
                    .help(status.word).accessibilityLabel(status.word)
            } else if !account.enabled {
                Text("Off").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Account picture from GitHub; a person symbol until it loads (or offline).
struct Avatar: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().clipShape(Circle())
        } placeholder: {
            Image(systemName: "person.crop.circle").resizable().foregroundStyle(.secondary)
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

struct PRListView: View {
    @Bindable var store: Store
    @Binding var query: String
    /// Collapsed sections (Drafts) the user opened, by title.
    @State private var opened: Set<String> = []

    /// The selected row's sections; while searching, every row's items under their row's name.
    private var sections: [ListSection] {
        let item = store.listSelection
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return item.filter.sections(store.prs(item.scope, item.filter)) }
        let hits = store.prs.filter { pr in
            item.scope.matches(pr) && "\(pr.repo) #\(pr.number) \(pr.title) \(pr.authorLogin)".lowercased().contains(q)
        }
        let byRow = Dictionary(grouping: hits, by: Filter.home)
        return Filter.allCases.compactMap { row in byRow[row].map { ListSection(title: row.title, prs: $0) } }
    }

    var body: some View {
        let sections = sections
        let filter = store.listSelection.filter
        let ids = sections.flatMap(\.prs).map(\.id)
        List(selection: $store.selectedID) {
            ForEach(store.errorAccounts) { account in  // FLW-17: inline, with the fix one click away
                AccountErrorRow(account: account, status: store.statuses[account.id] ?? .ok)
            }
            ForEach(sections, id: \.title) { section in
                if section.title.isEmpty {
                    PRRows(store: store, prs: section.prs)
                } else if section.collapsed {
                    let open = opened.contains(section.title)
                    // This list style draws no disclosure for collapsible sections, so the header is the toggle.
                    Section(isExpanded: Binding(get: { open }, set: { _ in opened.formSymmetricDifference([section.title]) })) {
                        PRRows(store: store, prs: section.prs)
                    } header: {
                        Button { opened.formSymmetricDifference([section.title]) } label: {
                            Label("\(section.title) (\(section.prs.count))", systemImage: open ? "chevron.down" : "chevron.right")
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(open ? "Expanded" : "Collapsed")
                    }
                } else {
                    Section("\(section.title) (\(section.prs.count))") { PRRows(store: store, prs: section.prs) }
                }
            }
        }
        .onChange(of: ids, initial: true) { _, ids in  // the detail never shows a row the list doesn't
            if let id = store.selectedID, !ids.contains(id) { store.selectedID = nil }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            PRMenuItems(store: store, ids: ids)
        } primaryAction: { ids in
            ids.forEach(store.open)
        }
        .overlay {
            if ids.isEmpty {
                if !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    EmptyState(store: store, filter: filter, scope: store.listSelection.scope)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if store.offline {
                Label(store.freshness, systemImage: "wifi.slash")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(6).background(.bar)
            }
        }
        .searchable(text: $query, prompt: "Search all pull requests")
        .toolbar {
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { store.refresh() }
                    .help("Refresh now (⌘R)")
            }
        }
    }
}

/// "@login: token rejected" with a Fix button (status panel and main window).
struct AccountErrorRow: View {
    let account: Account
    let status: AccountStatus

    var body: some View {
        HStack {
            Label {
                Text(verbatim: "\(account.displayName): \(status.word)").lineLimit(2)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.bad)
            }
            Spacer(minLength: 4)
            Button("Fix in Settings…") { SettingsWindow.shared.show(tab: "Accounts") }
        }
        .font(.callout)
    }
}

/// Empty states (FLW-14): no accounts, first sync, nothing in this row.
struct EmptyState: View {
    let store: Store
    var filter: Filter = .needsMe
    var scope: Scope = .all

    var body: some View {
        if store.accounts.isEmpty {
            ContentUnavailableView {
                Label("No Accounts", systemImage: "person.crop.circle.badge.plus")
            } description: {
                Text("Add a GitHub account to start tracking pull requests.")
            } actions: {
                Button("Add Account…") { SettingsWindow.shared.show(tab: "Accounts") }
            }
        } else if let first = store.firstSync.first {
            ProgressView { Text(verbatim: "Syncing \(first.displayName)…") }
        } else if filter == .needsMe {
            let waiting = store.prs(scope, .myPRs).filter { [.waitingReview, .waitingCI, .waitingMerge].contains(Attention.bucket($0)) }.count
            ContentUnavailableView("Nothing Needs You", systemImage: "checkmark.circle",
                                   description: Text(waiting == 0 ? "Reviews to do and your pull requests to fix or merge appear here."
                                                     : "\(waiting) of your pull requests \(waiting == 1 ? "is" : "are") waiting on others."))
        } else {
            ContentUnavailableView("Nothing Here", systemImage: filter.symbol,
                                   description: Text("Nothing in \(filter.title) right now."))
        }
    }
}

/// List rows of one section.
struct PRRows: View {
    let store: Store
    let prs: [TrackedPR]

    var body: some View {
        ForEach(prs) { pr in
            PRRow(pr: pr, account: store.login(for: pr), now: store.now).tag(pr.id)
        }
    }
}

struct PRRow: View {
    let pr: TrackedPR
    /// "@login", only with more than one account.
    let account: String?
    let now: Date

    var body: some View {
        let unread = Attention.unread(pr) > 0
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(verbatim: "\(pr.repo) #\(pr.number)").foregroundStyle(.secondary).lineLimit(1)
                if let account { Chip(text: account, symbol: "person.crop.circle") }
                Spacer(minLength: 4)
                if unread {
                    Circle().fill(.tint).frame(width: 7, height: 7).accessibilityLabel("Unread")
                }
            }
            .font(.caption)
            Text(pr.title)
                .fontWeight(Attention.isAttention(pr) ? .semibold : .regular)
                .foregroundStyle(pr.muted ? .secondary : .primary)
                .lineLimit(1)
                .help(pr.title)
            HStack(spacing: 4) {
                ForEach(Array(pr.chips.enumerated()), id: \.offset) { $0.element }
                Spacer(minLength: 4)
                if let last = pr.events.last {
                    Text(verbatim: "\(last.line) · \(shortAge(last.at, now: now))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).layoutPriority(-1)
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// Row context menu (status panel and main window); the Pull Request menu mirrors it with shortcuts.
struct PRMenuItems: View {
    let store: Store
    let ids: Set<String>

    var body: some View {
        if !ids.isEmpty {
            let muted = ids.allSatisfy { store.tracked.prs[$0]?.muted == true }
            let hidden = ids.allSatisfy { store.tracked.prs[$0]?.hidden == true }
            Button("Open in Browser") { ids.forEach(store.open) }
            Button("Mark as Read") { store.markRead(ids) }
            Button(muted ? "Unmute" : "Mute") { store.setMuted(ids, !muted) }
            Button(hidden ? "Unhide" : "Hide") { store.setHidden(ids, !hidden) }
            Menu("Snooze") {
                ForEach(Snooze.allCases, id: \.self) { option in
                    Button(option.title) { store.snooze(ids, option) }
                }
            }
            if ids.count == 1, let pr = ids.first.flatMap({ store.tracked.prs[$0] }) {
                if store.agentMenuShown { Menu("Handle with Agent") { HandlerMenu(store: store, pr: pr) } }
                RunAutomationMenu(store: store, pr: pr)
            }
            Divider()
            Button("Stop Tracking") { store.stopTracking(ids) }
        }
    }
}

/// The rules that fit the pull request plus its hooks, run now (a manual run); the detail toolbar's (`compact`) also has
/// Handle with Agent ▸ first. Dimmed when there is nothing to run or Automations are off.
struct RunAutomationMenu: View {
    let store: Store
    let pr: TrackedPR
    /// Icon only: the detail toolbar.
    var compact = false

    var body: some View {
        let automations = store.automations(for: pr)
        let handler = compact && store.agentMenuShown
        Menu {
            if handler {
                Menu("Handle with Agent") { HandlerMenu(store: store, pr: pr) }
                if !automations.isEmpty { Divider() }
            }
            ForEach(automations) { automation in
                let blocked = store.runBlocked(automation, pr)
                Button(blocked.map { "\(automation.name) (\($0))" } ?? automation.name) { store.run(automation, prID: pr.id, event: nil) }
                    .disabled(blocked != nil)
            }
        } label: {
            if compact { Label("Run Automation", systemImage: "play.circle").labelStyle(.iconOnly) } else { Text("Run Automation") }
        }
        .help("Run Automation")
        .disabled((automations.isEmpty && !handler) || !store.automationsEnabled)
    }
}

/// Handle with Agent's choices for one pull request, a section per Open With target (`HandlerMenuModel`): the row's
/// Handle with Agent ▸ submenu, the detail toolbar and the Pull Request menu; `nsMenu` for the panel's chevron.
struct HandlerMenu: View {
    let store: Store
    let pr: TrackedPR

    var body: some View {
        ForEach(Array(store.handlerSections(pr).enumerated()), id: \.offset) { _, section in
            Section {
                ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                    Button(item.title) { store.perform(item.choice, prID: pr.id, event: nil) }
                        .help(Self.help(item, store: store, pr: pr))
                }
            } header: {
                if let title = section.title { Text(verbatim: title) }
            }
        }
    }

    /// A found session's title and folder on Resume Earlier Session.
    static func help(_ item: HandlerMenuItem, store: Store, pr: TrackedPR) -> String {
        guard case .resumeEarlier = item.choice, let found = store.foundSession(for: pr) else { return "" }
        return PRDetailView.help(found)
    }

    /// The same choices as an AppKit menu (a panel is never key, so a SwiftUI `Menu` doesn't open reliably there).
    static func nsMenu(store: Store, pr: TrackedPR, event: PREvent?, scenario: Scenario?) -> NSMenu {
        let menu = NSMenu()
        for (i, section) in store.handlerSections(pr).enumerated() {
            if i > 0 { menu.addItem(.separator()) }
            if let title = section.title { menu.addItem(.sectionHeader(title: title)) }
            for item in section.items {
                let entry = ClosureMenuItem(title: item.title) {
                    MainActor.assumeIsolated { store.perform(item.choice, prID: pr.id, event: event, scenario: scenario) }
                }
                entry.toolTip = help(item, store: store, pr: pr).isEmpty ? nil : help(item, store: store, pr: pr)
                menu.addItem(entry)
            }
        }
        return menu
    }
}

struct PRDetailView: View {
    let store: Store
    let pr: TrackedPR

    private var repoURL: URL { pr.url.deletingLastPathComponent().deletingLastPathComponent() }

    var body: some View {
        List {
            header
            if !pr.isIssue {  // reviewers and checks are pull request only
                Section("Reviewers") {
                    if pr.reviewers.isEmpty && pr.requestedTeams.isEmpty {
                        Text("No reviewers").foregroundStyle(.secondary)
                    }
                    ForEach(pr.reviewers, id: \.login) { reviewer in
                        let look = Self.review(reviewer)
                        // An older commit than the head: the review predates the latest push.
                        let on = reviewer.commitOID.flatMap { $0 == pr.headOID || reviewer.requested ? nil : " on \($0.prefix(7))" } ?? ""
                        LabeledContent { Chip(text: look.word + on, symbol: look.symbol, tint: look.tint) } label: { Text(verbatim: "@\(reviewer.login)") }
                    }
                    ForEach(pr.requestedTeams, id: \.self) { team in
                        LabeledContent { Chip(text: "Requested", symbol: "clock", tint: Theme.needsYou) } label: { Text(verbatim: "team/\(team)") }
                    }
                }
                Section("Checks") {
                    if pr.checks.isEmpty { Text("No checks").foregroundStyle(.secondary) }
                    ForEach(Array(pr.checks.enumerated()), id: \.offset) { _, check in
                        LabeledContent {
                            HStack {
                                Chip(text: Self.word(check.state), symbol: Self.symbol(check.state), tint: Self.tint(check.state))
                                if let url = check.url, ["http", "https"].contains(url.scheme?.lowercased()) { Link("Details", destination: url) }
                            }
                        } label: {
                            Text(check.name)
                        }
                    }
                }
            }
            let hooks = store.automations(for: pr).filter(\.isHook)
            if !hooks.isEmpty {
                Section("Agent Hooks") {
                    ForEach(hooks) { hook in
                        HStack {
                            Text(verbatim: AutomationsTab.line(hook)).lineLimit(2)
                            Spacer(minLength: 8)
                            Button("Remove") { store.removeAutomation(hook.id) }
                        }
                    }
                }
            }
            if let link = store.link(for: pr) {
                Section("Agent Session") {
                    HStack {
                        Text(verbatim: AutomationsTab.line(link, now: store.now, pr: false)).lineLimit(2)
                        Spacer(minLength: 8)
                        Button("Remove") { store.removeLink(link) }
                    }
                }
            } else if store.handlerShown, store.automationFile.findSessions, let found = store.foundSession(for: pr) {
                Section("Agent Session") {
                    HStack {
                        Text(verbatim: "Earlier session: \(found.agent.rawValue) \(found.sessionID.prefix(8))…, \(relativeAge(found.modifiedAt, now: store.now))")
                            .lineLimit(2).help(Self.help(found))
                        Spacer(minLength: 8)
                        Button("Resume") { store.resumeFound(found, prID: pr.id, event: nil) }
                    }
                }
            }
            // A panel can be dismissed: the latest background run and its draft stay reachable here (7 days).
            if let run = store.backgroundRun(for: pr), store.now.timeIntervalSince(run.at) < 7 * 86_400 {
                Section("Agent Draft") { AgentDraftRow(store: store, run: run) }
            }
            Section("Activity") {
                if pr.events.isEmpty { Text("No activity yet").foregroundStyle(.secondary) }
                ForEach(pr.events.reversed(), id: \.id) { event in
                    ActivityRow(event: event, now: store.now)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Open in Browser", systemImage: "safari") { store.open(pr.id) }
                    .help("Open in browser (⇧⌘O)")
                Button("Mark as Read", systemImage: "envelope.open") { store.markRead([pr.id]) }
                    .help("Mark as read (⇧⌘U)")
                RunAutomationMenu(store: store, pr: pr, compact: true)
            }
        }
        .task(id: pr.id) { if store.handlerShown { store.findSession(prID: pr.id) } }  // no link + Look for earlier sessions: the toolbar menu may offer it
    }

    /// A found session's tooltip: its title, where it started, whether it may be open.
    static func help(_ found: SessionCandidate) -> String {
        ([found.title.isEmpty ? nil : "\u{201C}\(found.title)\u{201D}", "Launched in \((found.launchDir as NSString).abbreviatingWithTildeInPath)",
          "Found by \(found.tier)", found.mayBeOpen ? "May be open in another terminal" : nil] as [String?]).compactMap { $0 }.joined(separator: " · ")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Link(pr.repo, destination: repoURL)
                Text(verbatim: "#\(pr.number)").foregroundStyle(.secondary)
            }
            Text(pr.title).font(.title2.bold()).textSelection(.enabled)
            Text(verbatim: "by @\(pr.authorLogin)").foregroundStyle(.secondary)
            if let reason = Attention.needReason(pr, counting: store.settings.badgeReasons) {
                Label("Your turn: \(reason.panelTitle)", systemImage: "hand.point.right").foregroundStyle(Theme.needsYou)
            }
            HStack(spacing: 4) {
                ForEach(Array(pr.chips.enumerated()), id: \.offset) { $0.element }
                // My pull requests' status chip already says conflicts, behind or ready.
                if pr.state == .open, !pr.roles.contains(.author), let merge = Self.mergeWord(pr.mergeState) {
                    Chip(text: merge.word, symbol: merge.symbol, tint: merge.tint)
                }
            }
            // Actions sit with the header, not on the window's bottom edge (LAY-6).
            HStack {
                Button("Open in Browser") { store.open(pr.id) }.buttonStyle(.borderedProminent)
                Button("Mark as Read") { store.markRead([pr.id]) }
                Button(pr.muted ? "Unmute" : "Mute") { store.setMuted([pr.id], !pr.muted) }
                Button(pr.hidden ? "Unhide" : "Hide") { store.setHidden([pr.id], !pr.hidden) }
                Button("Stop Tracking") { store.stopTracking([pr.id]) }
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 6)
    }

    static func review(_ r: ReviewSummary) -> (word: String, symbol: String, tint: Color) {
        if r.requested { return ("Requested", "clock", Theme.needsYou) }
        switch r.state {
        case "APPROVED": return ("Approved", "checkmark.circle", Theme.good)
        case "CHANGES_REQUESTED": return ("Changes requested", "exclamationmark.bubble", Theme.bad)
        case "DISMISSED": return ("Dismissed", "hand.raised.slash", Theme.neutral)
        default: return ("Commented", "text.bubble", Theme.neutral)
        }
    }

    static func word(_ state: CIState) -> String {
        switch state {
        case .success: "Passed"
        case .failure: "Failed"
        case .pending: "Running"
        case .none: "No status"
        }
    }

    static func symbol(_ state: CIState) -> String {
        switch state {
        case .success: "checkmark.circle"
        case .failure: "xmark.circle"
        case .pending: "circle.dotted"
        case .none: "minus.circle"
        }
    }

    static func tint(_ state: CIState) -> Color {
        switch state {
        case .success: Theme.good
        case .failure: Theme.bad
        case .pending: Theme.needsYou
        case .none: Theme.neutral
        }
    }

    /// GitHub `mergeStateStatus` → a word; UNKNOWN, HAS_HOOKS and DRAFT stay hidden.
    static func mergeWord(_ state: String) -> (word: String, symbol: String, tint: Color)? {
        switch state {
        case "CLEAN": ("Ready to merge", "checkmark.circle", Theme.good)
        case "BLOCKED": ("Blocked", "lock", Theme.neutral)
        case "BEHIND": ("Behind base", "arrow.down.circle", Theme.neutral)
        case "DIRTY": ("Conflicts", "exclamationmark.triangle", Theme.bad)
        case "UNSTABLE": ("Unstable", "exclamationmark.circle", Theme.needsYou)
        default: nil
        }
    }
}

struct ActivityRow: View {
    let event: PREvent
    let now: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: event.kind.symbol).foregroundStyle(event.isOwn ? Theme.neutral : event.kind.hue).frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.line)
                if !event.summary.isEmpty {
                    Text(event.summary).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .foregroundStyle(event.isOwn ? .secondary : .primary)  // own events dimmed
            Spacer(minLength: 8)
            Text(shortAge(event.at, now: now)).foregroundStyle(.secondary).monospacedDigit()
            if let url = event.url { Link("View", destination: url) }
        }
        .accessibilityElement(children: .combine)
    }
}
