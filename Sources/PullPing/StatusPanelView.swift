import AppKit
import PullPingCore
import SwiftUI

/// Status item popover: scope (All · @a · @b) and filter over the list, keyboard-driven (MBX-1: a list needs a panel).
struct StatusPanelView: View {
    let store: Store
    @State private var selection: String?
    /// Collapsed groups the user opened (Waiting on Others, Reviewed, Drafts), by title.
    @State private var opened: Set<String> = []
    @FocusState private var listFocused: Bool
    @AppStorage(DefaultsKey.panelFilter) private var filter = Filter.needsMe
    /// Account id, empty = All Accounts; `Store.panelScope` resolves it.
    @AppStorage(DefaultsKey.panelAccount) private var account = ""

    var body: some View {
        let scope = store.panelScope(account)
        VStack(spacing: 0) {
            header(scope)
            if !store.errorAccounts.isEmpty {
                VStack(spacing: 4) {
                    ForEach(store.errorAccounts) { AccountErrorRow(account: $0, status: store.statuses[$0.id] ?? .ok) }
                }
                .padding(.horizontal, 12).padding(.bottom, 8)
            }
            Divider()
            content(scope).frame(maxHeight: .infinity)
            Divider()
            HStack {
                Button("Open Window") { MainWindow.shared.show() }
                Spacer()
                Button("Activity") { MainWindow.shared.showActivity() }
            }
            .padding(10)
        }
        .frame(width: 380, height: 520)
        .onExitCommand { StatusItem.shared.closePopover() }
    }

    private func header(_ scope: Scope) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pull Requests").font(.headline)
                    HStack(spacing: 4) {
                        if store.syncing { ProgressView().controlSize(.mini) }
                        if store.offline { Image(systemName: "wifi.slash").accessibilityHidden(true) }
                        Text(store.freshness)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    if !store.breakdown.isEmpty {
                        Text(store.breakdown).font(.caption).foregroundStyle(Theme.needsYou).lineLimit(3)
                    }
                }
                Spacer()
                // In the title row (design §5.3), so the account segments get the whole row below.
                Menu {  // a Menu, not a menu Picker: that one is as wide as its longest item
                    Picker("Filter", selection: $filter) {
                        ForEach(Filter.allCases.filter { $0 != .issues || store.settings.trackIssues }, id: \.self) {
                            Label($0.title, systemImage: $0.symbol).tag($0)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Label(filter.title, systemImage: filter.symbol)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Filter")
                buttons
            }
            if store.accounts.count > 1 {
                // Segments while they fit the 380 pt panel; a menu once names get long (no header overflow).
                ViewThatFits(in: .horizontal) {
                    scopePicker(scope).pickerStyle(.segmented)
                    scopePicker(scope).pickerStyle(.menu).fixedSize()
                }
            }
        }
        .padding(12)
    }

    private func scopePicker(_ scope: Scope) -> some View {
        Picker("Account", selection: Binding(get: { scope.key }, set: { account = $0 })) {
            if store.settings.inboxLayout == .unified { Text(segment("All", .all)).tag("") }
            ForEach(store.accounts) { Text(segment($0.displayName, .account($0.id))).tag($0.id.uuidString) }
        }
        .labelsHidden()
    }

    /// "Work 2": the count uses the menu-bar measure.
    private func segment(_ name: String, _ scope: Scope) -> String {
        let count = store.count(scope)
        return count > 0 ? "\(name) \(count)" : name
    }

    @ViewBuilder private var buttons: some View {
        Button("Refresh", systemImage: "arrow.clockwise") { store.refresh() }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .keyboardShortcut("r")
            .help("Refresh now (⌘R)")
        Menu {
            Button("Open Window") { MainWindow.shared.show() }.keyboardShortcut("1")
            Button("Activity") { MainWindow.shared.showActivity() }
            Button("Mark All as Read") { store.markAllRead() }
            Button("Dismiss All Notifications") { NotificationPanels.shared.dismissAll() }
            Divider()
            // Same items as the right-click menu (StatusItem), so both menus match.
            Menu("Pause Notifications") {
                ForEach([("1 Hour", Snooze.hour1), ("3 Hours", .hours3), ("Until Tomorrow 9:00", .tomorrow)], id: \.0) { title, option in
                    Button(title) { store.pause(until: option.until(from: Date())) }
                }
                Divider()
                Button("Resume") { store.pause(until: nil) }.disabled(!store.settings.isPaused(Date()))
            }
            if store.settings.isPaused(Date()), let until = store.settings.pausedUntil {
                Text("Paused until \(until.formatted(date: .omitted, time: .shortened))")
            }
            Divider()
            Button("Settings…") { SettingsWindow.shared.show() }.keyboardShortcut(",")
            Button("About PullPing") { AboutWindow.show() }
            Button("Support on Ko-fi ☕") { NSWorkspace.shared.open(AboutInfo.kofi) }
            Divider()
            Button("Quit PullPing") { NSApp.terminate(nil) }.keyboardShortcut("q")
        } label: {
            Label("More", systemImage: "ellipsis.circle").labelStyle(.iconOnly)  // a menu, not Settings: no gear (SYM-2)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More: Open Window, Pause Notifications, Settings, Quit")
    }

    /// The filter's sections; Needs Me adds what waits on others and what I reviewed, collapsed.
    @ViewBuilder private func content(_ scope: Scope) -> some View {
        let sections = filter.sections(store.prs(scope, filter)) + (filter == .needsMe ? [
            ListSection(title: "Waiting on Others", prs: Filter.myPRs.sections(store.prs(scope, .myPRs)).first { $0.title == "Waiting on Others" }?.prs ?? [], collapsed: true),
            ListSection(title: "Reviewed", prs: Filter.reviews.sections(store.prs(scope, .reviews)).first { $0.title == "Reviewed" }?.prs ?? [], collapsed: true),
        ].filter { !$0.prs.isEmpty } : [])
        let ids = sections.flatMap(\.prs).map(\.id)
        if ids.isEmpty {
            EmptyState(store: store, filter: filter, scope: scope).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selection) {
                if !sections.contains(where: { !$0.collapsed }) {  // Needs Me is empty: say so above the collapsed groups
                    EmptyState(store: store, filter: filter, scope: scope).frame(maxWidth: .infinity).padding(.vertical, 16)
                }
                ForEach(sections, id: \.title) { section in
                    if section.title.isEmpty {
                        PRRows(store: store, prs: section.prs)
                    } else if section.collapsed {
                        Section(isExpanded: Binding(get: { opened.contains(section.title) }, set: { _ in opened.formSymmetricDifference([section.title]) })) {
                            PRRows(store: store, prs: section.prs)
                        } header: {
                            Text("\(section.title) (\(section.prs.count))")
                        }
                    } else {
                        Section(section.title) { PRRows(store: store, prs: section.prs) }
                    }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: ids) { _, ids in  // never act on a row the list no longer shows
                if let selection, !ids.contains(selection) { self.selection = nil }
            }
            .focused($listFocused)
            .contextMenu(forSelectionType: String.self) { ids in
                PRMenuItems(store: store, ids: ids)
            } primaryAction: { ids in  // double-click or Return
                ids.forEach(store.open)
            }
            .onKeyPress(.return, phases: .down) { press in  // ⌘↩ opens the selection in the main window
                guard press.modifiers.contains(.command), let selection else { return .ignored }
                MainWindow.shared.show(select: selection)
                return .handled
            }
            .onAppear { listFocused = true }
        }
    }
}
