import Foundation

/// Why a pull request or issue needs me, in priority order (`needReason`, `sorted`, `breakdown`); the raw value is the
/// breakdown wording and the stored key, so it never changes.
public enum NeedReason: String, Codable, Sendable, CaseIterable, CodingKeyRepresentable {
    case toReview = "to review", reReview = "to re-review", changesRequested = "changes requested", ciFailed = "CI failed"
    case conflicts = "with conflicts", mentioned, assigned, newComments = "with new comments", readyToMerge = "ready to merge"
    case teamToReview = "team review"
}

/// Where a tracked item lives: whose turn it is. Exactly one per item (`Attention.bucket`); hidden and muted are flags, not buckets.
public enum Bucket: String, Sendable, CaseIterable {
    /// My pull requests. Your turn: `fix`, `merge`. Waiting on others: `waitingReview`, `waitingCI`, `waitingMerge`. And `draft`.
    case fix, merge, waitingReview, waitingCI, waitingMerge, draft
    /// Others' pull requests. Needs your review: `review`, `reReview`. Then `teamReview`, `reviewed`.
    case review, reReview, teamReview, reviewed
    case issueAssigned, issueMine, issueMentioned
    /// Open, not mine, no review role (commented, mentioned, assigned); merged or closed.
    case watching, closed
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

    /// `reviewDecision`, else (no required reviews) the reviewers' latest deciding reviews: any change request, else any approval.
    public static func decision(_ pr: TrackedPR) -> String? {
        pr.reviewDecision ?? (pr.reviewers.contains { $0.state == "CHANGES_REQUESTED" } ? "CHANGES_REQUESTED"
            : pr.reviewers.contains { $0.state == "APPROVED" } ? "APPROVED" : nil)
    }

    /// The head moved since my review (a nil commit, gone after a force-push, counts as moved). False when I never reviewed.
    public static func movedSinceMyReview(_ pr: TrackedPR) -> Bool {
        pr.myReview.map { $0.commitOID != pr.headOID } ?? false
    }

    static func ciOK(_ pr: TrackedPR) -> Bool { pr.ci == .success || pr.ci == .none }

    /// Conflicts with the base branch, or approved and green but behind it under strict protection: the author's move.
    public static func conflicted(_ pr: TrackedPR) -> Bool {
        pr.mergeState == "DIRTY" || (pr.mergeState == "BEHIND" && decision(pr) == "APPROVED" && ciOK(pr))
    }

    /// Whose turn: the first matching rule wins (0.7.0 design §3.3). Reads only stored state, so it is the same everywhere.
    public static func bucket(_ pr: TrackedPR) -> Bucket {
        guard pr.state == .open else { return .closed }
        let roles = pr.roles
        if pr.isIssue { return roles.contains(.assigned) ? .issueAssigned : roles.contains(.author) ? .issueMine : .issueMentioned }
        if roles.contains(.author) {
            let decision = decision(pr)
            if pr.isDraft { return .draft }
            if decision == "CHANGES_REQUESTED" || pr.ci == .failure || conflicted(pr) { return .fix }
            if pr.autoMerge == true { return .waitingMerge }
            if decision == "APPROVED" && ciOK(pr) && ["CLEAN", "HAS_HOOKS"].contains(pr.mergeState) { return .merge }
            let noRequests = !pr.reviewers.contains(where: \.requested) && pr.requestedTeams.isEmpty
            if pr.ci == .pending && (decision == "APPROVED" || (decision == nil && noRequests)) { return .waitingCI }
            return .waitingReview
        }
        if !pr.isDraft {
            if roles.contains(.reviewRequested) { return pr.myReview == nil ? .review : .reReview }
            if ["CHANGES_REQUESTED", "DISMISSED"].contains(pr.myReview?.state), movedSinceMyReview(pr) { return .reReview }
            if roles.contains(.teamReviewRequested) { return .teamReview }
        }
        return pr.myReview != nil || roles.contains(.reviewer) ? .reviewed : .watching
    }

    /// A row's status chip: what the item waits on, in words (0.7.0 design §5.2). `symbol` is an SF Symbol name.
    public struct Lead: Equatable, Sendable {
        public enum Tone: Sendable { case needsYou, good, bad, merged, neutral }
        public var text: String, symbol: String, tone: Tone
    }

    /// The status chip of an item's bucket; nil for open issues and Watching (their other chips say enough).
    public static func lead(_ pr: TrackedPR) -> Lead? {
        let requester = pr.events.last { $0.kind == .reviewRequested && !$0.summary.hasPrefix("via team") }?.actor ?? pr.authorLogin
        switch bucket(pr) {
        case .review: return Lead(text: "Review requested by @\(requester)", symbol: "eye", tone: .needsYou)
        case .reReview where pr.roles.contains(.reviewRequested):
            return Lead(text: "Re-review requested by @\(requester)", symbol: "arrow.triangle.2.circlepath", tone: .needsYou)
        case .reReview:
            let pushes = pr.events.filter { $0.kind == .newCommits && $0.at > (pr.myReview?.submittedAt ?? .distantPast) }.count
            return Lead(text: pushes == 0 ? "Re-review · updated since your review" : "Re-review · \(pushes) push\(pushes == 1 ? "" : "es") since your review",
                        symbol: "arrow.triangle.2.circlepath", tone: .needsYou)
        case .teamReview:
            return Lead(text: pr.requestedTeams.first.map { "Requested from team \($0)" } ?? "Requested from your team", symbol: "person.3", tone: .neutral)
        case .reviewed:
            let since = movedSinceMyReview(pr) ? " · updated since" : ""
            switch pr.myReview?.state {
            case "APPROVED": return Lead(text: "You approved" + since, symbol: "checkmark.circle", tone: .good)
            case "CHANGES_REQUESTED":
                return Lead(text: "You requested changes · waiting on @\(pr.authorLogin)" + since, symbol: "exclamationmark.bubble", tone: .neutral)
            case "DISMISSED": return Lead(text: "Your review was dismissed" + since, symbol: "hand.raised.slash", tone: .neutral)
            case "COMMENTED": return Lead(text: "You commented" + since, symbol: "text.bubble", tone: .neutral)
            default: return Lead(text: "You reviewed", symbol: "text.bubble", tone: .neutral)
            }
        case .fix:
            if decision(pr) == "CHANGES_REQUESTED" {
                let by = pr.reviewers.first { $0.state == "CHANGES_REQUESTED" }.map { " by @\($0.login)" } ?? ""
                return Lead(text: "Changes requested" + by, symbol: "exclamationmark.bubble", tone: .bad)
            }
            if pr.ci == .failure {
                let check = pr.checks.first { $0.state == .failure }.map { ": \($0.name)" } ?? ""
                return Lead(text: "CI failed" + check, symbol: "xmark.circle", tone: .bad)
            }
            return pr.mergeState == "DIRTY" ? Lead(text: "Conflicts with base", symbol: "exclamationmark.triangle", tone: .bad)
                : Lead(text: "Behind base: update branch", symbol: "arrow.down.circle", tone: .bad)
        case .merge: return Lead(text: "Approved · Ready to merge", symbol: "checkmark.circle", tone: .good)
        case .waitingReview:
            if decision(pr) == "APPROVED" { return Lead(text: "Approved · not mergeable yet", symbol: "clock", tone: .neutral) }
            let waiting = pr.reviewers.filter(\.requested).map { "@\($0.login)" } + pr.requestedTeams.map { "@\($0)" }
            return Lead(text: waiting.isEmpty ? "Waiting for review" : "Waiting on " + waiting.joined(separator: ", "), symbol: "clock", tone: .neutral)
        case .waitingCI: return Lead(text: "CI running", symbol: "circle.dotted", tone: .neutral)
        case .waitingMerge: return Lead(text: "Auto-merge on", symbol: "arrow.triangle.merge", tone: .neutral)
        case .draft: return Lead(text: "Draft", symbol: "circle.dashed", tone: .neutral)
        case .closed:
            if pr.state == .merged { return Lead(text: "Merged", symbol: "arrow.triangle.merge", tone: .merged) }
            if pr.isIssue && pr.stateReason == "COMPLETED" { return Lead(text: "Completed", symbol: "checkmark.circle", tone: .merged) }
            if pr.isIssue && pr.stateReason == "NOT_PLANNED" { return Lead(text: "Not planned", symbol: "slash.circle", tone: .neutral) }
            return Lead(text: "Closed", symbol: "xmark.circle", tone: .neutral)
        case .issueAssigned, .issueMine, .issueMentioned, .watching: return nil
        }
    }

    /// Why an open, shown, unmuted item needs me, from its bucket, plus unread mentions, assignments and (my pull requests and
    /// issues, or issues assigned to me) unread comments or reviews. Only reasons in `counting` (Settings > General) apply;
    /// the first match in `NeedReason` order wins, so each item counts once.
    public static func needReason(_ pr: TrackedPR, counting: Set<NeedReason> = Set(NeedReason.allCases)) -> NeedReason? {
        guard pr.state == .open, !pr.muted, !pr.hidden else { return nil }
        let unread = pr.events.filter { !$0.isOwn && $0.at > (pr.lastReadAt ?? .distantPast) }
        let mine = pr.roles.contains(.author) || (pr.isIssue && pr.roles.contains(.assigned)), bucket = bucket(pr)
        let talk: Set<EventKind> = [.comment, .reviewApproved, .reviewChangesRequested, .reviewCommented]
        let checks: [(NeedReason, Bool)] = [
            (.toReview, bucket == .review),
            (.reReview, bucket == .reReview),
            (.changesRequested, bucket == .fix && decision(pr) == "CHANGES_REQUESTED"),
            (.ciFailed, bucket == .fix && pr.ci == .failure),
            (.conflicts, bucket == .fix && conflicted(pr)),
            (.mentioned, unread.contains { $0.kind == .mentioned }),
            (.assigned, unread.contains { $0.kind == .assigned }),
            (.newComments, mine && unread.contains { talk.contains($0.kind) }),
            (.readyToMerge, bucket == .merge),
            (.teamToReview, bucket == .teamReview),
        ]
        return checks.first { counting.contains($0.0) && $0.1 }?.0
    }

    /// When the item entered `reason`: its newest event of a kind that causes the reason, else `updatedAt`.
    public static func waitingSince(_ pr: TrackedPR, _ reason: NeedReason) -> Date { causedAt(pr, reason) ?? pr.updatedAt }

    /// The newest event of a kind that causes `reason`; nil when none is stored.
    static func causedAt(_ pr: TrackedPR, _ reason: NeedReason) -> Date? {
        let kinds: Set<EventKind> = switch reason {
        case .toReview, .teamToReview: [.reviewRequested, .readyForReview]
        case .reReview: [.reviewRequested, .readyForReview, .newCommits, .reviewDismissed]
        case .changesRequested: [.reviewChangesRequested]
        case .ciFailed: [.ciFailed]
        case .conflicts: [.conflicts]
        case .mentioned: [.mentioned]
        case .assigned: [.assigned]
        case .newComments: [.comment, .reviewApproved, .reviewChangesRequested, .reviewCommented]
        case .readyToMerge: [.reviewApproved, .ciPassed, .readyToMerge]
        }
        return pr.events.filter { kinds.contains($0.kind) }.map(\.at).max()
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

    /// Latest of updated, closed and the newest event.
    public static func lastActivity(_ pr: TrackedPR) -> Date {
        max(pr.updatedAt, pr.closedAt ?? .distantPast, pr.events.map(\.at).max() ?? .distantPast)
    }

    /// The one list order: items that need me first, by reason (`NeedReason` order), oldest waiting first (they are queues);
    /// then the rest, latest activity first. Ties by number, highest first, then id. Unread is no rank of its own.
    /// `counting: []` gives plain latest-activity order (Waiting on Others, Reviewed, Watching, Closed).
    public static func sorted(_ prs: [TrackedPR], counting: Set<NeedReason> = Set(NeedReason.allCases)) -> [TrackedPR] {
        let rank = Dictionary(uniqueKeysWithValues: NeedReason.allCases.enumerated().map { ($1, $0) })
        return prs.map { pr -> (pr: TrackedPR, rank: Int, at: Date) in
            let reason = needReason(pr, counting: counting)
            return (pr, reason.flatMap { rank[$0] } ?? rank.count, reason.map { waitingSince(pr, $0) } ?? lastActivity(pr))
        }
        .sorted { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            if a.at != b.at { return a.rank < rank.count ? a.at < b.at : a.at > b.at }
            return (a.pr.number, a.pr.id) > (b.pr.number, b.pr.id)  // id: a stable order when numbers tie across repos
        }
        .map(\.pr)
    }
}
