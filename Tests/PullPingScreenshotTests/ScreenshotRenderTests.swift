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
            store.filter = nil  // an offscreen sidebar selection renders as a black bar
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
            try save("settings-accounts", AccountsTab(store: store), NSSize(width: 520, height: AccountsTab.height))
            try save("settings-notifications", NotificationsTab(store: store), NSSize(width: 520, height: NotificationsTab.height))
            try save("settings-general", GeneralTab(store: store), NSSize(width: 520, height: GeneralTab.height))
        }
    }

    /// The panel on a plain backdrop with room for its edge.
    private func panel(_ model: PanelModel) -> some View {
        NotificationContent(model: model, onOpen: {}, onSnooze: {}, onMute: {}, onDismiss: {}, onHover: { _ in })
            .padding(20)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    private func render(_ view: some View, size: NSSize, dark: Bool, to url: URL) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))  // cacheDisplay skips the window background
            .environment(\.controlActiveState, .key))
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
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
