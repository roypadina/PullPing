import AppKit
import PullPingCore
import SwiftUI

/// Not `@main`: `main.swift` runs smoke mode first.
struct PullPingApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    // Plain let, not @State: a @State read in init() is not the installed value, so a Store built there
    // would be a throwaway (MeetAlert lesson).
    private let store: Store

    init() {
        let store = Store.launch()
        self.store = store
        AppDelegate.store = store
        SettingsWindow.shared.store = store
        MainWindow.shared.store = store
        NotificationPanels.shared.store = store
        AccessoryWindows.shared.undoManager = store.undoManager
    }

    var body: some Scene {
        // The status item is AppKit (`StatusItem`); this never-inserted scene only carries the main menu commands.
        // Not a `Settings` scene: SwiftUI opens that one as an empty "PullPing Settings" window on reopen.
        MenuBarExtra("PullPing", isInserted: .constant(false)) { EmptyView() }
            .commands { AppCommands(store: store) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var store: Store?

    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        if let store = Self.store { StatusItem.shared.install(store: store) }
        _ = Updates.controller  // starts the daily update check
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Self.store?.setPaused(true) }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Self.store?.setPaused(false) }
        }
        // First launch only (MBX-18); smoke mode never gets here.
        guard !UserDefaults.standard.bool(forKey: DefaultsKey.didShowWelcome) else { return WelcomeWindow.showWhatsNewOnce() }
        UserDefaults.standard.set(true, forKey: DefaultsKey.didShowWelcome)
        UserDefaults.standard.set(true, forKey: DefaultsKey.didShowWhatsNew070)  // the welcome already describes 0.7
        WelcomeWindow.show()
    }

    /// Automation surface (STR-6): pullping://open, pullping://open?pr=<nodeID>, pullping://refresh, pullping://settings.
    @MainActor func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "pullping" {
            switch url.host {
            case "open":
                let pr = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "pr" }?.value
                MainWindow.shared.show(select: pr)
            case "refresh": Self.store?.refresh()
            case "settings": SettingsWindow.shared.show()
            default: break
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Opening PullPing again (Finder, Raycast) shows the main window: the way in when the icon is hidden (MBX-8).
    @MainActor func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainWindow.shared.show() }
        return false  // handled; `true` lets SwiftUI open a window of its own
    }

    @MainActor func applicationWillTerminate(_ notification: Notification) {
        Self.store?.interruptBackground()
        Self.store?.state.save()
    }
}

/// Menu bar while a window is open (policy `.regular`). Pull Request items act on the main-window selection
/// and are dimmed without one (MNU-8). The Edit menu keeps its default groups (MNU-5). The shortcuts are mirrored in
/// Settings › Shortcuts (`ShortcutsTab`): change both together.
struct AppCommands: Commands {
    let store: Store

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About PullPing") { AboutWindow.show() }
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { SettingsWindow.shared.show() }.keyboardShortcut(",")
        }
        SidebarCommands()
        CommandGroup(before: .sidebar) {
            Button("Refresh Now") { store.refresh() }.keyboardShortcut("r")
            Divider()
        }
        CommandGroup(before: .windowArrangement) {
            Button("Open Window") { MainWindow.shared.show() }.keyboardShortcut("1")
            Button("Activity") { MainWindow.shared.showActivity() }
        }
        CommandMenu("Pull Request") {
            let ids = store.selectedIDs
            let pr = store.selectedPR  // exactly one selected: the agent menus
            let muted = store.all(ids, \.muted), hidden = store.all(ids, \.hidden)
            Button("Open in Browser") { store.open(ids) }
                .keyboardShortcut("o", modifiers: [.command, .shift]).disabled(ids.isEmpty)
            Button(store.readTitle(ids)) { store.toggleRead(ids) }
                .keyboardShortcut("u", modifiers: [.command, .shift]).disabled(ids.isEmpty)
            Button("Mark All as Read") { store.markAllRead() }
                .keyboardShortcut("u", modifiers: [.command, .shift, .option])
            Divider()
            Menu("Handle with Agent") { if let pr { HandlerMenu(store: store, pr: pr) } }
                .disabled(pr == nil || !store.agentMenuShown)
            // The row menu's and the toolbar's Run Automation ▸ here too (MNU-2); dimmed without a selection.
            if let pr { RunAutomationMenu(store: store, pr: pr) } else { Menu("Run Automation") {}.disabled(true) }
            Divider()
            RemindMenu(store: store, ids: ids, menuBar: true)
            Menu("Snooze Notifications") {
                ForEach(Snooze.allCases, id: \.self) { option in
                    Button(option.title) { store.snooze(ids, option) }
                }
            }
            .disabled(ids.isEmpty)
            Button(muted ? "Unmute" : "Mute") { store.setMuted(ids, !muted) }
                .keyboardShortcut("m", modifiers: [.command, .control]).disabled(ids.isEmpty)
            Button(hidden ? "Unhide" : "Hide") { store.setHidden(ids, !hidden) }
                .keyboardShortcut("h", modifiers: [.command, .control]).disabled(ids.isEmpty)
            Button("Stop Tracking") {
                // ⌘⌫ deletes to line start while typing in the search field (KBD-6).
                if let text = NSApp.keyWindow?.firstResponder as? NSTextView { text.deleteToBeginningOfLine(nil) } else { store.stopTracking(ids) }
            }
            .keyboardShortcut(.delete, modifiers: .command).disabled(ids.isEmpty || store.remindIDs != nil)  // not behind the Remind Me sheet
            Divider()
            Button("Dismiss All Notifications") { NotificationPanels.shared.dismissAll() }
        }
        CommandGroup(replacing: .help) {
            Button("PullPing Help") { NSWorkspace.shared.open(URL(string: "https://github.com/roypadina/PullPing#readme")!) }
        }
    }
}
