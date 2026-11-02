import AppKit
import PullPingCore
import SwiftUI

/// A Run button on a panel: an automation in ask mode, or Handle with Agent.
struct PanelAction {
    let id: UUID  // the automation (Handle with Agent: `Automation.handlerID` / `handlerResumeActionID`)
    let title: String
    let run: @MainActor () -> Void
}

/// What one panel shows; coalescing updates it in place.
@MainActor @Observable final class PanelModel {
    var pr: TrackedPR
    var events: [PREvent]
    var alert: Bool
    var account: String?
    /// "+N more" summary panel when set.
    var moreCount: Int?
    var actions: [PanelAction]
    /// A note panel instead of a pull request's (`pr` is then a placeholder): its title, text and `actions`.
    var note: (title: String, text: String)?

    init(pr: TrackedPR, events: [PREvent], alert: Bool, account: String?, moreCount: Int? = nil, actions: [PanelAction] = []) {
        self.pr = pr; self.events = events; self.alert = alert; self.account = account; self.moreCount = moreCount; self.actions = actions
    }
}

/// Custom chrome on purpose (PRN-5): a notification must not take focus or activate the app, and
/// `UNUserNotificationCenter` would need a permission prompt. Never key (no `canBecomeKey` override), so
/// typing in another app can never act on a panel; every action also lives in the status panel and menus.
private final class NotificationNSPanel: NSPanel {}

/// Clicks reach the buttons even though the panel never becomes key.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Stacked top-right panels: one per PR, at most 4; a 5th PR turns slot 4 into a "+N more" summary.
@MainActor
final class NotificationPanels {
    static let shared = NotificationPanels()
    /// Set once at launch.
    weak var store: Store?

    private struct Entry {
        let prID: String?  // nil = summary
        let panel: NSPanel
        let model: PanelModel
        var hide: Task<Void, Never>?
    }

    private var active: [Entry] = []
    private var overflow: Set<String> = []
    private var nextAnnouncement = Date.distantPast
    private static let maxSlots = 4
    private static let gap: CGFloat = 8
    private static let margin: CGFloat = 12

    /// `actions`: Run and Handle with Agent buttons, offers first.
    func show(pr: TrackedPR, events: [PREvent], alert: Bool, account: String?, autoHide: Int, actions: [PanelAction] = []) {
        if let index = active.firstIndex(where: { $0.prID == pr.id }) {
            let model = active[index].model
            model.pr = pr
            model.events += events.filter { new in !model.events.contains { $0.id == new.id } }
            // Handle with Agent's buttons are replaced as a set (a link may have appeared) and stay after the offers.
            let handlerIDs: Set<UUID> = [Automation.handlerID, Automation.handlerResumeActionID]
            if actions.contains(where: { handlerIDs.contains($0.id) }) { model.actions.removeAll { handlerIDs.contains($0.id) } }
            for new in actions {  // a newer offer of the same automation replaces the older one (its event)
                if let i = model.actions.firstIndex(where: { $0.id == new.id }) { model.actions[i] = new } else { model.actions.append(new) }
            }
            model.actions = model.actions.filter { !handlerIDs.contains($0.id) } + model.actions.filter { handlerIDs.contains($0.id) }
            model.alert = model.alert || alert
            scheduleHide(index, seconds: autoHide)
            announce(model)
            return
        }
        if overflow.contains(pr.id) { return }
        if active.count >= Self.maxSlots {
            overflow.insert(pr.id)
            if let summary = active.last, summary.prID == nil {
                summary.model.moreCount = overflow.count
            } else if let last = active.last?.prID {
                overflow.insert(last)
                remove(at: active.count - 1, reflow: false)
                add(prID: nil, PanelModel(pr: pr, events: [], alert: true, account: nil, moreCount: overflow.count), autoHide: autoHide)
            }
            return
        }
        add(prID: pr.id, PanelModel(pr: pr, events: events, alert: alert, account: account, actions: actions), autoHide: autoHide)
    }

    /// An alert that is not about a pull request, with its buttons (e.g. "a CLI change made this automation automatic"); a
    /// newer note with the same `id` replaces it.
    // shortcut: notes skip the 4-slot limit; fold them into the "+N more" summary if they ever pile up.
    func show(note: String, title: String, id key: UUID, actions: [PanelAction]) {
        let id = "note:\(key)"
        dismiss(prID: id)
        let model = PanelModel(pr: TrackedPR(id: id, accountID: key, firstTrackedAt: Date()), events: [], alert: true, account: nil, actions: actions)
        model.note = (title, note)
        add(prID: id, model, autoHide: 0)
    }

    /// Handle with Agent's buttons on an open panel, swapped in place (a found session arrived); no panel, nothing.
    func replaceHandlerActions(prID: String, _ actions: [PanelAction]) {
        // Only on a panel whose events show the handler (its kinds), as `Store.show` decides.
        guard let model = active.first(where: { $0.prID == prID })?.model, store?.handler.handlerEvent(in: model.events) != nil else { return }
        let handlerIDs: Set<UUID> = [Automation.handlerID, Automation.handlerResumeActionID]
        model.actions = model.actions.filter { !handlerIDs.contains($0.id) } + actions
    }

    func dismiss(prID: String) {
        overflow.remove(prID)
        if let index = active.firstIndex(where: { $0.prID == prID }) { remove(at: index) }
    }

    func dismissAll() {
        overflow = []
        while !active.isEmpty { remove(at: active.count - 1) }
    }

    var isEmpty: Bool { active.isEmpty }

    private func add(prID: String?, _ model: PanelModel, autoHide: Int) {
        guard let screen = Self.screenUnderMouse() else { return }
        let panel = NotificationNSPanel(contentRect: NSRect(x: 0, y: 0, width: Theme.panelWidth, height: Theme.panelHeight),
                                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false  // owned by `active`; avoids AppKit double release on close()
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        let close = { [weak self, weak panel] in
            guard let self, let panel, let index = self.active.firstIndex(where: { $0.panel === panel }) else { return }
            if self.active[index].prID == nil { self.overflow = [] }
            self.remove(at: index)
        }
        let content = NotificationContent(
            model: model,
            onOpen: { [weak self] in
                guard let store = self?.store else { return }
                if let prID { store.open(prID) } else { close(); MainWindow.shared.show() }
            },
            onSnooze: { [weak self] in
                guard let prID else { return }
                Self.popUpSnoozeMenu { self?.store?.snooze([prID], $0) }
            },
            onMute: { [weak self] in if let prID { self?.store?.setMuted([prID], true) } },
            onDismiss: close,
            onHover: { [weak self, weak panel] hovering in
                guard let self, let index = self.active.firstIndex(where: { $0.panel === panel }) else { return }
                if hovering { self.active[index].hide?.cancel() } else { self.scheduleHide(index, seconds: autoHide) }
            })
        let host = FirstMouseHostingView(rootView: content)
        host.sizingOptions = []
        panel.contentView = host
        panel.setFrame(Self.frame(slot: active.count, screen: screen), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        active.append(Entry(prID: prID, panel: panel, model: model))
        scheduleHide(active.count - 1, seconds: autoHide)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25  // a fade only: no slide, so Reduce Motion needs no special case
            panel.animator().alphaValue = 1
        }
        announce(model)
    }

    /// Banners hide after `seconds`; alerts and the summary stay. Hover cancels (see `onHover`).
    private func scheduleHide(_ index: Int, seconds: Int) {
        active[index].hide?.cancel()
        guard !active[index].model.alert, let prID = active[index].prID else { return }
        active[index].hide = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, let index = self.active.firstIndex(where: { $0.prID == prID }) else { return }
            self.remove(at: index)
        }
    }

    private func remove(at index: Int, reflow: Bool = true) {
        let entry = active.remove(at: index)
        entry.hide?.cancel()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            entry.panel.animator().alphaValue = 0
        }, completionHandler: {
            // close, not orderOut: a hidden panel keeps its SwiftUI view alive (MeetAlert CPU leak).
            entry.panel.contentView = nil
            entry.panel.close()
        })
        if reflow { self.reflow() }
    }

    // shortcut: reflow moves every panel to the screen under the mouse now; per-panel screens if it matters.
    private func reflow() {
        guard let screen = Self.screenUnderMouse() else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
            for (i, entry) in active.enumerated() { entry.panel.animator().setFrame(Self.frame(slot: i, screen: screen), display: true) }
        }
    }

    /// The panel is never key and the app never active, so VoiceOver gets an announcement (A11Y-6), ≤ 1 per 0.5 s.
    private func announce(_ model: PanelModel) {
        let text = model.note.map { "\($0.title). \($0.text)" } ?? model.moreCount.map { "\($0) more need attention" }
            ?? "\(model.events.last?.kind.label ?? "Update"): \(model.pr.repo) number \(model.pr.number), \(model.pr.title)"
        let at = max(Date(), nextAnnouncement)
        nextAnnouncement = at.addingTimeInterval(0.5)
        Task {
            try? await Task.sleep(for: .seconds(max(0, at.timeIntervalSinceNow)))
            AccessibilityNotification.Announcement(text).post()
        }
    }

    private static func screenUnderMouse() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private static func frame(slot: Int, screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        return NSRect(x: visible.maxX - Theme.panelWidth - margin,
                      y: visible.maxY - margin - CGFloat(slot + 1) * (Theme.panelHeight + gap) + gap,
                      width: Theme.panelWidth, height: Theme.panelHeight)
    }

    /// AppKit menu at the mouse: a SwiftUI `Menu` does not open reliably in a panel that is never key.
    static func popUpSnoozeMenu(_ pick: @escaping (Snooze) -> Void) {
        let menu = NSMenu()
        for option in Snooze.allCases {
            let item = ClosureMenuItem(title: option.title) { pick(option) }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, key: String = "", run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError("unused") }

    @objc private func fire() { run() }
}

struct NotificationContent: View {
    let model: PanelModel
    let onOpen: () -> Void
    let onSnooze: () -> Void
    let onMute: () -> Void
    let onDismiss: () -> Void
    let onHover: (Bool) -> Void

    @Environment(\.colorSchemeContrast) private var contrast

    private var latest: PREvent? { model.events.last }
    private var hue: Color { model.moreCount != nil || model.note != nil ? Theme.needsYou : latest?.kind.hue ?? Theme.neutral }

    var body: some View {
        if let note = model.note { noteBody(note) } else { prBody }
    }

    /// A note: title, text, its button.
    private func noteBody(_ note: (title: String, text: String)) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Label(note.title, systemImage: "bolt.fill").font(.callout.weight(.semibold)).foregroundStyle(hue).lineLimit(1)
                Spacer(minLength: 4)
                Button("Dismiss", systemImage: "xmark", action: onDismiss)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Dismiss this notification")
            }
            Text(verbatim: note.text).font(.caption).foregroundStyle(.secondary).lineLimit(3).help(note.text)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                ForEach(Array(model.actions.enumerated()), id: \.offset) { _, action in
                    Button { action.run(); onDismiss() } label: { Label(action.title, systemImage: "gearshape") }
                        .buttonStyle(SignalButtonStyle(signal: hue, prominent: true))
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .padding(.leading, Theme.rimWidth)
        .frame(width: Theme.panelWidth, height: Theme.panelHeight, alignment: .topLeading)
        .background(background)
        .onHover(perform: onHover)
    }

    private var prBody: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if let more = model.moreCount {
                    Label("\(more) more need attention", systemImage: "tray.full")
                        .font(.callout.weight(.semibold)).foregroundStyle(hue)
                } else {
                    Label(kindLine, systemImage: latest?.kind.symbol ?? "bell")
                        .font(.callout.weight(.semibold)).foregroundStyle(hue).lineLimit(1).layoutPriority(1)
                    Text(verbatim: "\(model.pr.repo) #\(model.pr.number)").font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Button("Dismiss", systemImage: "xmark", action: onDismiss)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Dismiss this notification")
            }
            if model.moreCount == nil {
                Text(model.pr.title).font(.body.weight(.semibold)).lineLimit(1)
                if let latest {
                    Text(verbatim: latest.summary.isEmpty ? latest.line : "\(latest.actor): \(latest.summary)")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Text("Open the window to see them all.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                // Run buttons need the room: the other buttons go icon-only (help and VoiceOver keep their words), the chip goes.
                let compact = !model.actions.isEmpty && model.moreCount == nil
                Button(action: onOpen) {
                    Label(model.moreCount == nil ? "Open" : "Open Window", systemImage: "arrow.up.right.square")
                }
                .labelStyle(CompactLabelStyle(compact: compact))
                .buttonStyle(SignalButtonStyle(signal: hue, prominent: !compact))
                .help(model.moreCount == nil ? "Open the \(noun) in the browser" : "Open the PullPing window")
                if model.moreCount == nil {
                    ForEach(Array(model.actions.prefix(2).enumerated()), id: \.offset) { index, action in
                        Button { action.run(); onDismiss() } label: {
                            Label(action.title, systemImage: "play.fill").lineLimit(1)
                        }
                        .buttonStyle(SignalButtonStyle(signal: hue, prominent: index == 0))
                        .help("\(action.title): start the agent in a terminal")
                    }
                    if model.actions.count > 2 {
                        Text(verbatim: "+\(model.actions.count - 2)").font(.callout).foregroundStyle(.secondary)
                            .help("More in the pull request's menu")
                            .accessibilityLabel("\(model.actions.count - 2) more in the pull request's menu")
                    }
                    Button(action: onSnooze) { Label("Snooze…", systemImage: "moon.zzz") }
                        .labelStyle(CompactLabelStyle(compact: compact, icon: false))
                        .buttonStyle(SignalButtonStyle(signal: hue))
                        .help("Snooze this \(noun)")
                    Button(action: onMute) { Label(model.pr.isIssue ? "Mute Issue" : "Mute PR", systemImage: "bell.slash") }
                        .labelStyle(CompactLabelStyle(compact: compact, icon: false))
                        .buttonStyle(SignalButtonStyle(signal: hue))
                        .help("Stop notifications and reminders for this \(noun)")
                }
                Spacer(minLength: 4)
                if let account = model.account, !compact { Chip(text: account, symbol: "person.crop.circle").fixedSize() }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .padding(.leading, Theme.rimWidth)
        .frame(width: Theme.panelWidth, height: Theme.panelHeight, alignment: .topLeading)
        .background(background)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)  // body click = Open; the Open button is the accessible path
        .onHover(perform: onHover)
    }

    private var noun: String { model.pr.isIssue ? "issue" : "pull request" }

    private var kindLine: String {
        let kinds = model.events.map(\.kind.verb)
        return model.events.count > 1 ? "\(model.events.count) new: \(kinds.suffix(3).joined(separator: ", "))" : latest?.kind.label ?? "Update"
    }

    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
        return ZStack(alignment: .leading) {
            if contrast == .increased {
                shape.fill(Color(nsColor: .windowBackgroundColor))  // opaque under Increase Contrast (A11Y-12)
            } else {
                shape.fill(.regularMaterial)  // the system makes it opaque under Reduce Transparency
            }
            Rectangle().fill(hue).frame(width: Theme.rimWidth)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(contrast == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.primary.opacity(0.15)),
                                    lineWidth: contrast == .increased ? 2 : 1))
    }
}

/// Icon only when `compact`; otherwise the title, with the icon when `icon`.
private struct CompactLabelStyle: LabelStyle {
    var compact: Bool
    var icon = true

    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if compact {
            Label(configuration).labelStyle(.iconOnly)
        } else if icon {
            Label(configuration)
        } else {
            Label(configuration).labelStyle(.titleOnly)
        }
    }
}

/// Copied from MeetAlert: the app is never active and the panel never key, so system `.borderedProminent`
/// buttons would draw in their grey inactive look and lose the hue. `prominent` fills with the hue (one per panel).
private struct SignalButtonStyle: ButtonStyle {
    var signal: Color
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        SignalButtonBody(cfg: configuration, signal: signal, prominent: prominent)
    }

    private struct SignalButtonBody: View {
        let cfg: Configuration
        let signal: Color
        let prominent: Bool
        @State private var hover = false
        @Environment(\.colorSchemeContrast) private var contrast

        var body: some View {
            cfg.label
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(prominent ? AnyShapeStyle(Theme.onSignal) : AnyShapeStyle(.primary))
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(prominent ? AnyShapeStyle(signal) : AnyShapeStyle(Color.primary.opacity(hover ? 0.14 : 0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(
                            prominent ? AnyShapeStyle(.clear)
                                : contrast == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(signal.opacity(hover ? 0.7 : 0.35)),
                            lineWidth: contrast == .increased ? 1.5 : 1))
                )
                .opacity(prominent && hover ? 0.92 : 1)  // never brighten the fill: white text would lose contrast
                .scaleEffect(cfg.isPressed ? 0.97 : 1)
                .onHover { hover = $0 }
        }
    }
}
