import AppKit
import PullPingCore
import SwiftUI

/// One dynamic colour from a light/dark pair: flips with the appearance like the system's semantic colours.
/// Increase Contrast uses the `hc` variants when given, else the pair.
private func dyn(light: NSColor, dark: NSColor, hcLight: NSColor? = nil, hcDark: NSColor? = nil) -> Color {
    Color(nsColor: NSColor(name: nil) {
        switch $0.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
        case .darkAqua: dark
        case .accessibilityHighContrastAqua: hcLight ?? light
        case .accessibilityHighContrastDarkAqua: hcDark ?? dark
        default: light
        }
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
    /// Ko-fi red, the support card's Tip button (MeetAlert's values).
    static let kofi = dyn(light: rgb(0xC8302D), dark: rgb(0xFF5E5B), hcLight: rgb(0xA32320), hcDark: rgb(0xFF8783))
    /// The support card's base tint over `.regularMaterial`: navy ink, not neutral black.
    static let cardInk = dyn(light: NSColor(white: 1, alpha: 0.45), dark: NSColor(srgbRed: 0.05, green: 0.07, blue: 0.13, alpha: 0.55))

    static let panelWidth: CGFloat = 420
    static let panelHeight: CGFloat = 112
    static let panelRadius: CGFloat = 16
    static let rimWidth: CGFloat = 4
}

extension EventKind {
    /// (Row verb, symbol, hue). The Settings label and panel kind word, `label`, is in Core.
    private var look: (verb: String, symbol: String, hue: Color) {
        switch self {
        case .comment: ("commented", "bubble.left", Theme.neutral)
        case .mentioned: ("mentioned you", "at", Theme.needsYou)
        case .reviewApproved: ("approved", "checkmark.circle", Theme.good)
        case .reviewChangesRequested: ("requested changes", "exclamationmark.bubble", Theme.bad)
        case .reviewCommented: ("reviewed", "text.bubble", Theme.neutral)
        case .reviewRequested: ("requested your review", "person.crop.circle.badge.exclamationmark", Theme.needsYou)
        case .assigned: ("assigned you", "person.crop.circle.badge.checkmark", Theme.needsYou)
        case .newCommits: ("pushed commits", "arrow.triangle.branch", Theme.neutral)
        case .ciPassed: ("CI passed", "checkmark.seal", Theme.good)
        case .ciFailed: ("CI failed", "xmark.octagon", Theme.bad)
        case .readyForReview: ("marked ready", "eye", Theme.neutral)
        case .convertedToDraft: ("converted to draft", "pencil.circle", Theme.neutral)
        case .merged: ("merged", "arrow.triangle.merge", Theme.merged)
        case .closed: ("closed", "xmark.circle", Theme.neutral)
        case .reopened: ("reopened", "arrow.uturn.left.circle", Theme.neutral)
        case .reviewDismissed: ("dismissed a review", "hand.raised.slash", Theme.neutral)
        case .retitled: ("renamed", "pencil", Theme.neutral)
        case .labeled: ("changed labels", "tag", Theme.neutral)
        case .reviewReminder: ("reminder", "bell.badge", Theme.needsYou)
        case .conflicts: ("Conflicts with base", "exclamationmark.triangle", Theme.bad)
        case .readyToMerge: ("Ready to merge", "checkmark.circle", Theme.good)
        case .reminder: ("reminded you", "alarm", Theme.needsYou)
        case .issueOpened: ("opened this issue", "plus.circle", Theme.needsYou)
        }
    }

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

/// "Something here is new": the one dot of list rows, sidebar rows, account headers and collapsed sections. Accent colour,
/// white on an emphasized selection (it would vanish into the accent there); labelled, so it never rests on colour.
struct NewDot: View {
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Circle().fill(prominence == .increased ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
            .frame(width: 6, height: 6)
            .accessibilityLabel("New")
    }
}

extension Attention.Lead.Tone {
    var color: Color {
        switch self {
        case .needsYou: Theme.needsYou
        case .good: Theme.good
        case .bad: Theme.bad
        case .merged: Theme.merged
        case .neutral: Theme.neutral
        }
    }
}

extension TrackedPR {
    /// Issue, the status chip of its bucket (`Attention.lead`), the reminder, Draft, CI and Muted, in reading order.
    var chips: [Chip] {
        var chips: [Chip] = []
        if isIssue { chips.append(Chip(text: "Issue", symbol: "smallcircle.filled.circle")) }
        let lead = Attention.lead(self)
        if let lead { chips.append(Chip(text: lead.text, symbol: lead.symbol, tint: lead.tone.color)) }
        if Attention.reminderDue(self) {
            chips.append(Chip(text: "Reminder", symbol: "alarm", tint: Theme.needsYou))
        } else if let remindAt {
            chips.append(Chip(text: "Remind " + Remind.label(remindAt, now: Date()), symbol: "alarm"))
        }
        if state == .open && isDraft && Attention.bucket(self) != .draft { chips.append(Chip(text: "Draft", symbol: "circle.dashed")) }
        if state == .open && !(lead?.text.hasPrefix("CI") ?? false) {  // the status chip may already be about CI
            switch ci {
            case .success: chips.append(Chip(text: "CI passed", symbol: "checkmark.circle", tint: Theme.good))
            case .failure: chips.append(Chip(text: "CI failed", symbol: "xmark.circle", tint: Theme.bad))
            case .pending: chips.append(Chip(text: "CI running", symbol: "circle.dotted", tint: Theme.needsYou))
            case .none: break
            }
        }
        if muted { chips.append(Chip(text: "Muted", symbol: "bell.slash")) }
        return chips
    }
}

extension NeedReason {
    /// A notification panel's title: what the event asks of me.
    var panelTitle: String {
        switch self {
        case .toReview: "Review requested"
        case .reReview: "Re-review needed"
        case .changesRequested: "Changes requested"
        case .ciFailed: "CI failed"
        case .conflicts: "Conflicts with base"
        case .toTriage: "New issue"
        case .mentioned: "Mentioned"
        case .assigned: "Assigned to you"
        case .newComments: "New comments"
        case .readyToMerge: "Ready to merge"
        case .teamToReview: "Team review requested"
        case .reminder: "Reminder"
        }
    }

    /// A notification panel's symbol and hue: amber for a turn, red for something broken, green for ready.
    var look: (symbol: String, hue: Color) {
        switch self {
        case .toReview: ("eye", Theme.needsYou)
        case .reReview: ("arrow.triangle.2.circlepath", Theme.needsYou)
        case .teamToReview: ("person.3", Theme.needsYou)
        case .changesRequested: ("exclamationmark.bubble", Theme.bad)
        case .ciFailed: ("xmark.octagon", Theme.bad)
        case .conflicts: ("exclamationmark.triangle", Theme.bad)
        case .toTriage: ("plus.circle", Theme.needsYou)
        case .mentioned: ("at", Theme.needsYou)
        case .assigned: ("person.crop.circle.badge.checkmark", Theme.needsYou)
        case .newComments: ("bubble.left", Theme.needsYou)
        case .readyToMerge: ("checkmark.circle", Theme.good)
        case .reminder: ("alarm", Theme.needsYou)
        }
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
