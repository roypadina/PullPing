import Foundation

/// Which events ask something of me. Pure, evaluated on the pull request as it is after the refresh.
public enum Notify {
    /// The reason an event pops a panel, or nil: Activity only (merges, CI passed, new commits I don't have to re-review,
    /// labels, comments on others' pull requests without a mention…). Muting, snoozing and styles come after (`Quiet`).
    public static func reason(_ event: PREvent, pr: TrackedPR) -> NeedReason? {
        guard !event.isOwn else { return nil }
        let bucket = Attention.bucket(pr)
        let mine = pr.roles.contains(.author) || (pr.isIssue && pr.roles.contains(.assigned))
        switch event.kind {
        case .reviewRequested: return event.summary.hasPrefix("via team") ? .teamToReview : pr.myReview != nil ? .reReview : .toReview
        case .reviewReminder: return bucket == .teamReview ? .teamToReview : bucket == .reReview ? .reReview : .toReview
        case .readyForReview: return bucket == .review ? .toReview : bucket == .reReview ? .reReview : nil
        case .newCommits, .reviewDismissed: return bucket == .reReview ? .reReview : nil
        case .reviewChangesRequested where mine: return .changesRequested
        case .ciFailed where mine: return .ciFailed
        case .conflicts where mine: return .conflicts
        case .comment where mine, .reviewCommented where mine: return .newComments
        case .reviewApproved where mine, .ciPassed where mine, .readyToMerge where mine: return bucket == .merge ? .readyToMerge : nil
        case .mentioned: return .mentioned
        case .assigned: return .assigned
        case .reminder: return .reminder
        default: return nil
        }
    }
}
