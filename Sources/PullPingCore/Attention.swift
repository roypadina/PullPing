import Foundation

/// Status panel sections; a PR is in exactly one, checked in this order.
public enum PRGroup: String, Sendable, CaseIterable { case mine, toReview, involved }

public enum Attention {
    /// Events by others newer than the last read. Baseline marks everything read (Poller).
    public static func unread(_ pr: TrackedPR) -> Int {
        pr.events.filter { !$0.isOwn && $0.at > (pr.lastReadAt ?? .distantPast) }.count
    }

    public static func awaitingMyReview(_ pr: TrackedPR) -> Bool {
        pr.state == .open && !pr.isDraft && !pr.roles.isDisjoint(with: [.reviewRequested, .teamReviewRequested])
    }

    public static func isAttention(_ pr: TrackedPR) -> Bool {
        !pr.muted && (unread(pr) > 0 || awaitingMyReview(pr))
    }

    public static func badgeCount(_ prs: [TrackedPR], enabledAccounts: Set<UUID>) -> Int {
        prs.filter { enabledAccounts.contains($0.accountID) && isAttention($0) }.count
    }

    public static func group(_ pr: TrackedPR) -> PRGroup {
        if pr.roles.contains(.author) { return .mine }
        return awaitingMyReview(pr) ? .toReview : .involved
    }
}
