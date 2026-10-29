import AppKit
import PullPingCore
import SwiftUI

/// Own Settings window (MBX-16): `SettingsLink`/`openSettings` are unreliable in a menu-bar-only app.
/// `NSTabViewController` keeps the tabs as toolbar icons; a SwiftUI `TabView` in a plain `NSWindow`
/// would draw in-window tabs instead.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    var store: Store?  // set once at launch
    private var window: NSWindow?
    private var tabs: SettingsTabs?

    /// `tab`: a tab label ("Accounts") to switch to; nil reopens on the last one.
    func show(tab: String? = nil) {
        guard let store else { return }
        if window == nil {
            let tabs = SettingsTabs()
            tabs.tabStyle = .toolbar
            // Each pane gets its own height (SET-8): grouped forms have no intrinsic height.
            add(tabs, "Accounts", "person.2", AccountsTab(store: store), height: AccountsTab.height)
            add(tabs, "Notifications", "bell.badge", NotificationsTab(store: store), height: NotificationsTab.height)
            add(tabs, "Phone", "iphone", PhoneTab(store: store), height: PhoneTab.height)
            add(tabs, "General", "gearshape", GeneralTab(store: store), height: GeneralTab.height)
            if let last = UserDefaults.standard.string(forKey: DefaultsKey.settingsTab),  // reopen on the last pane (SET-3)
               let index = tabs.tabViewItems.firstIndex(where: { $0.label == last }) {
                tabs.selectedTabViewItemIndex = index
            }
            let w = NSWindow(contentViewController: tabs)
            w.styleMask = [.titled, .closable, .miniaturizable]  // keep .miniaturizable so the button dims, not vanishes
            w.title = tabs.tabViewItems[tabs.selectedTabViewItemIndex].label
            w.isReleasedWhenClosed = false
            w.standardWindowButton(.miniaturizeButton)?.isEnabled = false
            w.standardWindowButton(.zoomButton)?.isEnabled = false
            w.center()
            w.setFrameAutosaveName("SettingsWindow")
            window = w
            self.tabs = tabs
        }
        if let tab, let tabs, let index = tabs.tabViewItems.firstIndex(where: { $0.label == tab }) {
            tabs.selectedTabViewItemIndex = index
        }
        if let window { AccessoryWindows.shared.show(window) }
    }

    private func add(_ tabs: NSTabViewController, _ label: String, _ symbol: String, _ pane: some View, height: CGFloat) {
        let host = NSHostingController(rootView: pane.frame(width: 520, height: height))
        host.sizingOptions = .preferredContentSize  // the window follows the selected pane
        host.title = label
        let item = NSTabViewItem(viewController: host)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        tabs.addTabViewItem(item)
    }
}

/// Title follows the selected pane (SET-2); the pane is remembered for the next open (SET-3).
final class SettingsTabs: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard let label = tabViewItem?.label else { return }
        view.window?.title = label
        UserDefaults.standard.set(label, forKey: DefaultsKey.settingsTab)
    }
}
