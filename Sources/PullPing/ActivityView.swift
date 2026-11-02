import AppKit
import PullPingCore
import SwiftUI

/// Main window › Activity: what PullPing saw and did, newest first by day: every event (shown or not, and why), reminder and
/// run of the sidebar scope. A row shows its pull request in the detail column; double-click or Return opens it in the browser.
struct ActivityView: View {
    let store: Store
    @Binding var query: String
    /// An index into `store.activity`, which is oldest first, so new entries don't move it.
    @Binding var selection: Int?

    /// Newest day first; rows newest first.
    private var days: [(day: Date, rows: [Int])] {
        let scope = store.listSelection.scope
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = store.activity.indices.reversed().filter { i in
            let e = store.activity[i]
            return scope.matches(e) && (q.isEmpty || "\(e.repo) #\(e.number) \(e.title) \(e.actor ?? "") \(e.automation ?? "")".lowercased().contains(q))
        }
        return Dictionary(grouping: rows) { Calendar.current.startOfDay(for: store.activity[$0].at) }
            .sorted { $0.key > $1.key }.map { ($0.key, $0.value) }
    }

    var body: some View {
        let days = days
        List(selection: $selection) {
            ForEach(days, id: \.day) { day in
                Section(Self.title(day.day)) {
                    ForEach(day.rows, id: \.self) { i in
                        let entry = store.activity[i]
                        ActivityEntryRow(entry: entry, account: store.multiAccount ? entry.accountID.flatMap(store.account)?.displayName ?? "@\(entry.account)" : nil)
                            .tag(i)
                    }
                }
            }
        }
        .onChange(of: selection) { _, i in store.selectedID = i.flatMap(pr)?.id }
        .contextMenu(forSelectionType: Int.self) { rows in
            if !rows.isEmpty { Button("Open in Browser") { rows.forEach(open) } }
        } primaryAction: { rows in
            rows.forEach(open)
        }
        .overlay {
            if days.isEmpty {
                if !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ContentUnavailableView("No Activity Yet", systemImage: "clock.arrow.circlepath",
                                           description: Text("Every event PullPing sees appears here, notified or not, with every automation run. Kept for \(store.settings.activityDays) days."))
                }
            }
        }
        .searchable(text: $query, prompt: "Search activity")
        .task {
            selection = nil  // indices shift when the log is compacted
            store.compactActivity()
        }
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

/// Kind icon, title and time; repo #n and what happened; badges for what PullPing did.
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
                Text(verbatim: detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(entry.error ?? "")
                HStack(spacing: 4) {
                    ForEach(Array(badges.enumerated()), id: \.offset) { $0.element }
                    if let account { Chip(text: account, symbol: "person.crop.circle") }
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    /// Events: "octo-org/widgets #12 · Review approved · alice". Runs: the error, else the event that started it.
    private var detail: String {
        let ref = "\(entry.repo) #\(entry.number)"
        if entry.kind == .event { return "\(ref) · \(entry.what)" }
        return (entry.error ?? entry.event?.label).map { "\(ref) · \($0)" } ?? ref
    }

    private var symbol: String {
        switch entry.kind {
        case .event: entry.event?.symbol ?? "bell"
        case .run: "play.circle"
        case .handler: "terminal"
        }
    }

    private var hue: Color {
        if entry.kind != .event { return entry.ok == false ? Theme.bad : Theme.good }
        return entry.quiet == nil ? entry.event?.hue ?? Theme.neutral : Theme.neutral
    }

    private var badges: [Chip] {
        guard entry.kind == .event else {
            return [entry.ok == false ? Chip(text: entry.what, symbol: "xmark.octagon", tint: Theme.bad) : Chip(text: entry.what, symbol: "play.circle", tint: Theme.good)]
        }
        var chips = [entry.quiet.map { Chip(text: "Not shown: \($0.label)", symbol: "bell.slash") }
            ?? (entry.panel == .alert ? Chip(text: "Alert", symbol: "bell.badge", tint: Theme.needsYou) : Chip(text: "Banner", symbol: "bell"))]
        if entry.phone == true { chips.append(Chip(text: "Phone", symbol: "iphone")) }
        return chips
    }
}
