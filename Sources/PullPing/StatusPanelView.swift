import AppKit
import PullPingCore
import SwiftUI

/// Status item popover: scope (All · @a · @b) and filter over the list, keyboard-driven (MBX-1: a list needs a panel).
struct StatusPanelView: View {
    let store: Store
    @State private var selection: Set<String> = []
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
        let map = store.signals(scope), new = map.values.reduce(0) { $0 + $1.new }
        let breakdown = Attention.breakdown(store.prs(scope, .needsMe), counting: store.settings.badgeReasons)
        let filters = Filter.allCases.filter { $0 != .issues || store.settings.trackIssues }
        // Filters other than the current one with new items: the dot beside the menu hints to open it.
        let elsewhere = filters.filter { $0 != filter && $0.signal(map).new > 0 }.map(\.title).joined(separator: ", ")
        let needs = filter.signal(map).needs
        return VStack(alignment: .leading, spacing: 10) {
            // Title and controls on one row; the lines below get the panel's whole width (beside the menu they wrapped and
            // truncated, and their width changed with the filter's name).
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .center, spacing: 8) {
                    Text("Pull Requests").font(.headline)
                    Spacer()
                    // In the title row (design §5.3), so the account segments get the whole row below.
                    PopUpMenuButton(chevron: true) {
                        FilterMenu.make(filters: filters, map: map, current: filter) { filter = $0 }
                    } label: {
                        Label(needs > 0 ? "\(filter.title) \(needs)" : filter.title, systemImage: filter.symbol)
                    }
                    .help(elsewhere.isEmpty ? "Filter" : "Filter. New activity in \(elsewhere)")
                    .accessibilityValue([needs > 0 ? "\(needs) need you" : nil, elsewhere.isEmpty ? nil : "new activity in \(elsewhere)"]
                        .compactMap { $0 }.joined(separator: ", "))
                    if !elsewhere.isEmpty { NewDot().accessibilityHidden(true) }  // the menu's value says it
                    buttons
                }
                HStack(spacing: 4) {
                    if store.syncing { ProgressView().controlSize(.mini) }
                    if store.offline { Image(systemName: "wifi.slash").accessibilityHidden(true) }
                    Text(store.freshness)
                }
                .font(.caption).foregroundStyle(.secondary)
                // Both cover the selected segment. The count of new shows only here, on its own line: appended, the
                // breakdown's truncation cut it off.
                if !breakdown.isEmpty {
                    Text(breakdown).font(.caption).foregroundStyle(Theme.needsYou).lineLimit(3)
                }
                if new > 0 { Text("\(new) new").font(.caption).foregroundStyle(.secondary) }
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
            if store.settings.inboxLayout == .unified { segment("All", .all).tag("") }
            ForEach(store.accounts) { segment($0.displayName, .account($0.id)).tag($0.id.uuidString) }
        }
        .labelsHidden()
    }

    /// "Work 3 •": need you, and a dot when anything in it is new. Segments take plain text, so the dot is a glyph.
    private func segment(_ name: String, _ scope: Scope) -> some View {
        let signal = store.signals(scope).values.reduce(Signal(), +)
        return Text(verbatim: signal.badge.map { "\(name) \($0)" } ?? name)
            .accessibilityLabel(signal.spoken.isEmpty ? name : "\(name), \(signal.spoken)")
    }

    @ViewBuilder private var buttons: some View {
        Button("Refresh", systemImage: "arrow.clockwise") { store.refresh() }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .keyboardShortcut("r")
            .help("Refresh now (⌘R)")
        PopUpMenuButton(chevron: false) {
            StatusItem.shared.makeMenu() ?? NSMenu()
        } label: {
            Label("More", systemImage: "ellipsis.circle").labelStyle(.iconOnly)  // a menu, not Settings: no gear (SYM-2)
        }
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
                        PRRows(store: store, prs: section.prs, scope: scope)
                    } else if section.collapsed {
                        Section(isExpanded: Binding(get: { opened.contains(section.title) }, set: { _ in opened.formSymmetricDifference([section.title]) })) {
                            PRRows(store: store, prs: section.prs, scope: scope)
                        } header: {
                            CollapsedHeader(section: section, open: opened.contains(section.title), now: store.now) { opened.formSymmetricDifference([section.title]) }
                        }
                    } else {
                        Section(section.title) { PRRows(store: store, prs: section.prs, scope: scope) }
                    }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: ids) { _, ids in  // never act on a row the list no longer shows
                if !selection.isSubset(of: ids) { selection.formIntersection(ids) }
            }
            .focused($listFocused)
            .contextMenu(forSelectionType: String.self) { ids in
                PRMenuItems(store: store, ids: ids)
            } primaryAction: { ids in  // double-click or Return
                store.open(ids)
            }
            .onKeyPress(.return, phases: .down) { press in  // ⌘↩ opens the one selected row in the main window
                guard press.modifiers.contains(.command), selection.count == 1, let id = selection.first else { return .ignored }
                MainWindow.shared.show(select: id)
                return .handled
            }
            .prKeys(store: store, ids: selection)
            .onAppear { listFocused = true }
        }
    }
}

/// The filter menu: the number = need you (a menu-item badge), a coloured dot = new, the words in the tooltip. AppKit, so
/// both always render (SwiftUI's `.badge` on menu options dropped some) and `PopUpMenuButton` can open it after the click.
enum FilterMenu {
    @MainActor static func make(filters: [Filter], map: [Bucket: Signal], current: Filter, select: @escaping (Filter) -> Void) -> NSMenu {
        let menu = NSMenu()
        for option in filters {
            let signal = option.signal(map)
            let item = ClosureMenuItem(title: option.title) { select(option) }
            item.image = icon(option.symbol, dot: signal.new > 0)
            item.state = option == current ? .on : .off
            if signal.needs > 0 { item.badge = NSMenuItemBadge(count: signal.needs) }
            item.toolTip = signal.spoken
            menu.addItem(item)
        }
        return menu
    }

    /// The option's symbol; with new activity, an accent dot on its top-right corner (drawn per appearance, so not a
    /// template: the menu would tint the dot too).
    static func icon(_ symbol: String, dot: Bool) -> NSImage? {
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { return nil }
        guard dot else { return base }
        let image = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            NSColor.labelColor.set()
            rect.fill(using: .sourceAtop)
            let dot = NSRect(x: rect.maxX - 6, y: rect.maxY - 6, width: 6, height: 6)
            let cg = NSGraphicsContext.current?.cgContext
            cg?.setBlendMode(.clear)  // a gap around the dot, so it reads apart from the glyph
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            cg?.setBlendMode(.normal)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// A borderless button that opens an AppKit menu below itself on click (SwiftUI's `Menu` closed on the panel's first click).
struct PopUpMenuButton<Label: View>: View {
    let chevron: Bool
    let menu: () -> NSMenu
    @ViewBuilder let label: () -> Label
    @State private var anchor = Anchor()

    var body: some View {
        Button {
            guard let view = anchor.view else { return }
            let menu = menu(), at = NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4)
            let front = { NSWorkspace.shared.frontmostApplication == .current }
            let wasFront = front(), opened = Date()
            if menu.popUp(positioning: nil, at: at, in: view) { return }
            // shortcut: if PullPing still wasn't active, opening the menu activates it and that closes the menu at once (traced):
            // reopen it once. Drop when the panel's activation is reliable on every macOS PullPing supports.
            if !wasFront, front(), Date().timeIntervalSince(opened) < 0.5 {
                DispatchQueue.main.async { menu.popUp(positioning: nil, at: at, in: view) }
            }
        } label: {
            HStack(spacing: 3) {
                label()
                if chevron { Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).accessibilityHidden(true) }
            }
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .background(AnchorView(anchor: anchor))
    }

    final class Anchor { weak var view: NSView? }

    struct AnchorView: NSViewRepresentable {
        let anchor: Anchor
        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            anchor.view = view
            return view
        }
        func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
    }
}
