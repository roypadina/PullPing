import Foundation

/// Status panel sections; a PR is in exactly one, checked in this order.
public enum PRGroup: String, Sendable, CaseIterable { case mine, toReview, involved }

/// Why a pull request needs me, in breakdown order; the raw value is the breakdown wording.
public enum NeedReason: String, Codable, Sendable, CaseIterable {
    case toReview = "to review", teamToReview = "team review", changesRequested = "changes requested", ciFailed = "CI failed"
    case mentioned, newComments = "with new comments", readyToMerge = "ready to merge"
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

    /// Open, shown, unmuted, and: my review is awaited (directly or via a team), an unread mention, or I'm the author and it
    /// has changes requested, failed CI, unread comments or reviews, or is ready to merge. Only reasons in `counting`
    /// (Settings > General) apply; the first match wins, so each pull request counts once.
    public static func needReason(_ pr: TrackedPR, counting: Set<NeedReason> = Set(NeedReason.allCases)) -> NeedReason? {
        guard pr.state == .open, !pr.muted, !pr.hidden else { return nil }
        let unread = pr.events.filter { !$0.isOwn && $0.at > (pr.lastReadAt ?? .distantPast) }
        let mine = pr.roles.contains(.author), reviewable = !pr.isDraft
        let talk: Set<EventKind> = [.comment, .reviewApproved, .reviewChangesRequested, .reviewCommented]
        let checks: [(NeedReason, Bool)] = [
            (.toReview, reviewable && pr.roles.contains(.reviewRequested)),
            (.teamToReview, reviewable && pr.roles.contains(.teamReviewRequested)),
            (.changesRequested, mine && pr.reviewDecision == "CHANGES_REQUESTED"),
            (.ciFailed, mine && pr.ci == .failure),
            (.mentioned, unread.contains { $0.kind == .mentioned }),
            (.newComments, mine && unread.contains { talk.contains($0.kind) }),
            (.readyToMerge, mine && pr.reviewDecision == "APPROVED" && pr.ci == .success && pr.mergeState == "CLEAN"),
        ]
        return checks.first { counting.contains($0.0) && $0.1 }?.0
    }

    public static func needsMe(_ pr: TrackedPR, counting: Set<NeedReason> = Set(NeedReason.allCases)) -> Bool {
        needReason(pr, counting: counting) != nil
    }

    /// "2 to review · 1 ready to merge"; empty when nothing needs me.
    public static func breakdown(_ prs: [TrackedPR], counting: Set<NeedReason> = Set(NeedReason.allCases)) -> String {
        let reasons = prs.compactMap { needReason($0, counting: counting) }
        return NeedReason.allCases.compactMap { reason in
            let count = reasons.filter { $0 == reason }.count
            return count > 0 ? "\(count) \(reason.rawValue)" : nil
        }.joined(separator: " · ")
    }

    public static func badgeCount(_ prs: [TrackedPR], enabledAccounts: Set<UUID>, mode: BadgeMode = .allUnread,
                                  counting: Set<NeedReason> = Set(NeedReason.allCases)) -> Int {
        let prs = prs.filter { enabledAccounts.contains($0.accountID) }
        switch mode {
        case .needsMe: return prs.filter { needsMe($0, counting: counting) }.count
        case .allUnread: return prs.filter(isAttention).count
        case .off: return 0
        }
    }

    /// Nothing left for me: merged or closed, or open and not mine, not assigned to me, no review asked of me or my team,
    /// nothing unread. Ignores the badge settings, so a switched-off reason never moves a request into Done.
    public static func isDone(_ pr: TrackedPR) -> Bool {
        guard pr.state == .open else { return true }
        return pr.roles.isDisjoint(with: [.author, .assigned, .reviewRequested, .teamReviewRequested])
            && unread(pr) == 0 && !awaitingMyReview(pr)
    }

    /// Latest of updated, closed and the newest event.
    public static func lastActivity(_ pr: TrackedPR) -> Date {
        max(pr.updatedAt, pr.closedAt ?? .distantPast, pr.events.map(\.at).max() ?? .distantPast)
    }

    /// The one list order: needs me, then unread (`isAttention`), then latest activity; ties by number, highest first.
    /// Done pull requests rank by activity alone.
    public static func sorted(_ prs: [TrackedPR], counting: Set<NeedReason> = Set(NeedReason.allCases)) -> [TrackedPR] {
        prs.map { pr -> (TrackedPR, (Int, Date, Int, String)) in
            let rank = isDone(pr) ? 0 : needsMe(pr, counting: counting) ? 2 : isAttention(pr) ? 1 : 0
            return (pr, (rank, lastActivity(pr), pr.number, pr.id))  // id: a stable order when numbers tie across repos
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    public static func group(_ pr: TrackedPR) -> PRGroup {
        if pr.roles.contains(.author) { return .mine }
        return awaitingMyReview(pr) ? .toReview : .involved
    }
}
