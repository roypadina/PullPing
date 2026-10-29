import PullPingCore
import SwiftUI

struct MainView: View {
    @Bindable var store: Store
    @State private var query = ""

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } content: {
            PRListView(store: store, query: $query)
                .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 560)
        } detail: {
            if let pr = store.selectedPR {
                PRDetailView(store: store, pr: pr)
            } else {
                ContentUnavailableView("No Selection", systemImage: "arrow.triangle.pull",
                                       description: Text("Select a pull request to see its reviewers, checks and activity."))
            }
        }
        .navigationTitle("Pull Requests")
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

    private func rows(_ scope: Scope) -> some View {
        ForEach(Filter.allCases, id: \.self) { filter in
            Label(filter.title, systemImage: filter.symbol)
                .badge(store.count(scope, filter))
                .tag(SidebarItem(scope: scope, filter: filter))
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

    private var rows: [TrackedPR] {
        let item = store.listSelection
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return store.prs(item.scope, item.filter).filter { pr in
            q.isEmpty || "\(pr.repo) #\(pr.number) \(pr.title) \(pr.authorLogin)".lowercased().contains(q)
        }
    }

    var body: some View {
        let rows = rows
        let filter = store.listSelection.filter
        List(selection: $store.selectedID) {
            ForEach(store.errorAccounts) { account in  // FLW-17: inline, with the fix one click away
                AccountErrorRow(account: account, status: store.statuses[account.id] ?? .ok)
            }
            PRRows(store: store, prs: rows, sectioned: filter == .inbox)
        }
        .onChange(of: rows.map(\.id), initial: true) { _, ids in  // the detail never shows a row the list doesn't
            if let id = store.selectedID, !ids.contains(id) { store.selectedID = nil }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            PRMenuItems(store: store, ids: ids)
        } primaryAction: { ids in
            ids.forEach(store.open)
        }
        .overlay {
            if rows.isEmpty {
                if !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    EmptyState(store: store, filter: filter)
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
        .searchable(text: $query, prompt: "Search pull requests")
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

/// Empty states (FLW-14): no accounts, first sync, nothing tracked.
struct EmptyState: View {
    let store: Store
    var filter: Filter = .all

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
        } else if filter == .all || filter == .inbox {
            ContentUnavailableView("No Pull Requests", systemImage: "arrow.triangle.pull",
                                   description: Text("Pull requests you open, review or comment on appear here."))
        } else {
            ContentUnavailableView("No Pull Requests", systemImage: filter.symbol,
                                   description: Text("Nothing in \(filter.title) right now."))
        }
    }
}

/// List rows; `sectioned` groups them Mine · To Review · Involved (the Inbox filter).
struct PRRows: View {
    let store: Store
    let prs: [TrackedPR]
    let sectioned: Bool

    var body: some View {
        if sectioned {
            ForEach(PRGroup.allCases, id: \.self) { group in
                let rows = prs.filter { Attention.group($0) == group }
                if !rows.isEmpty {
                    Section(group.title) { rowViews(rows) }
                }
            }
        } else {
            rowViews(prs)
        }
    }

    private func rowViews(_ prs: [TrackedPR]) -> some View {
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
            Divider()
            Button("Stop Tracking") { store.stopTracking(ids) }
        }
    }
}

struct PRDetailView: View {
    let store: Store
    let pr: TrackedPR

    private var repoURL: URL { pr.url.deletingLastPathComponent().deletingLastPathComponent() }

    var body: some View {
        List {
            header
            Section("Reviewers") {
                if pr.reviewers.isEmpty && pr.requestedTeams.isEmpty {
                    Text("No reviewers").foregroundStyle(.secondary)
                }
                ForEach(pr.reviewers, id: \.login) { reviewer in
                    let look = Self.review(reviewer)
                    LabeledContent { Chip(text: look.word, symbol: look.symbol, tint: look.tint) } label: { Text(verbatim: "@\(reviewer.login)") }
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
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Link(pr.repo, destination: repoURL)
                Text(verbatim: "#\(pr.number)").foregroundStyle(.secondary)
            }
            Text(pr.title).font(.title2.bold()).textSelection(.enabled)
            Text(verbatim: "by @\(pr.authorLogin)").foregroundStyle(.secondary)
            HStack(spacing: 4) {
                if pr.state == .open && !pr.isDraft { Chip(text: "Open", symbol: "circle.circle", tint: Theme.good) }
                ForEach(Array(pr.chips.enumerated()), id: \.offset) { $0.element }
                if pr.state == .open, let merge = Self.mergeWord(pr.mergeState) {
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
