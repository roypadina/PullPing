import Foundation

/// Status panel sections; a PR is in exactly one, checked in this order.
public enum PRGroup: String, Sendable, CaseIterable { case mine, toReview, involved }

/// Why a pull request needs me, in breakdown order; the raw value is the breakdown wording.
public enum NeedReason: String, Sendable, CaseIterable {
    case toReview = "to review", changesRequested = "changes requested", ciFailed = "CI failed", mentioned
    case newComments = "with new comments", readyToMerge = "ready to merge"
}

public enum Attention {
    /// Events by others newer than the last read. Baseline marks everything read (Poller).
    public static func unread(_ pr: TrackedPR) -> Int {
        pr.events.filter { !$0.isOwn && $0.at > (pr.lastReadAt ?? .distantPast) }.count
    }

    public static func awaitingMyReview(_ pr: TrackedPR) -> Bool {
        pr.state == .open && !pr.isDraft && !pr.roles.isDisjoint(with: [.reviewRequested, .teamReviewRequested])
    }

    public static func isAttention(_ pr: TrackedPR) -> Bool {
        !pr.muted && !pr.hidden && (unread(pr) > 0 || awaitingMyReview(pr))
    }

    /// Open, shown, unmuted, and: my review is awaited, an unread mention, or I'm the author and it has changes requested,
    /// failed CI, unread comments or reviews, or is ready to merge. The first match wins, so each counts once.
    public static func needReason(_ pr: TrackedPR) -> NeedReason? {
        guard pr.state == .open, !pr.muted, !pr.hidden else { return nil }
        let unread = pr.events.filter { !$0.isOwn && $0.at > (pr.lastReadAt ?? .distantPast) }
        let mine = pr.roles.contains(.author)
        if awaitingMyReview(pr) { return .toReview }
        if mine && pr.reviewDecision == "CHANGES_REQUESTED" { return .changesRequested }
        if mine && pr.ci == .failure { return .ciFailed }
        if unread.contains(where: { $0.kind == .mentioned }) { return .mentioned }
        let talk: Set<EventKind> = [.comment, .reviewApproved, .reviewChangesRequested, .reviewCommented]
        if mine && unread.contains(where: { talk.contains($0.kind) }) { return .newComments }
        if mine && pr.reviewDecision == "APPROVED" && pr.ci == .success && pr.mergeState == "CLEAN" { return .readyToMerge }
        return nil
    }

    public static func needsMe(_ pr: TrackedPR) -> Bool { needReason(pr) != nil }

    /// "2 to review · 1 ready to merge"; empty when nothing needs me.
    public static func breakdown(_ prs: [TrackedPR]) -> String {
        let reasons = prs.compactMap(needReason)
        return NeedReason.allCases.compactMap { reason in
            let count = reasons.filter { $0 == reason }.count
            return count > 0 ? "\(count) \(reason.rawValue)" : nil
        }.joined(separator: " · ")
    }

    public static func badgeCount(_ prs: [TrackedPR], enabledAccounts: Set<UUID>, mode: BadgeMode = .allUnread) -> Int {
        let prs = prs.filter { enabledAccounts.contains($0.accountID) }
        switch mode {
        case .needsMe: return prs.filter(needsMe).count
        case .allUnread: return prs.filter(isAttention).count
        case .off: return 0
        }
    }

    public static func group(_ pr: TrackedPR) -> PRGroup {
        if pr.roles.contains(.author) { return .mine }
        return awaitingMyReview(pr) ? .toReview : .involved
    }
}
