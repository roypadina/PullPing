import AppKit
import PullPingCore
import SwiftUI
import XCTest
@testable import PullPing

/// Dev-only: renders the README screenshots offscreen from `Fixtures` (generic data only).
/// Skipped unless RENDER_SCREENSHOTS=<output dir>. Usage:
///   RENDER_SCREENSHOTS=$PWD/docs/screenshots swift test --filter ScreenshotRenderTests
@MainActor
final class ScreenshotRenderTests: XCTestCase {
    func test_renderScreenshots() throws {
        guard let dir = ProcessInfo.processInfo.environment["RENDER_SCREENSHOTS"] else {
            throw XCTSkip("set RENDER_SCREENSHOTS=<dir> to render")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for dark in [false, true] {
            let suffix = dark ? "-dark" : ""
            let store = Fixtures.sampleStore()
            store.selectedID = "PR_1"
            store.selection = nil  // an offscreen sidebar selection renders as a black bar
            let pr = { store.tracked.prs[$0]! }
            func save(_ name: String, _ view: some View, _ size: NSSize) throws {
                try render(view, size: size, dark: dark, to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)\(suffix).png"))
            }
            try save("status-panel", StatusPanelView(store: store), NSSize(width: 380, height: 520))
            try save("main-window", MainView(store: store), NSSize(width: 1100, height: 680))
            try save("notification-banner", panel(PanelModel(pr: pr("PR_1"), events: Array(pr("PR_1").events.suffix(1)), alert: false, account: "@dana")),
                     NSSize(width: Theme.panelWidth + 40, height: Theme.panelHeight + 40))
            try save("notification-alert", panel(PanelModel(pr: pr("PR_2"), events: pr("PR_2").events, alert: true, account: "@dana")),
                     NSSize(width: Theme.panelWidth + 40, height: Theme.panelHeight + 40))
            try save("notification-issue", panel(PanelModel(pr: pr("I_1"), events: pr("I_1").events, alert: false, account: "@dana")),
                     NSSize(width: Theme.panelWidth + 40, height: Theme.panelHeight + 40))
            try save("settings-accounts", AccountsTab(store: store), NSSize(width: 520, height: AccountsTab.height))
            try save("settings-notifications", NotificationsTab(store: store), NSSize(width: 520, height: NotificationsTab.height))
            try save("settings-phone", PhoneTab(store: store), NSSize(width: 520, height: PhoneTab.height))
            try save("settings-general", GeneralTab(store: store), NSSize(width: 520, height: GeneralTab.height))
        }
    }

    /// Agent automations, light only: Settings → Automations, the rule editor, and panels with the agent buttons.
    func test_renderAutomationScreenshots() throws {
        guard let dir = ProcessInfo.processInfo.environment["RENDER_SCREENSHOTS"] else {
            throw XCTSkip("set RENDER_SCREENSHOTS=<dir> to render")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func save(_ name: String, _ view: some View, _ size: NSSize) throws {
            try render(view, size: size, dark: false, to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        let store = Fixtures.sampleStore()
        var ci = Automation(name: "Fix failing CI", kinds: [.ciFailed],
                            prompt: "CI failed on {pr_url}. Read the failing check with `gh pr checks {pr_number} --repo {repo}`, fix it on the branch and push.",
                            workingDirectory: "{worktree_dir}")
        ci.scope = .mine
        var review = Automation(name: "Answer review feedback", kinds: [.reviewChangesRequested, .reviewCommented, .comment],
                                prompt: "{event_label} by @{actor} on {pr_url}. Read it with `gh pr view {pr_number} --repo {repo} --comments`, address what you agree with, push, and reply on the pull request.",
                                workingDirectory: "{worktree_dir}")
        review.scope = .mine
        review.repos = ["octo-org/widgets"]
        review.sessionID = Automation.linkedSession
        var triage = Automation(name: "Triage assigned issues", kinds: [.assigned], workingDirectory: "{repo_dir}")
        triage.agent = .codex
        triage.mode = .auto
        triage.actors = ["carol"]
        triage.source = "cli"
        store.automationStore.mutate { file in
            file.automations = [ci, review, triage]
            file.handler.enabled = true
        }
        // A linked session before the tab renders: it once pushed Fallback folder out of its card. Also the editor's Try target,
        // so the linked-session rule can run.
        let latest = try XCTUnwrap(store.prs.first)
        store.automationStore.mutate {
            $0.setLink(SessionLink(pr: PRRef(repo: latest.repo, number: latest.number), agent: .claude,
                                   sessionID: "0f3c2a1e-5b7d-4c9e-8a10-2b4d6f8e1c3a", cwd: "~/Code/widgets", setAt: Date(), source: "cli", by: "claude"))
        }
        store.setFindSessions(false)  // reloads the store's copy
        store.mutateRepoFolders { $0.roots = ["~/Code", "~/src"] }  // also reloads the store's copy
        try save("settings-automations", AutomationsTab(store: store), NSSize(width: 520, height: 945))  // down to Repository Folders
        // Scrolled to its end (agent, session, prompt); 32 pt taller than the sheet so the top edge falls between sections.
        try render(RuleEditorSheet(store: store, rule: review), size: NSSize(width: 560, height: 672), dark: false, scrollToEnd: true,
                   to: URL(fileURLWithPath: dir).appendingPathComponent("rule-editor.png"))
        let pr = { store.tracked.prs[$0]! }
        let handle = PanelModel(pr: pr("PR_5"), events: pr("PR_5").events, alert: false, account: "@dana-work",
                                actions: [PanelAction(id: Automation.handlerID, title: "Handle with Agent") {}])
        let resume = PanelModel(pr: pr("PR_2"), events: Array(pr("PR_2").events.prefix(1)), alert: false, account: "@dana",
                                actions: [PanelAction(id: Automation.handlerResumeActionID, title: "Resume Session") {},
                                          PanelAction(id: Automation.handlerID, title: "New Session") {}])
        let panels = VStack(spacing: 10) {
            NotificationContent(model: resume, onOpen: {}, onSnooze: {}, onMute: {}, onDismiss: {}, onHover: { _ in })
            NotificationContent(model: handle, onOpen: {}, onSnooze: {}, onMute: {}, onDismiss: {}, onHover: { _ in })
        }
        .padding(20)
        try save("notification-agent", panels, NSSize(width: Theme.panelWidth + 40, height: Theme.panelHeight * 2 + 50))
    }

    /// The panel on a plain backdrop with room for its edge.
    private func panel(_ model: PanelModel) -> some View {
        NotificationContent(model: model, onOpen: {}, onSnooze: {}, onMute: {}, onDismiss: {}, onHover: { _ in })
            .padding(20)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    /// `scrollToEnd`: the first scroll view (a grouped Form's) scrolled to its end before the capture.
    private func render(_ view: some View, size: NSSize, dark: Bool, scrollToEnd: Bool = false, to url: URL) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))  // cacheDisplay skips the window background
            .environment(\.controlActiveState, .key))
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        if scrollToEnd {
            func first(_ view: NSView) -> NSScrollView? { view.subviews.lazy.compactMap { ($0 as? NSScrollView) ?? first($0) }.first }
            let scroller = try XCTUnwrap(first(host))
            let end = (scroller.documentView?.frame.height ?? 0) - scroller.contentView.bounds.height
            scroller.contentView.scroll(to: NSPoint(x: 0, y: max(0, end)))
            scroller.reflectScrolledClipView(scroller.contentView)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        let scale = 2
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try Self.stripMetadata(png).write(to: url)
    }

    /// Keeps only IHDR, IDAT and IEND (no ICC profile, gamma or timestamps).
    static func stripMetadata(_ png: Data) -> Data {
        var out = png.prefix(8)
        var offset = 8
        let bytes = [UInt8](png)
        while offset + 8 <= bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            let type = String(decoding: bytes[offset + 4..<offset + 8], as: UTF8.self)
            let end = offset + 12 + length
            if ["IHDR", "IDAT", "IEND"].contains(type) { out.append(contentsOf: bytes[offset..<end]) }
            offset = end
        }
        return out
    }
}
