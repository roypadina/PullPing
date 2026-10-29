import AppKit
import SwiftUI

/// Real windows from a menu-bar-only app (MBX-15): Dock icon and menu bar while one is open, back to
/// `.accessory` when the last one closes. Notification panels can't become main, so they don't count.
@MainActor
final class AccessoryWindows: NSObject, NSWindowDelegate {
    static let shared = AccessoryWindows()
    /// The Store's manager, so Edit > Undo reaches Stop Tracking and Reset Ignored from any window.
    var undoManager: UndoManager?

    func show(_ window: NSWindow) {
        StatusItem.shared.closePopover()  // every window entry point: status panel, menus, links, Welcome
        window.delegate = self
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        let others = NSApp.windows.contains { $0 !== closing && $0.isVisible && $0.canBecomeMain }
        if !others { NSApp.setActivationPolicy(.accessory) }
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { undoManager }
}

/// The main window: AppKit-hosted so it opens from the status panel, the URL scheme and a Finder reopen
/// without a SwiftUI scene. Closing keeps the window (`isReleasedWhenClosed = false`), so it reopens as left.
@MainActor
final class MainWindow {
    static let shared = MainWindow()
    var store: Store?  // set once at launch
    private var window: NSWindow?

    func show(select id: String? = nil) {
        guard let store else { return }
        if let id { store.reveal(id) }
        if window == nil {
            let host = NSHostingController(rootView: MainView(store: store))
            host.sceneBridgingOptions = [.toolbars, .title]  // SwiftUI .toolbar / .navigationTitle drive the NSWindow
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.toolbarStyle = .unified
            w.title = "Pull Requests"
            w.isReleasedWhenClosed = false
            w.contentMinSize = NSSize(width: 900, height: 520)
            w.setContentSize(NSSize(width: 1100, height: 680))
            w.center()
            w.setFrameAutosaveName("MainWindow")
            window = w
        }
        if let window { AccessoryWindows.shared.show(window) }
    }
}
