import PullPingCore
import ServiceManagement
import SwiftUI

/// First-launch welcome (MBX-18): where the icon is, what a notification looks like, how to get back in
/// without the icon (MBX-8, MBX-9), and the login item (MBX-17). Shown once from AppDelegate, and again from "Welcome Guide…".
@MainActor
enum WelcomeWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: WelcomeView(
                onAddAccount: { window?.close(); SettingsWindow.shared.show(tab: "Accounts") },
                onDone: { window?.close() })))
            w.title = "Welcome"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
            // Release on close: a kept-alive window keeps the login toggle's activation subscription running.
            Task { @MainActor in
                for await _ in NotificationCenter.default.notifications(named: NSWindow.willCloseNotification, object: w) { break }
                window = nil
            }
        }
        if let window { AccessoryWindows.shared.show(window) }
    }

    /// Once, after an update to 0.7 (a first launch gets the welcome instead): lists and notifications changed.
    static func showWhatsNewOnce() {
        guard !UserDefaults.standard.bool(forKey: DefaultsKey.didShowWhatsNew070) else { return }
        UserDefaults.standard.set(true, forKey: DefaultsKey.didShowWhatsNew070)
        let id = UUID(uuidString: "0D7A0000-0000-4000-8000-000000000070")!
        NotificationPanels.shared.show(
            note: "Lists sort by whose turn it is: Needs Me first. A notification now means something needs you; merges, CI passes and other updates are listed in Activity.",
            title: "New in PullPing 0.7", id: id,
            actions: [PanelAction(id: id, title: "Notification Settings") { SettingsWindow.shared.show(tab: "Notifications") }])
    }
}

struct WelcomeView: View {
    let onAddAccount: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to PullPing").font(.title2.bold())
                    Text("Pull request emails get buried and reviews wait on you without you knowing. PullPing tracks every pull request and issue you are part of, across your GitHub accounts, and tells you when something happens.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            row("arrow.triangle.pull", "PullPing lives in the menu bar.",
                "Click its icon for what needs you: reviews to do, your pull requests to fix or merge. A number shows how many.")
            row("bell.badge", "Notifications stay out of your way.",
                "A small panel appears at the top right only when something needs you. Everything else is listed in Activity.")
            row("questionmark.circle", "Icon missing?",
                "Open PullPing again from Applications to get the window, or check System Settings > Menu Bar.")
            LaunchAtLoginToggle()
            SupportBox()
            HStack {
                Button("Add Account…", action: onAddAccount)
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func row(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tint).frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Free-and-open-source note with the Ko-fi link; the welcome window's own next step stays the primary action.
struct SupportBox: View {
    var body: some View {
        GroupBox {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Free and open source").font(.headline)
                    Text("If PullPing saves you time, a coffee on Ko-fi keeps the next one coming.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Link("Support on Ko-fi ☕", destination: AboutInfo.kofi).buttonStyle(.bordered)
            }
            .padding(4)
        }
    }
}

/// Settings > General and the welcome window (MBX-17): user action only, status re-read on activation.
struct LaunchAtLoginToggle: View {
    @State private var status = SMAppService.mainApp.status

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Open at Login", isOn: Binding(
                get: { status == .enabled },
                set: { on in
                    try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    status = SMAppService.mainApp.status
                }))
            if status == .requiresApproval {
                Button("Allow in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
            } else if status == .notFound {
                Text("Move PullPing to Applications to open it at login.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            status = SMAppService.mainApp.status  // the user may change it in System Settings
        }
    }
}
