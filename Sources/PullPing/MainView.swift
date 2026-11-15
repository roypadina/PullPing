import PullPingCore
import SwiftUI

struct MainView: View {
    @Bindable var store: Store
    @State private var query = ""
    @State private var activityRow: Int?

    var body: some View {
        let activity = store.listSelection.activity
        let repo = store.activeRepo(store.repoFilter, store.listSelection.scope)
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
            // The Repository choice (TBR-2), for the lists and Activity alike: a view filter that always shows itself (PRN-2).
            .safeAreaInset(edge: .top, spacing: 0) {
                if let repo { RepoFilterBar(repo: repo) { store.repoFilter = "" } }
            }
            .toolbar {
                ToolbarItem {
                    Menu {
                        RepoFilterPicker(store: store)
                    } label: {
                        Label("Repository", systemImage: repo == nil ? "book.closed" : "book.closed.fill")
                    }
                    .help(repo.map { "Showing only \($0)" } ?? "Show one repository")
                    .accessibilityValue(repo ?? "All Repositories")
                }
            }
        } detail: {
            if !activity && store.selectedIDs.count > 1 {
                SelectionSummaryView(store: store, ids: store.selectedIDs)
            } else if let pr = store.selectedPR {
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
        .task(id: store.selectedID) {  // one row selected for Settings › General › Mark as read when selected = read
            let delay = store.settings.markReadSeconds
            guard delay >= 0, let id = store.selectedID, let pr = store.selectedPR, Attention.unread(pr) > 0 else { return }
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            if !Task.isCancelled { store.markRead([id]) }
        }
        .onChange(of: activity) { _, activity in  // the menus must never act on rows out of sight
            if activity && store.selectedIDs.count > 1 { store.selectedIDs = []; activityRow = nil }
        }
        .sheet(isPresented: Binding(get: { store.remindIDs != nil }, set: { if !$0 { store.remindIDs = nil } })) {
            if let ids = store.remindIDs { RemindSheet(store: store, ids: ids) }
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
                Section("All Accounts") { rows(.all, store.signals(.all)) }
            }
            ForEach(store.accounts) { account in
                let map = store.signals(.account(account.id)), open = expanded[account.id] ?? !unified
                Section(isExpanded: Binding(get: { open }, set: { expanded[account.id] = $0 })) {
                    rows(.account(account.id), map)
                } header: {
                    // Collapsed: the header carries the account's dot (expanded rows show their own).
                    header(account, new: !open && map.values.contains { $0.new > 0 })
                }
            }
        }
    }

    /// Issues only while tracked; Muted & Hidden only when it holds something.
    /// Number = need you (system badge), dot = new (`Filter.signal`).
    @ViewBuilder private func rows(_ scope: Scope, _ map: [Bucket: Signal]) -> some View {
        ForEach(Filter.allCases.filter { shown($0, scope) }, id: \.self) { filter in
            let signal = filter.signal(map)
            Label {
                HStack(spacing: 5) {
                    Text(filter.title)
                    if signal.new > 0 { NewDot() }
                }
            } icon: {
                Image(systemName: filter.symbol)
            }
            .badge(signal.needs)
            .accessibilityLabel(signal.spoken.isEmpty ? filter.title : "\(filter.title), \(signal.spoken)")
            .tag(SidebarItem(scope: scope, filter: filter))
        }
        let newActivity = store.hasNewActivity(scope)
        Label {
            HStack(spacing: 5) {  // the rows' dot, not a badge: one look for "new" in the sidebar
                Text("Activity")
                if newActivity { NewDot() }
            }
        } icon: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .accessibilityLabel(newActivity ? "Activity, new activity" : "Activity")
        .tag(SidebarItem(scope: scope, filter: .needsMe, activity: true))
    }

    private func shown(_ filter: Filter, _ scope: Scope) -> Bool {
        switch filter {
        case .issues: store.settings.trackIssues
        case .mutedHidden: !store.prs(scope, .mutedHidden).isEmpty
        default: true
        }
    }

    private func header(_ account: Account, new: Bool) -> some View {
        HStack(spacing: 6) {
            Avatar(url: account.avatarURL)
            Text(verbatim: account.displayName)
            if new { NewDot() }
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
    /// The ids last shown and their sidebar row (nil while searching): Needs Me keeps a selected row in place.
    @State private var shown = Shown()

    private struct Shown: Equatable {
        var item: SidebarItem?, ids: [String] = []
    }

    /// The selected row's sections; while searching, every row's items under their row's name.
    private var sections: [ListSection] {
        let item = store.listSelection
        let repo = store.activeRepo(store.repoFilter, item.scope)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty && item.filter == .needsMe && shown.item == item {
            // Reading an item (a mention, a comment, a reminder) can end its reason: the selected row stays, in place, until
            // the selection moves on (Mail's Unread filter), so it doesn't vanish under the cursor.
            // Only rows that would still need me if unread: one whose reason ended on GitHub (approved, merged) goes.
            let kept = store.selectedIDs.compactMap { store.tracked.prs[$0] }.filter { pr in
                var unread = pr
                unread.lastReadAt = nil
                return shown.ids.contains(pr.id) && item.scope.matches(pr) && RepoFilter.matches(pr.repo, repo)
                    && item.filter.matches(unread, counting: store.settings.badgeReasons)
            }
            let shownOrder = item.filter.sections(store.prs(item.scope, item.filter, repo: repo)).flatMap(\.prs)
            return item.filter.sections(Attention.keeping(shownOrder, kept, order: shown.ids))
        }
        guard !q.isEmpty else { return item.filter.sections(store.prs(item.scope, item.filter, repo: repo)) }
        let hits = store.prs.filter { pr in
            item.scope.matches(pr) && RepoFilter.matches(pr.repo, repo) && "\(pr.repo) #\(pr.number) \(pr.title) \(pr.authorLogin)".lowercased().contains(q)
        }
        let byRow = Dictionary(grouping: hits, by: Filter.home)
        return Filter.allCases.compactMap { row in byRow[row].map { ListSection(title: row.title, prs: $0) } }
    }

    var body: some View {
        let sections = sections
        let filter = store.listSelection.filter
        let ids = sections.flatMap(\.prs).map(\.id)
        // Keyed on the row and search state too: switching rows (or clearing a search) with the same ids must refresh `shown`.
        let key = Shown(item: query.trimmingCharacters(in: .whitespaces).isEmpty ? store.listSelection : nil, ids: ids)
        List(selection: $store.selectedIDs) {
            ForEach(store.errorAccounts) { account in  // FLW-17: inline, with the fix one click away
                AccountErrorRow(account: account, status: store.statuses[account.id] ?? .ok)
            }
            ForEach(sections, id: \.title) { section in
                if section.title.isEmpty {
                    PRRows(store: store, prs: section.prs, scope: store.listSelection.scope)
                } else if section.collapsed {
                    let open = opened.contains(section.title)
                    // This list style draws no disclosure for collapsible sections, so the header is the toggle.
                    Section(isExpanded: Binding(get: { open }, set: { _ in opened.formSymmetricDifference([section.title]) })) {
                        PRRows(store: store, prs: section.prs, scope: store.listSelection.scope)
                    } header: {
                        CollapsedHeader(section: section, open: open, now: store.now) { opened.formSymmetricDifference([section.title]) }
                    }
                } else {
                    Section("\(section.title) (\(section.prs.count))") { PRRows(store: store, prs: section.prs, scope: store.listSelection.scope) }
                }
            }
        }
        .onChange(of: key, initial: true) { _, key in  // the detail and the menus never act on a row the list doesn't show
            shown = key
            let visible = store.selectedIDs.intersection(key.ids)
            if visible != store.selectedIDs { store.selectedIDs = visible }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            PRMenuItems(store: store, ids: ids)
        } primaryAction: { ids in
            store.open(ids)
        }
        .prKeys(store: store, ids: store.selectedIDs)
        .overlay {
            if ids.isEmpty {
                let scope = store.listSelection.scope, all = store.prs(scope, filter).count
                if !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else if let repo = store.activeRepo(store.repoFilter, scope), all > 0 {
                    RepoEmptyState(repo: repo, row: filter.title, hidden: all) { store.repoFilter = "" }
                } else {
                    EmptyState(store: store, filter: filter, scope: scope)
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

/// A collapsible section's header (Drafts, Waiting on Others, Reviewed) in the window and the status panel: the list styles draw
/// no disclosure (or only on hover), so the header is the toggle. A dot while closed and something in it is new.
struct CollapsedHeader: View {
    let section: ListSection
    let open: Bool
    let now: Date
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Label {
                HStack(spacing: 5) {
                    Text("\(section.title) (\(section.prs.count))")
                    if !open && section.prs.contains(where: { Attention.isNew($0, now: now) }) { NewDot() }
                }
            } icon: {
                Image(systemName: open ? "chevron.down" : "chevron.right")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(open ? "Expanded" : "Collapsed")
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
                                   description: Text(filter == .issues ? "Open issues you are part of, and issues in repositories you track, appear here."
                                                     : "Nothing in \(filter.title) right now."))
        }
    }
}

/// The main window's Repository choice (toolbar and View ▸ Repository): All Repositories, then each repository of the
/// sidebar row's accounts (every tracked item: closed, muted and hidden ones too).
struct RepoFilterPicker: View {
    let store: Store

    var body: some View {
        let scope = store.listSelection.scope
        Picker("Repository", selection: Binding(get: { store.activeRepo(store.repoFilter, scope) ?? "" }, set: { store.repoFilter = $0 })) {
            Text("All Repositories").tag("")
            ForEach(store.repos(scope), id: \.self) { Text(verbatim: $0).tag($0) }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}

/// Above the window's list while a repository is chosen: what it shows and the way back, styled like the offline bar.
struct RepoFilterBar: View {
    let repo: String
    let clear: () -> Void

    var body: some View {
        HStack {
            Label { Text(verbatim: "Showing \(repo) only") } icon: { Image(systemName: "book.closed.fill") }
                .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button("Show All", action: clear).buttonStyle(.link)
        }
        .font(.callout).padding(6).background(.bar)
    }
}

/// A list empty only because of the Repository choice (FLW-14), in the window and the panel: how much the other
/// repositories hold, and the way back.
struct RepoEmptyState: View {
    let repo: String
    /// The sidebar row's or the panel filter's title.
    let row: String
    /// What the list holds without the choice.
    let hidden: Int
    let clear: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label { Text(verbatim: "Nothing in \(repo)") } icon: { Image(systemName: "book.closed") }
        } description: {
            Text(verbatim: "\(row) has \(hidden) \(hidden == 1 ? "item" : "items") in other repositories.")
        } actions: {
            Button("Show All Repositories", action: clear)
        }
    }
}

/// List rows of one section.
struct PRRows: View {
    let store: Store
    let prs: [TrackedPR]
    /// One account's list: no account chip on every row.
    var scope: Scope = .all

    var body: some View {
        ForEach(prs) { pr in
            PRRow(pr: pr, account: scope == .all ? store.login(for: pr) : nil, now: store.now).tag(pr.id)
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
                if unread { NewDot() }
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
            let muted = store.all(ids, \.muted), hidden = store.all(ids, \.hidden)
            Button("Open in Browser") { store.open(ids) }
            Button(store.readTitle(ids)) { store.toggleRead(ids) }
            RemindMenu(store: store, ids: ids)
            Button(muted ? "Unmute" : "Mute") { store.setMuted(ids, !muted) }
            Button(store.repoMuteTitle(ids)) { store.toggleReposMuted(ids) }
            Button(hidden ? "Unhide" : "Hide") { store.setHidden(ids, !hidden) }
            Menu("Snooze Notifications") {
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

/// Remind Me ▸ for the selection: at the time the item becomes new and needs you again, with an Alert panel. Not Snooze
/// (stay quiet until then). Row menus, the detail ⋯ menu, the summary's More menu and the Pull Request menu (`menuBar`).
struct RemindMenu: View {
    let store: Store
    let ids: Set<String>
    /// The Pull Request menu: Custom… shows ⌃⌘R and Clear Reminder dims when none is set (MNU-8); row menus hide it (MNU-12).
    var menuBar = false

    var body: some View {
        let set = ids.compactMap { store.tracked.prs[$0]?.remindAt }
        Menu("Remind Me") {
            if ids.count == 1, let at = set.first {
                Button("Set for \(Remind.label(at, now: store.now))") {}.disabled(true)
                Divider()
            }
            ForEach(Remind.Option.allCases, id: \.self) { option in
                Button(option.title) { store.setReminder(ids, option.date(from: Date())) }
            }
            Divider()
            // Mirrored in Settings › Shortcuts (`ShortcutsTab`).
            Button("Custom…") { store.askReminder(ids) }
                .keyboardShortcut(menuBar ? KeyboardShortcut("r", modifiers: [.command, .control]) : nil)
            if menuBar || !set.isEmpty {
                Divider()
                Button("Clear Reminder") { store.setReminder(ids, nil) }.disabled(set.isEmpty)
            }
        }
        .disabled(ids.isEmpty)
    }
}

/// Remind Me ▸ Custom… (and R, ⌃⌘R): one date for the items. R then Return = tomorrow 9:00.
struct RemindSheet: View {
    let store: Store
    let ids: Set<String>
    @State private var date: Date
    @Environment(\.dismiss) private var dismiss

    init(store: Store, ids: Set<String>) {
        self.store = store
        self.ids = ids
        let current = ids.count == 1 ? ids.first.flatMap { store.tracked.prs[$0]?.remindAt } : nil
        _date = State(initialValue: max(current ?? Remind.Option.tomorrow.date(from: Date()), Date()))
    }

    var body: some View {
        let prs = ids.compactMap { store.tracked.prs[$0] }
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: prs.count == 1 ? "Remind me about \u{201C}\(prs[0].title)\u{201D}" : "Remind me about \(prs.count) items")
                .font(.headline).lineLimit(2)
            DatePicker("Remind me", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
            HStack {
                if prs.contains(where: { $0.remindAt != nil }) {
                    Button("Clear Reminder") { store.setReminder(ids, nil); dismiss() }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Set Reminder") { store.setReminder(ids, date); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// The detail pane with 2+ selected (Mail's "N messages selected"): what they need, and actions for all of them.
struct SelectionSummaryView: View {
    let store: Store
    let ids: Set<String>

    var body: some View {
        let breakdown = Attention.breakdown(ids.compactMap { store.tracked.prs[$0] }, counting: store.settings.badgeReasons)
        let read = store.readTitle(ids), unread = store.anyUnread(ids)
        ContentUnavailableView {
            Label("\(ids.count) Items Selected", systemImage: "square.stack")
        } description: {
            if !breakdown.isEmpty { Text(breakdown) }
        } actions: {
            HStack {
                Button(read) { store.toggleRead(ids) }
                Button("Open in Browser") { store.open(ids) }
                Menu {
                    PRMenuItems(store: store, ids: ids)
                } label: {
                    Label("More", systemImage: "ellipsis").labelStyle(.iconOnly)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More: Remind Me, Mute, Hide, Snooze, Stop Tracking")
                .accessibilityLabel("More")
            }
        }
        .toolbar {  // the single detail's two buttons: the toolbar keeps its shape between 1 and N (TBR-2)
            ToolbarItemGroup {
                Button("Open in Browser", systemImage: "safari") { store.open(ids) }
                    .help("Open in browser (⇧⌘O)")
                Button(read, systemImage: unread ? "envelope.open" : "envelope.badge") { store.toggleRead(ids) }
                    .help(unread ? "Mark as read (⇧⌘U)" : "Mark as unread (⇧⌘U)")
            }
        }
    }
}

extension View {
    /// Single keys on a focused pull request list (Settings › Shortcuts): O open, U read/unread, M mute, H hide, R Remind Me.
    /// Only while the list has focus, so the search field keeps its keys (KBD-6); off with the setting (WCAG 2.1.4).
    func prKeys(store: Store, ids: Set<String>) -> some View {
        onKeyPress(characters: .letters, phases: .down) { press in
            guard store.settings.singleKeyShortcuts, !ids.isEmpty, press.modifiers.isDisjoint(with: [.command, .option, .control]) else {
                return .ignored
            }
            // An ASCII letter as typed (Dvorak keeps its letters). Else the key's Latin letter on Hebrew and other non-Latin
            // layouts: ⌘ switches a layout to its Latin keys (`characters(byApplyingModifiers:)` raises on a non-key event).
            var key = press.characters.lowercased()
            if !key.allSatisfy({ $0.isASCII && $0.isLetter }), let event = NSApp.currentEvent, event.type == .keyDown,
               let latin = event.characters(byApplyingModifiers: .command) {
                key = latin.lowercased()
            }
            let done: String
            switch key {
            case "o": store.open(ids); return .handled
            case "r": store.askReminder(ids); return .handled
            case "u":
                done = store.anyUnread(ids) ? "Marked as read" : "Marked as unread"
                store.toggleRead(ids)
            case "m":
                let muted = store.all(ids, \.muted)
                store.setMuted(ids, !muted)
                done = muted ? "Unmuted" : "Muted"
            case "h":
                let hidden = store.all(ids, \.hidden)
                store.setHidden(ids, !hidden)
                done = hidden ? "Unhidden" : "Hidden"
            default: return .ignored
            }
            AccessibilityNotification.Announcement(done).post()  // focus doesn't move, so say what changed (A11Y-6)
            return .handled
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
                let unread = Attention.unread(pr) > 0
                Button("Open in Browser", systemImage: "safari") { store.open(pr.id) }
                    .help("Open in browser (⇧⌘O)")
                Button(store.readTitle([pr.id]), systemImage: unread ? "envelope.open" : "envelope.badge") { store.toggleRead([pr.id]) }
                    .help(unread ? "Mark as read (⇧⌘U)" : "Mark as unread (⇧⌘U)")
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
            // The two main actions as buttons, the rest in More: five buttons truncated in a narrow detail column (PRN-4).
            HStack {
                Button("Open in Browser") { store.open(pr.id) }.buttonStyle(.borderedProminent)
                Button(store.readTitle([pr.id])) { store.toggleRead([pr.id]) }
                Menu {
                    RemindMenu(store: store, ids: [pr.id])
                    Button(pr.muted ? "Unmute" : "Mute") { store.setMuted([pr.id], !pr.muted) }
                    Button(store.repoMuteTitle([pr.id])) { store.toggleReposMuted([pr.id]) }
                    Button(pr.hidden ? "Unhide" : "Hide") { store.setHidden([pr.id], !pr.hidden) }
                    Menu("Snooze Notifications") {
                        ForEach(Snooze.allCases, id: \.self) { option in Button(option.title) { store.snooze([pr.id], option) } }
                    }
                    Divider()
                    Button("Stop Tracking") { store.stopTracking([pr.id]) }
                } label: {
                    Label("More", systemImage: "ellipsis").labelStyle(.iconOnly)
                }
                .menuStyle(.button)  // bordered like its neighbours
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More: Remind Me, Mute, Hide, Snooze, Stop Tracking")
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
