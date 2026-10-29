import AppKit
import PullPingCore
import SwiftUI

/// The menu-bar icon. Left click toggles the status panel in a popover; right click or Control-click opens a menu
/// (MBX-13, MBX-14). AppKit, not `MenuBarExtra`: that has no right-click menu and can't be closed from code.
@MainActor
final class StatusItem: NSObject, NSPopoverDelegate {
    static let shared = StatusItem()
    private var store: Store?
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var visibility: NSKeyValueObservation?
    /// The packaged template glyph; the SF Symbol when running unbundled (`swift run`).
    private let glyph = NSImage(named: "menubar") ?? NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: nil)

    func install(store: Store) {
        self.store = store
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "PullPing"
        item.behavior = .removalAllowed  // ⌘-drag out hides it; the app keeps running (MBX-9)
        item.isVisible = UserDefaults.standard.object(forKey: DefaultsKey.showMenuBarIcon) as? Bool ?? true
        visibility = item.observe(\.isVisible) { item, _ in  // keeps Settings > General > Show in the Menu Bar in sync
            let visible = item.isVisible
            if UserDefaults.standard.object(forKey: DefaultsKey.showMenuBarIcon) as? Bool ?? true != visible {
                UserDefaults.standard.set(visible, forKey: DefaultsKey.showMenuBarIcon)
            }
        }
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        }
        popover.behavior = .transient
        popover.delegate = self
        self.item = item
        render()
    }

    func setVisible(_ visible: Bool) {
        if let item, item.isVisible != visible { item.isVisible = visible }
    }

    /// Before any window opens (AccessoryWindows) and on Escape.
    func closePopover() {
        if popover.isShown { popover.performClose(nil) }
    }

    /// Shape carries the state (MBX-5): warning triangle on account errors, dimmed offline, count when something needs you.
    private func render() {
        guard let store, let button = item?.button else { return }
        withObservationTracking {
            let image = store.hasError ? NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil) : glyph
            image?.isTemplate = true
            button.image = image
            button.title = store.badgeCount > 0 ? "\(store.badgeCount)" : ""
            button.appearsDisabled = store.offline
            button.setAccessibilityLabel(store.menuBarLabel)
            button.toolTip = store.menuBarLabel
        } onChange: { [weak self] in
            Task { @MainActor in self?.render() }  // fires once, before the change lands: re-read and re-subscribe
        }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true { showMenu() } else { togglePopover(sender) }
    }

    private func togglePopover(_ button: NSStatusBarButton) {
        guard let store else { return }
        if popover.isShown { popover.performClose(nil); return }
        let host = NSHostingController(rootView: StatusPanelView(store: store))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        NSApp.activate()  // user click only: arrows and Return need a key window
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// A closed popover drops its SwiftUI view, so it stops re-rendering on every store change.
    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }

    /// Order per MBX-11: actions, status, Settings / About, Quit last. Rebuilt per click so Pause shows its state.
    private func showMenu() {
        guard let store, let item else { return }
        closePopover()
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Open PullPing", key: "1") { MainWindow.shared.show() })
        menu.addItem(ClosureMenuItem(title: "Refresh Now") { store.refresh() })
        menu.addItem(ClosureMenuItem(title: "Mark All as Read") { store.markAllRead() })
        menu.addItem(ClosureMenuItem(title: "Dismiss All Notifications") { NotificationPanels.shared.dismissAll() })
        menu.addItem(.separator())
        let paused = store.settings.isPaused(Date())
        let pause = NSMenu()
        pause.autoenablesItems = false
        for (title, option) in [("1 Hour", Snooze.hour1), ("3 Hours", .hours3), ("Until Tomorrow 9:00", .tomorrow)] {
            pause.addItem(ClosureMenuItem(title: title) { store.pause(until: option.until(from: Date())) })
        }
        pause.addItem(.separator())
        let resume = ClosureMenuItem(title: "Resume") { store.pause(until: nil) }
        resume.isEnabled = paused
        pause.addItem(resume)
        let pauseItem = NSMenuItem(title: "Pause Notifications", action: nil, keyEquivalent: "")
        pauseItem.submenu = pause
        menu.addItem(pauseItem)
        if paused, let until = store.settings.pausedUntil {
            menu.addItem(NSMenuItem(title: "Paused until \(until.formatted(date: .omitted, time: .shortened))", action: nil, keyEquivalent: ""))
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Settings…", key: ",") { SettingsWindow.shared.show() })
        menu.addItem(ClosureMenuItem(title: "About PullPing") { AboutWindow.show() })
        menu.addItem(ClosureMenuItem(title: "Support on Ko-fi ☕") { NSWorkspace.shared.open(AboutInfo.kofi) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Quit PullPing", key: "q") { NSApp.terminate(nil) })
        // shortcut: set-then-clear `menu` is the community way to open a status menu (popUpStatusItemMenu is deprecated);
        // re-test on each macOS.
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }
}
