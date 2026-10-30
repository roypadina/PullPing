import AppKit
import PullPingCore
import SwiftUI

/// One dynamic colour from a light/dark pair: flips with the appearance like the system's semantic colours.
private func dyn(light: NSColor, dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) {
        $0.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
            .map { $0 == .darkAqua || $0 == .accessibilityHighContrastDarkAqua } == true ? dark : light
    })
}

private func rgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// Signal hues. Light variants are deep (≥ 6:1 on #ECECEC), dark variants bright (≥ 5:1 on dark material),
/// so they pass as text at caption size. State is never carried by colour alone: every use has a symbol and a word.
enum Theme {
    static let needsYou = dyn(light: rgb(0x7D4E00), dark: rgb(0xE3A93A))  // amber
    static let good = dyn(light: rgb(0x116329), dark: rgb(0x46C35A))      // green
    static let bad = dyn(light: rgb(0xA40E26), dark: rgb(0xFF6B61))       // red
    static let merged = dyn(light: rgb(0x6639BA), dark: rgb(0xB48CFA))    // purple
    static let neutral = Color.secondary
    /// Text on a filled signal button: white on the deep light fills, ink on the bright dark fills.
    static let onSignal = dyn(light: .white, dark: rgb(0x0D1117))

    static let panelWidth: CGFloat = 420
    static let panelHeight: CGFloat = 112
    static let panelRadius: CGFloat = 16
    static let rimWidth: CGFloat = 4
}

extension EventKind {
    /// (Settings label and panel kind word, row verb, symbol, hue).
    private var look: (label: String, verb: String, symbol: String, hue: Color) {
        switch self {
        case .comment: ("Comment added", "commented", "bubble.left", Theme.neutral)
        case .mentioned: ("Mentioned", "mentioned you", "at", Theme.needsYou)
        case .reviewApproved: ("Review approved", "approved", "checkmark.circle", Theme.good)
        case .reviewChangesRequested: ("Changes requested", "requested changes", "exclamationmark.bubble", Theme.bad)
        case .reviewCommented: ("Review comments", "reviewed", "text.bubble", Theme.neutral)
        case .reviewRequested: ("Review requested", "requested your review", "person.crop.circle.badge.exclamationmark", Theme.needsYou)
        case .assigned: ("Assigned to me", "assigned you", "person.crop.circle.badge.checkmark", Theme.needsYou)
        case .newCommits: ("New commits", "pushed commits", "arrow.triangle.branch", Theme.neutral)
        case .ciPassed: ("CI passed", "CI passed", "checkmark.seal", Theme.good)
        case .ciFailed: ("CI failed", "CI failed", "xmark.octagon", Theme.bad)
        case .readyForReview: ("Ready for review", "marked ready", "eye", Theme.neutral)
        case .convertedToDraft: ("Converted to draft", "converted to draft", "pencil.circle", Theme.neutral)
        case .merged: ("Merged", "merged", "arrow.triangle.merge", Theme.merged)
        case .closed: ("Closed", "closed", "xmark.circle", Theme.neutral)
        case .reopened: ("Reopened", "reopened", "arrow.uturn.left.circle", Theme.neutral)
        case .reviewDismissed: ("Review dismissed", "dismissed a review", "hand.raised.slash", Theme.neutral)
        case .retitled: ("Title changed", "renamed", "pencil", Theme.neutral)
        case .labeled: ("Labels changed", "changed labels", "tag", Theme.neutral)
        case .reviewReminder: ("Reminder: review requested", "reminder", "bell.badge", Theme.needsYou)
        }
    }

    var label: String { look.label }
    var verb: String { look.verb }
    var symbol: String { look.symbol }
    var hue: Color { look.hue }
}

/// Small capsule: symbol in the hue plus a word, so the state never rests on colour.
struct Chip: View {
    let text: String
    let symbol: String
    var tint: Color = Theme.neutral

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            Text(text).lineLimit(1)
        }
        .font(.caption)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }
}

extension TrackedPR {
    /// Issue, state, review decision, CI and muted chips, in reading order. Pull requests carry no kind chip.
    var chips: [Chip] {
        var chips: [Chip] = []
        if isIssue { chips.append(Chip(text: "Issue", symbol: "smallcircle.filled.circle")) }
        switch state {
        case .merged: chips.append(Chip(text: "Merged", symbol: "arrow.triangle.merge", tint: Theme.merged))
        case .closed where isIssue && stateReason == "COMPLETED": chips.append(Chip(text: "Completed", symbol: "checkmark.circle", tint: Theme.merged))
        case .closed where isIssue && stateReason == "NOT_PLANNED": chips.append(Chip(text: "Not planned", symbol: "slash.circle"))
        case .closed: chips.append(Chip(text: "Closed", symbol: "xmark.circle"))
        case .open: if isDraft { chips.append(Chip(text: "Draft", symbol: "circle.dashed")) }
        }
        switch reviewDecision {
        case "APPROVED": chips.append(Chip(text: "Approved", symbol: "checkmark.circle", tint: Theme.good))
        case "CHANGES_REQUESTED": chips.append(Chip(text: "Changes requested", symbol: "exclamationmark.bubble", tint: Theme.bad))
        case "REVIEW_REQUIRED" where state == .open: chips.append(Chip(text: "Review required", symbol: "eye"))
        default: break
        }
        switch ci {
        case .success: chips.append(Chip(text: "CI passed", symbol: "checkmark.circle", tint: Theme.good))
        case .failure: chips.append(Chip(text: "CI failed", symbol: "xmark.circle", tint: Theme.bad))
        case .pending: chips.append(Chip(text: "CI running", symbol: "circle.dotted", tint: Theme.needsYou))
        case .none: break
        }
        if muted { chips.append(Chip(text: "Muted", symbol: "bell.slash")) }
        return chips
    }
}

extension PREvent {
    /// "alice approved"; CI events (actor "CI") read "CI failed".
    var line: String { actor == "CI" ? kind.verb : "\(actor) \(kind.verb)" }
}

/// "now", "5m", "2h", "3d": row trailing times.
func shortAge(_ date: Date, now: Date) -> String {
    let s = max(0, now.timeIntervalSince(date))
    return s < 60 ? "now" : s < 3600 ? "\(Int(s / 60))m" : s < 86_400 ? "\(Int(s / 3600))h" : "\(Int(s / 86_400))d"
}

/// "2 min. ago": header and subtitle freshness.
func relativeAge(_ date: Date, now: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return now.timeIntervalSince(date) < 60 ? "just now" : formatter.localizedString(for: date, relativeTo: now)
}
