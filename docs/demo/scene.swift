// PullPing demo: the app's REAL views over its own fake data. StatusPanelView (the status item popover) and NotificationContent (the top-right
// panel) are compiled from Sources/PullPing unchanged, as are Store, Fixtures, Attention and Theme; this file only draws them into bitmaps
// and composes the scenes. Nothing is ever shown on screen, no token or keychain is read, no network is touched, the installed app is never
// launched: the Store is the memory-only fixture store (Fixtures.sampleStore, persist: false).
import AppKit
import SwiftUI
import PullPingCore
@testable import PullPing

private let W = Demo.size.width, H = Demo.size.height

// MARK: - drawing a SwiftUI view into a bitmap the way a window would (AppKit controls included), transparent, at the kit's pixel scale

private final class ActiveWindow: NSWindow {  // controls draw their grey "inactive" look in a window that is not key; claim to be key
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

/// The status panel is a List (AppKit table) with a Picker and a Menu: ImageRenderer cannot draw those, so host the view in a borderless window
/// and cacheDisplay it, as the app's own ScreenshotRenderTests do.
@MainActor private func capture<V: View>(_ view: V, size: CGSize) -> CGImage {
    func settle(_ seconds: Double) { RunLoop.current.run(until: Date(timeIntervalSinceReferenceDate: CFAbsoluteTimeGetCurrent() + seconds)) }
    let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark).environment(\.controlActiveState, .key))
    let w = ActiveWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    w.appearance = NSAppearance(named: .darkAqua)
    w.isOpaque = false; w.backgroundColor = .clear
    w.contentView = host
    host.frame = CGRect(origin: .zero, size: size)
    settle(0.5)
    host.layoutSubtreeIfNeeded()
    settle(0.5)  // the table fills its rows on the next run-loop turns
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((size.width * Demo.scale).rounded()), pixelsHigh: Int((size.height * Demo.scale).rounded()),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep.cgImage!
}

private func context(_ w: Int, _ h: Int) -> CGContext {
    let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    return c
}

/// cacheDisplay paints the table's backing (one flat grey, the most common opaque colour) where a real popover shows its glass through.
/// Make exactly that colour transparent, so the kit's glass material is the popover's background from header to footer.
private func unflattened(_ img: CGImage) -> CGImage {
    let c = context(img.width, img.height)
    c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    let p = c.data!.assumingMemoryBound(to: UInt8.self), bpr = c.bytesPerRow
    var counts: [UInt32: Int] = [:]
    for y in stride(from: 0, to: img.height, by: 3) {
        for x in stride(from: 0, to: img.width, by: 3) {
            let o = y * bpr + x * 4
            if p[o + 3] == 255 { counts[UInt32(p[o]) << 16 | UInt32(p[o + 1]) << 8 | UInt32(p[o + 2]), default: 0] += 1 }
        }
    }
    guard let flat = counts.max(by: { $0.value < $1.value })?.key else { return img }
    let (fr, fg, fb) = (Int(flat >> 16), Int(flat >> 8 & 0xFF), Int(flat & 0xFF))
    for y in 0..<img.height {
        for x in 0..<img.width {
            let o = y * bpr + x * 4
            if p[o + 3] == 255, abs(Int(p[o]) - fr) <= 1, abs(Int(p[o + 1]) - fg) <= 1, abs(Int(p[o + 2]) - fb) <= 1 {
                p[o] = 0; p[o + 1] = 0; p[o + 2] = 0; p[o + 3] = 0
            }
        }
    }
    return c.makeImage()!
}

private func scaled(_ img: CGImage, by k: CGFloat) -> CGImage {
    let c = context(Int((CGFloat(img.width) * k).rounded()), Int((CGFloat(img.height) * k).rounded()))
    c.draw(img, in: CGRect(x: 0, y: 0, width: c.width, height: c.height))
    return c.makeImage()!
}

/// Centre (points, y-down) of the light pixels in the top-right corner of the notification panel: the Dismiss (xmark) button.
private func dismissButtonCenter(_ img: CGImage) -> CGPoint {
    let c = context(img.width, img.height)
    c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    let p = c.data!.assumingMemoryBound(to: UInt8.self), bpr = c.bytesPerRow
    var (minX, maxX, minY, maxY) = (Int.max, 0, Int.max, 0)
    for y in 0..<Int(34 * Demo.scale) {
        for x in Int(360 * Demo.scale)..<img.width {
            let o = y * bpr + x * 4
            if p[o + 3] == 255, Int(p[o]) + Int(p[o + 1]) + Int(p[o + 2]) > 3 * 140 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
    }
    return CGPoint(x: CGFloat(minX + maxX) / 2 / Demo.scale, y: CGFloat(minY + maxY) / 2 / Demo.scale)
}

// MARK: - fake data: the app's own Fixtures (generic "octo-org" repos, accounts "Personal" / "Work"), trimmed so the panel shows every section

/// Fixtures.swift sampleStore: eleven pull requests and issues. Keep four: mine with changes requested + failed CI (PR_2), my issue with a new
/// comment (I_1), someone else's pull request awaiting my review (PR_3, the one that "arrives"), and one I only commented on (PR_5).
@MainActor private func makeStore(arrived: Bool) -> Store {
    let store = Fixtures.sampleStore()
    let keep: Set<String> = arrived ? ["PR_2", "I_1", "PR_3", "PR_5"] : ["PR_2", "I_1", "PR_5"]
    let now = Date()  // only ever compared with Store.now a few ms later: "just now" / "now" come out the same on every render
    store.setTracked { state in
        state.prs = state.prs.filter { keep.contains($0.key) }
        // EventEngine.swift:78: a direct review request is recorded with an empty summary, so the panel reads "carol requested your review".
        state.prs["PR_3"]?.events[0].summary = ""
        if arrived {
            // Poller.swift:216 / Store.handle: the poll that delivered the request stamps lastPollAt (header "Updated just now", Theme.swift:128),
            // and the request itself is as old as that poll (row "carol requested your review · now", Theme.swift:119).
            state.lastPollAt = [Fixtures.personal.id: now, Fixtures.work.id: now]
            state.prs["PR_3"]?.events[0].at = now
            state.prs["PR_3"]?.updatedAt = now
        }
    }
    return store
}

// MARK: - status item: StatusItem.swift render() = the packaged template glyph (Assets/icons/menubar@2x.png), then the count when > 0

private func glyphSlot(_ width: CGFloat) -> String {  // reserves the glyph's width in the kit's status item; the glyph is drawn over it
    var s = ""
    while (s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width < width { s += " " }
    return s
}

private let glyph: CGImage = {  // tinted like a menu bar template image
    let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PULLPING_ASSETS"]! + "/menubar@2x.png")
    let img = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
    let ctx = context(img.width, img.height)
    let r = CGRect(x: 0, y: 0, width: img.width, height: img.height)
    ctx.draw(img, in: r); ctx.setBlendMode(.sourceIn); ctx.setFillColor(CGColor(gray: 1, alpha: 0.95)); ctx.fill(r)
    return ctx.makeImage()!
}()
private let glyphSize: CGFloat = 18  // menubar.png is 18x18 pt; NSStatusBarButton imagePosition .imageLeading, a few points before the title

@MainActor private func drawBar(_ c: Canvas, count: Int, active: Bool = false) -> CGRect {
    let text = count > 0 ? "\(count)" : ""  // StatusItem.swift: button.title = store.badgeCount > 0 ? "\(store.badgeCount)" : ""
    let f = c.menuBar(app: StatusItem(text: glyphSlot(glyphSize + (count > 0 ? 4 : 0)) + text), appActive: active)
    c.draw(glyph, in: CGRect(x: f.minX + 8, y: (Demo.barHeight - glyphSize) / 2, width: glyphSize, height: glyphSize))
    return f
}

// MARK: - scenes

@MainActor func pullPingScenes() -> [Scene] {
    let calm = makeStore(arrived: false), busy = makeStore(arrived: true)
    let before = calm.badgeCount, after = busy.badgeCount  // Store.badgeCount: what needs me (review requests, changes requested, new comments...)

    // The panel the app shows when PR_3's review request arrives: Store.show(_:) builds the model from the event, the style (alert: Settings
    // default for a review request on someone else's pull request, stays until acted on) and the account label.
    let pr3 = busy.tracked.prs["PR_3"]!
    let alert = busy.settings.style(for: .reviewRequested, mine: false) == .alert
    let model = PanelModel(pr: pr3, events: pr3.events, alert: alert, account: busy.login(for: pr3))
    let note = capture(NotificationContent(model: model, onOpen: {}, onSnooze: {}, onMute: {}, onDismiss: {}, onHover: { _ in }),
                       size: CGSize(width: Theme.panelWidth, height: Theme.panelHeight))
    let noteOrigin = CGPoint(x: W - Theme.panelWidth - 12, y: Demo.barHeight + 12)  // NotificationPanels.frame(slot: 0): 12 pt margin, top right
    let dismiss = dismissButtonCenter(note)
    let dismissAt = CGPoint(x: noteOrigin.x + dismiss.x, y: noteOrigin.y + dismiss.y)

    // The status item popover (StatusPanelView, 380 x 520 pt), once per scope. @AppStorage reads the panel's saved account: register it in memory only.
    let panelKey = DefaultsKey.panelAccount
    UserDefaults.standard.register(defaults: [panelKey: ""])
    let allImage = unflattened(capture(StatusPanelView(store: busy), size: CGSize(width: 380, height: 520)))
    UserDefaults.standard.register(defaults: [panelKey: Fixtures.work.id.uuidString])
    let workImage = unflattened(capture(StatusPanelView(store: busy), size: CGSize(width: 380, height: 520)))
    UserDefaults.standard.register(defaults: [panelKey: ""])

    // 380 x 520 pt is 87 % of the 600 pt canvas and would sit under the caption pill: draw it at 0.9 (the canvas is a scaled-down desktop anyway).
    let k: CGFloat = 0.9
    let popAll = scaled(allImage, by: k), popWork = scaled(workImage, by: k)
    let popSize = CGSize(width: CGFloat(popAll.width) / Demo.scale, height: CGFloat(popAll.height) / Demo.scale)
    let item = Canvas(background: nil).menuBar(app: StatusItem(text: glyphSlot(glyphSize + 4) + "\(after)"))
    let popOrigin = CGPoint(x: min(item.midX - popSize.width / 2, W - popSize.width - 8), y: Demo.barHeight + 6)  // NSPopover under the item, 6 pt gap
    func inPopover(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: popOrigin.x + x * k, y: popOrigin.y + y * k) }
    // StatusPanelView header, points in the unscaled panel (measured on the capture): the "Work N" segment of the account picker.
    let workSegment = inPopover(230, 80.5)
    let itemCenter = CGPoint(x: item.midX, y: Demo.barHeight / 2)
    let radius: CGFloat = 16

    // 1. the status item: the count of what needs me (before the review request)
    let s1 = Scene(name: "menu bar", duration: 2.2, caption: "A count of pull requests that need you") { _ in
        let c = Canvas()
        _ = drawBar(c, count: before)
        return c.image
    }

    // 2. the review request arrives: the count goes up and a panel fades in (NotificationPanels.add: 0.25 s fade, no slide); an alert stays until
    //    acted on. A click on its xmark dismisses it (NotificationPanels.remove: 0.15 s fade).
    let arrive = 0.40, click2 = 2.05
    let path2 = CursorPath(start: CGPoint(x: W * 0.46, y: H * 0.50), moves: [.init(t0: 1.35, t1: 1.90, to: dismissAt)], clicks: [click2])
    let s2 = Scene(name: "arrives", duration: 3.0, caption: "A review request arrives as a panel that stays") { t in
        let c = Canvas()
        _ = drawBar(c, count: t >= arrive ? after : before)
        let a = ramp(t, arrive, arrive + 0.25) * (1 - ramp(t, click2, click2 + 0.15))
        if a > 0 { c.panel(note, at: noteOrigin, radius: Theme.panelRadius, alpha: CGFloat(a)) }
        let click = path2.click(t)
        c.cursor(at: path2.position(t), alpha: CGFloat(ramp(t, 1.30, 1.50)), press: click.press, pulse: click.pulse)
        return c.image
    }

    // 3. a click on the icon opens the popover (StatusItem.togglePopover): Mine / To Review / Involved with chips; the cursor then heads for "Work"
    let open3 = 0.90
    let path3 = CursorPath(start: dismissAt, moves: [.init(t0: 0.10, t1: 0.75, to: itemCenter), .init(t0: 2.05, t1: 2.75, to: workSegment)],
                           clicks: [open3])
    let s3 = Scene(name: "panel", duration: 3.4, caption: "Mine, To Review, Involved, with CI and review state") { t in
        let c = Canvas()
        let opened = t >= open3
        _ = drawBar(c, count: after, active: opened)
        if opened { c.panel(popAll, at: popOrigin, radius: radius, alpha: CGFloat(ramp(t, open3, open3 + 0.12))) }
        let click = path3.click(t)
        c.cursor(at: path3.position(t), alpha: 1, press: click.press, pulse: click.pulse)
        return c.image
    }

    // 4. the account picker: "Work" shows only that account's pull requests (StatusPanelView.scopePicker); a click outside closes the popover
    let pick = 0.35, away = 1.95
    let path4 = CursorPath(start: workSegment, moves: [.init(t0: 1.35, t1: 1.85, to: CGPoint(x: W * 0.30, y: H * 0.60))], clicks: [pick, away])
    let s4 = Scene(name: "accounts", duration: 2.8, caption: "Switch between your personal and work accounts") { t in
        let c = Canvas()
        let open = 1 - ramp(t, away, away + 0.12)
        _ = drawBar(c, count: after, active: open > 0)
        if open > 0 { c.panel(t >= pick ? popWork : popAll, at: popOrigin, radius: radius, alpha: CGFloat(open)) }
        let click = path4.click(t)
        c.cursor(at: path4.position(t), alpha: CGFloat(1 - ramp(t, away + 0.15, away + 0.40)), press: click.press, pulse: click.pulse)
        return c.image
    }
    return [s1, s2, s3, s4]
}

@main struct PullPingDemo {
    @MainActor static func main() { Demo.run(scenes: pullPingScenes()) }
}
