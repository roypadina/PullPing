import AppKit
import PullPingCore
import SwiftUI

/// Activity's filters: everything, entries that asked something of me (a notify reason), my pull requests, reviews, runs.
enum ActivityFilter: String, CaseIterable {
    case all = "All", needsMe = "Needs Me", mine = "My PRs", reviews = "Reviews", runs = "Runs"
}

/// Main window › Activity: a read-only log of what PullPing saw and did, newest first, entries since the last visit under New,
/// the rest by day: every event (notified or not, and why), reminder and run of the sidebar scope. A row shows its pull request
/// in the detail column; double-click or Return opens it in the browser.
struct ActivityView: View {
    let store: Store
    @Binding var query: String
    /// An index into `store.activity`, which is oldest first, so new entries don't move it.
    @Binding var selection: Int?
    @State private var filter = ActivityFilter.all
    /// `store.activitySeenAt` when the feed opened: what counts as new while it stays open.
    @State private var seenAt: Date?

    /// New first, then by day, newest first; rows newest first. Rows carry their entry: compaction shifts `store.activity`
    /// while SwiftUI still renders old rows, so a row must never look its entry up by index (crash in 0.7.0 dev builds).
    private var days: [(title: String, rows: [(index: Int, entry: ActivityEntry)])] {
        let scope = store.listSelection.scope
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = store.activity.enumerated().reversed().filter { _, e in
            scope.matches(e) && matches(e) && (q.isEmpty || "\(e.repo) #\(e.number) \(e.title) \(e.actor ?? "") \(e.automation ?? "")".lowercased().contains(q))
        }.map { (index: $0.offset, entry: $0.element) }
        let seen = seenAt ?? store.activitySeenAt
        let new = rows.filter { $0.entry.at > seen }
        return (new.isEmpty ? [] : [("New", new)]) + Dictionary(grouping: rows.filter { $0.entry.at <= seen }) { Calendar.current.startOfDay(for: $0.entry.at) }
            .sorted { $0.key > $1.key }.map { (Self.title($0.key), $0.value) }
    }

    private func matches(_ e: ActivityEntry) -> Bool {
        let pr = e.prID.flatMap { store.tracked.prs[$0] }
        switch filter {
        case .all: return true
        case .needsMe: return e.need != nil
        case .mine: return pr?.roles.contains(.author) ?? false
        case .reviews: return [.toReview, .reReview, .teamToReview].contains(e.need) || pr.map { Filter.home($0) == .reviews } ?? false
        case .runs: return e.kind != .event
        }
    }

    var body: some View {
        let days = days
        List(selection: $selection) {
            ForEach(days, id: \.title) { day in
                Section(day.title) {
                    ForEach(day.rows, id: \.index) { row in
                        let entry = row.entry
                        ActivityEntryRow(entry: entry, account: store.multiAccount ? entry.accountID.flatMap(store.account)?.displayName ?? "@\(entry.account)" : nil)
                            .tag(row.index)
                    }
                }
            }
        }
        .safeAreaInset(edge: .top) {
            // Segments while the column is wide enough, else a menu (five segments clipped a 400 pt column).
            ViewThatFits(in: .horizontal) {
                filterPicker.pickerStyle(.segmented)
                filterPicker.pickerStyle(.menu).fixedSize()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .onChange(of: selection) { _, i in store.selectedID = i.flatMap(pr)?.id }
        .contextMenu(forSelectionType: Int.self) { rows in
            if !rows.isEmpty {
                Button("Open in Browser") { rows.forEach(open) }
                if rows.count == 1, let i = rows.first, store.activity.indices.contains(i), let id = store.activity[i].runID, store.draft(id) != nil {
                    Button("Review Draft…") { DraftWindows.shared.show(store: store, runID: id) }
                }
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(rows.sorted().compactMap { store.activity.indices.contains($0) ? store.activity[$0].url?.absoluteString : nil }
                        .joined(separator: "\n"), forType: .string)
                }
            }
        } primaryAction: { rows in
            rows.forEach(open)
        }
        .overlay {
            if days.isEmpty {
                if !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ContentUnavailableView("No Activity", systemImage: "clock.arrow.circlepath",
                                           description: Text("Every event PullPing sees appears here, notified or not, with every automation run. Kept for \(store.settings.activityDays) days."))
                }
            }
        }
        .searchable(text: $query, prompt: "Search activity")
        .task {
            selection = nil  // indices shift when the log is compacted
            seenAt = store.activitySeenAt
            store.compactActivity()
        }
        // Seen once left: another row, or the window in the background.
        .onDisappear { store.activitySeenAt = Date() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in store.activitySeenAt = Date() }
    }

    private var filterPicker: some View {
        Picker("Show", selection: $filter) {
            ForEach(ActivityFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden()
    }

    /// The row's pull request while PullPing still tracks it.
    private func pr(_ i: Int) -> TrackedPR? {
        guard store.activity.indices.contains(i) else { return nil }
        return store.activity[i].prID.flatMap { store.tracked.prs[$0] }
    }

    /// A tracked pull request as the list's Open in Browser (marks it read); one no longer tracked by its URL.
    private func open(_ i: Int) {
        if let pr = pr(i) { store.open(pr.id) } else if store.activity.indices.contains(i), let url = store.activity[i].url { NSWorkspace.shared.open(url) }
    }

    /// "Today", "Yesterday", "Friday, October 30".
    static func title(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
}

/// Kind icon, title and time; repo #n, who did what and the summary; chips for what PullPing did (no buttons: a log).
struct ActivityEntryRow: View {
    let entry: ActivityEntry
    /// Only with more than one account.
    let account: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(hue).frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.title).lineLimit(1).help(entry.title)
                    Spacer(minLength: 4)
                    Text(entry.at, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Text(verbatim: detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(entry.error ?? entry.summary ?? "")
                let chips = chips
                if !chips.isEmpty || account != nil || quiet != nil {
                    HStack(spacing: 4) {
                        ForEach(Array(chips.enumerated()), id: \.offset) { $0.element }
                        if let account { Chip(text: account, symbol: "person.crop.circle") }
                        if let quiet { Text(verbatim: quiet).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    /// Events: "octo-org/widgets #12 · alice approved · Looks good". Runs: the error, else the event that started it.
    private var detail: String {
        guard entry.prID != nil else { return entry.summary ?? "" }  // a setting the command line changed
        let ref = "\(entry.repo) #\(entry.number)"
        guard entry.kind == .event else { return (entry.error ?? entry.event?.label).map { "\(ref) · \($0)" } ?? ref }
        let actor = entry.actor ?? ""
        let line = entry.event.map { actor.isEmpty || actor == "CI" ? $0.verb : "\(actor) \($0.verb)" } ?? entry.what
        return ([ref, line] + (entry.summary.map { [$0] } ?? [])).joined(separator: " · ")
    }

    private var symbol: String {
        switch entry.kind {
        case .event: entry.event?.symbol ?? "bell"
        case .run: "play.circle"
        case .handler: "terminal"
        }
    }

    private var hue: Color {
        if entry.kind != .event { return entry.ok == false ? Theme.bad : entry.ok == nil ? Theme.needsYou : Theme.good }
        return entry.quiet == nil ? entry.event?.hue ?? Theme.neutral : Theme.neutral
    }

    /// Notified (a panel showed), Phone, and a run's outcome.
    private var chips: [Chip] {
        guard entry.kind == .event else {
            if entry.ok == false { return [Chip(text: entry.what, symbol: "xmark.octagon", tint: Theme.bad)] }
            return [entry.ok == nil ? Chip(text: entry.what, symbol: "questionmark.circle", tint: Theme.needsYou) : Chip(text: entry.what, symbol: "play.circle", tint: Theme.good)]
        }
        var chips: [Chip] = []
        if entry.quiet == nil && entry.panel != .notShown { chips.append(Chip(text: "Notified", symbol: "bell.badge", tint: Theme.needsYou)) }
        if entry.phone == true { chips.append(Chip(text: "Phone", symbol: "iphone")) }
        return chips
    }

    /// Why an event that asked something of me stayed quiet ("muted", "paused"…); nothing for what never notifies.
    private var quiet: String? {
        guard let quiet = entry.quiet, ![.own, .activityOnly, .styleOff].contains(quiet) else { return nil }
        return "Not shown: \(quiet.label)"
    }
}
