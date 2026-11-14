import AppKit
import PullPingCore
import SwiftUI

/// One regular window per draft (Review Draft… on the panel, the detail pane's Agent Draft section, an Activity row). A closed
/// window keeps its edits until the draft is posted or discarded.
@MainActor
final class DraftWindows {
    static let shared = DraftWindows()
    private var windows: [String: NSWindow] = [:]

    func show(store: Store, runID: String) {
        if let window = windows[runID] { return AccessoryWindows.shared.show(window) }
        guard let draft = store.draft(runID) else {
            NSSound.beep()
            return NotificationPanels.shared.show(note: "The draft is gone: discarded, posted, or older than 7 days.", title: "No draft", id: Automation.backgroundID, actions: [])
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = draft.action == .review ? "Review Draft" : "Summary"
        window.subtitle = "\(draft.repo) #\(draft.number)"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 540, height: 420)
        window.contentView = NSHostingView(rootView: DraftView(store: store, draft: draft) { [weak self] in self?.close(runID) })
        window.center()
        windows[runID] = window
        AccessoryWindows.shared.show(window)
    }

    func close(_ runID: String) { windows.removeValue(forKey: runID)?.close() }
}

/// The draft, editable, and the only Post button in PullPing. The agent's verdict is preselected, but Approve is never the
/// default button (Return posts a comment only), and Approve and Request Changes are refused once the pull request moved
/// past the draft's commit (`DraftPost.refusal`).
struct DraftView: View {
    let store: Store
    let draft: BackgroundDraft
    let close: () -> Void
    @State private var text: String
    @State private var event: DraftPost.Event
    @State private var error: String?
    @State private var posting = false
    @State private var askFirstPost = false
    @State private var askDiscard = false

    init(store: Store, draft: BackgroundDraft, close: @escaping () -> Void) {
        self.store = store
        self.draft = draft
        self.close = close
        _text = State(initialValue: draft.body)
        let head = store.tracked.prs[draft.prID].map { $0.headOID.isEmpty ? draft.head : $0.headOID } ?? draft.head
        _event = State(initialValue: draft.initialEvent(head: head))  // moved or cut diff: a comment
    }

    private var pr: TrackedPR? { store.tracked.prs[draft.prID] }
    private var head: String { pr.map { $0.headOID.isEmpty ? draft.head : $0.headOID } ?? draft.head }
    private var refusal: String? { DraftPost.refusal(event, body: text, draftHead: draft.head, head: head, open: (pr?.state ?? .open) == .open) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "\(draft.repo) #\(draft.number) · \(draft.title)").font(.headline).lineLimit(2)
                Text(verbatim: "Drafted by \(draft.agent.title) · at commit \(draft.head.prefix(7)) · \(relativeAge(draft.createdAt, now: store.now))")
                    .font(.callout).foregroundStyle(.secondary)
                if draft.notCloned {
                    Text("Not cloned on this Mac: drafted from the diff and the discussion only.").font(.callout).foregroundStyle(.secondary)
                }
                if let cut = draft.diffCut {
                    Label("The diff was cut: the agent saw \(kb(cut.kept)) of \(kb(cut.total)). Read the rest on GitHub before you approve.", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(Theme.needsYou)
                }
                if let cut = draft.discussionCut {
                    Text("The discussion was cut: the agent saw \(kb(cut.kept)) of \(kb(cut.total)).").font(.callout).foregroundStyle(.secondary)
                }
            }
            if draft.action == .review {
                TextEditor(text: $text)
                    .font(.body)
                    .accessibilityLabel("Review text")
                    .padding(6)  // the text kept off the border
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                Picker("Post as @\(draft.login):", selection: $event) {
                    ForEach(DraftPost.Event.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                if head != draft.head {
                    HStack(alignment: .firstTextBaseline) {
                        Label("The pull request changed since this draft.", systemImage: "exclamationmark.triangle").foregroundStyle(Theme.needsYou)
                        Spacer(minLength: 8)
                        Button("Run Again") { store.startBackground(.review, prID: draft.prID, event: nil) }
                            .help("A new background review at the current commit")
                    }
                }
            } else {
                ScrollView {
                    Text(verbatim: draft.body.isEmpty ? draft.summary : draft.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let message = error ?? (draft.action == .review ? refusal : nil) {
                Text(verbatim: message).font(.callout).foregroundStyle(Theme.bad).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            HStack {
                Button("Discard…", role: .destructive) { askDiscard = true }
                Button("Open Session") { store.openBackgroundSession(runID: draft.runID) }
                    .help("Resume the agent's session in a terminal, without a prompt")
                Button("Open on GitHub") { if draft.url.scheme == "https" { NSWorkspace.shared.open(draft.url) } }
                Spacer()
                if draft.action == .review {
                    Button(postTitle) { post() }
                        .keyboardShortcut(event == .comment ? .defaultAction : nil)  // Return never approves or requests changes
                        .disabled(posting || refusal != nil)
                        .help(refusal ?? "Posts on GitHub as @\(draft.login), at commit \(draft.head.prefix(7))")
                } else {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(draft.body.isEmpty ? draft.summary : draft.body, forType: .string)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 540, minHeight: 420)
        .alert("Post as @\(draft.login)?", isPresented: $askFirstPost) {
            Button("Post") { post(askedNow: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("PullPing will post this as @\(draft.login). Until now PullPing only read from GitHub.")
        }
        .confirmationDialog("Discard this draft?", isPresented: $askDiscard) {
            Button("Discard", role: .destructive) { store.discardDraft(draft.runID) }
        } message: {
            Text("The agent's \(draft.action.result) is deleted. Its session stays and Open Session in Recent Runs still finds it.")
        }
    }

    private func kb(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }

    private var postTitle: String {
        switch event {
        case .comment: "Post Comment"
        case .requestChanges: "Request Changes"
        case .approve: "Approve Pull Request"
        }
    }

    private func post(askedNow: Bool = false) {
        guard askedNow || store.postConfirmed(draft.login) else { return askFirstPost = true }
        posting = true
        error = nil
        Task {
            let failure = await store.postDraft(draft, body: text, event: event, askedNow: askedNow)
            posting = false
            if let failure { error = failure } else { close() }
        }
    }
}

/// The detail pane's Agent Draft row: the pull request's latest background run and what to do with it.
struct AgentDraftRow: View {
    let store: Store
    let run: RunRecord

    var body: some View {
        let draft = run.runID.flatMap(store.draft)
        HStack {
            Text(verbatim: line(draft)).lineLimit(2).help(run.detail)
            Spacer(minLength: 8)
            if let id = run.runID {
                if run.status?.isActive == true {
                    Button("Cancel") { store.cancelBackground(id) }
                } else if let draft {
                    Button(draft.action == .review ? "Review Draft…" : "Show Summary…") { DraftWindows.shared.show(store: store, runID: id) }
                } else if run.sessionID != nil {
                    Button("Open Session") { store.openBackgroundSession(runID: id) }
                }
            }
        }
    }

    /// "Review draft · suggests request changes · 4 min. ago", "Review in Background · running · 1 min. ago", or the run's detail.
    private func line(_ draft: BackgroundDraft?) -> String {
        let age = relativeAge(run.at, now: store.now)
        if let draft {
            return draft.action == .review ? "Review draft by \(draft.agent.title) · suggests \(draft.verdict.phrase) · \(age)" : "Summary · \(draft.summary)"
        }
        let title = run.background?.title ?? ""
        return run.status?.isActive == true ? "\(title) · \(run.status?.word ?? "") · \(age)" : "\(title) · \(run.detail) · \(age)"
    }
}
