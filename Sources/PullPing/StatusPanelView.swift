import AppKit
import PullPingCore
import SwiftUI

/// `MenuBarExtra` `.window` content: Mine · To Review · Involved, keyboard-driven (MBX-1: a list needs a panel).
struct StatusPanelView: View {
    let store: Store
    @State private var selection: String?
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            if !store.errorAccounts.isEmpty {
                VStack(spacing: 4) {
                    ForEach(store.errorAccounts) { AccountErrorRow(account: $0, status: store.statuses[$0.id] ?? .ok) }
                }
                .padding(.horizontal, 12).padding(.bottom, 8)
            }
            Divider()
            content.frame(maxHeight: .infinity)
            Divider()
            HStack {
                Button("Open Window") { MainWindow.shared.show() }
                Spacer()
                if store.badgeCount > 0 {
                    Text("\(store.badgeCount) need attention").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .padding(10)
        }
        .frame(width: 380, height: 520)
        .onExitCommand { NSApp.keyWindow?.close() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pull Requests").font(.headline)
                HStack(spacing: 4) {
                    if store.syncing { ProgressView().controlSize(.mini) }
                    if store.offline { Image(systemName: "wifi.slash").accessibilityHidden(true) }
                    Text(store.freshness)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Refresh", systemImage: "arrow.clockwise") { store.refresh() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .keyboardShortcut("r")
                .help("Refresh now (⌘R)")
            Menu {
                Button("Open Window") { MainWindow.shared.show() }.keyboardShortcut("1")
                Button("Mark All as Read") { store.markAllRead() }
                Button("Dismiss All Notifications") { NotificationPanels.shared.dismissAll() }
                Divider()
                Button("Settings…") { SettingsWindow.shared.show() }.keyboardShortcut(",")
                Button("About PullPing") { AboutWindow.show() }
                Button("Support on Ko-fi ☕") { NSWorkspace.shared.open(AboutInfo.kofi) }
                Divider()
                Button("Quit PullPing") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Label("More", systemImage: "gearshape").labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Settings, About and Quit")
        }
        .padding(12)
    }

    @ViewBuilder private var content: some View {
        let prs = store.prs
        if prs.isEmpty {
            EmptyState(store: store).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selection) {
                ForEach(PRGroup.allCases, id: \.self) { group in
                    let rows = prs.filter { Attention.group($0) == group }
                    if !rows.isEmpty {
                        Section(group.title) {
                            ForEach(rows) { pr in
                                PRRow(pr: pr, account: store.login(for: pr), now: store.now).tag(pr.id)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
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
