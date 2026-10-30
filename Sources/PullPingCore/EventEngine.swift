import Foundation

/// Turns a refreshed snapshot into the next tracked state plus the new events. Pure.
public enum EventEngine {
    static let seenCap = 300
    static let eventCap = 50

    public static func diff(old: TrackedPR?, snapshot s: PRSnapshot, me: String, accountID: UUID,
                            inRequestedSearch: Bool, inReviewedSearch: Bool, now: Date) -> (pr: TrackedPR, events: [PREvent]) {
        let isNew = old == nil
        let meLower = me.lowercased()
        func mine(_ login: String?) -> Bool { login?.lowercased() == meLower }
        var pr = old ?? TrackedPR(id: s.id, accountID: accountID, firstTrackedAt: now)
        var seen = Set(pr.seenEventIDs)
        var events: [PREvent] = []

        func add(_ id: String, _ kind: EventKind, _ actor: String, _ at: Date, _ summary: String, _ url: URL?, silent: Bool) {
            guard seen.insert(id).inserted else { return }
            pr.seenEventIDs.append(id)
            events.append(PREvent(id: id, prID: s.id, kind: kind, actor: actor, at: at, summary: String(summary.prefix(120)), url: url, isOwn: silent))
            if kind == .mentioned && !mine(actor) { pr.roles.insert(.mentioned) }
        }

        // Timeline. A new PR's seeded history is silent, except recent mentions of me by others.
        let nodes = s.timeline.sorted { $0.at < $1.at }
        let mergedMinutes = Set((nodes.filter { $0.type == "MergedEvent" }.map(\.at) + pr.events.filter { $0.kind == .merged }.map(\.at)).map(minute))
        let recent = now.addingTimeInterval(-86_400)
        var forcePushed = false
        // A batch shares the oldest watermark, so older nodes come back; `seen` is capped and can't be the only dedupe.
        let floor = old.map { $0.lastSeenAt.addingTimeInterval(-60) } ?? .distantPast
        for node in nodes where !seen.contains(node.id) && node.at >= floor {
            let own = mine(node.actor)
            let mentionsMe = !own && mentions(node.body + "\n" + (node.commentBody ?? ""), meLower)
            let silent = own || (isNew && !(mentionsMe && node.at > recent))
            let simple: [String: EventKind] = ["ReadyForReviewEvent": .readyForReview, "ConvertToDraftEvent": .convertedToDraft, "MergedEvent": .merged,
                                               "ReopenedEvent": .reopened, "ReviewDismissedEvent": .reviewDismissed]
            switch node.type {
            case "IssueComment":
                add(node.id, mentionsMe ? .mentioned : .comment, node.actor, node.at, firstLine(node.body), node.url, silent: silent)
            case "PullRequestReview":
                let kinds: [String: EventKind] = ["APPROVED": .reviewApproved, "CHANGES_REQUESTED": .reviewChangesRequested, "COMMENTED": .reviewCommented]
                guard let kind = kinds[node.reviewState ?? ""] else { continue }  // PENDING, DISMISSED (dismissal has its own event)
                add(node.id, kind, node.actor, node.at, reviewSummary(node), node.url, silent: own || isNew)
                if mentionsMe { add("mention:" + node.id, .mentioned, node.actor, node.at, reviewSummary(node), node.url, silent: silent) }
            case "ClosedEvent":
                if mergedMinutes.contains(minute(node.at)) { seen.insert(node.id); pr.seenEventIDs.append(node.id) }  // merged says it
                else { add(node.id, .closed, node.actor, node.at, node.detail.map { "as \($0)" } ?? "", s.url, silent: silent) }
            case "HeadRefForcePushedEvent":
                forcePushed = true
                add(node.id, .newCommits, node.actor, node.at, "force-pushed \(node.detail ?? "")", s.url, silent: silent)
            case "RenamedTitleEvent":
                add(node.id, .retitled, node.actor, node.at, node.detail ?? "", s.url, silent: silent)
            case "LabeledEvent", "UnlabeledEvent":
                add(node.id, .labeled, node.actor, node.at, (node.type == "LabeledEvent" ? "added " : "removed ") + (node.detail ?? ""), s.url, silent: silent)
            default:
                if let kind = simple[node.type] { add(node.id, kind, node.actor, node.at, "", s.url, silent: silent) }
            }
        }

        // Snapshot diffs. Synthetic ids carry oid/login/date so they dedupe like node ids.
        let stamp = now.ISO8601Format()
        if let old {
            let headChanged = !old.headOID.isEmpty && old.headOID != s.headOID
            if headChanged && !forcePushed {
                let actor = s.headAuthorLogin ?? "someone"
                add("head:\(s.headOID)", .newCommits, actor, now, "pushed \(s.headOID.prefix(7))", s.url, silent: mine(actor))
            }
            // A new head starts over: report only once its CI settles.
            if (s.ci == .success || s.ci == .failure) && (headChanged || s.ci != old.ci) {
                let failed = s.checks.filter { $0.state == .failure }
                add("ci:\(s.headOID):\(s.ci.rawValue)", s.ci == .success ? .ciPassed : .ciFailed, "CI", now,
                    failed.map(\.name).joined(separator: ", "), failed.first?.url ?? s.url, silent: false)
            }
        }
        let wasRequested = old?.reviewers.contains { $0.requested && mine($0.login) } ?? false
        let isRequested = s.reviewers.contains { $0.requested && mine($0.login) }
        if isRequested && !wasRequested {
            add("rr:\(me):\(stamp)", .reviewRequested, s.authorLogin, now, "", s.url, silent: mine(s.authorLogin))
        } else if !isRequested, inRequestedSearch,
                  // A new team, or the first poll the (lagging) search confirms a team already on the PR.
                  let team = s.requestedTeams.first(where: { !(old?.requestedTeams ?? []).contains($0) })
                    ?? (old?.roles.contains(.teamReviewRequested) == false ? s.requestedTeams.first : nil) {
            add("rr:team/\(team):\(stamp)", .reviewRequested, s.authorLogin, now, "via team \(team)", s.url, silent: mine(s.authorLogin))
        }
        if s.assignees.contains(where: mine) && !(old?.assignees ?? []).contains(where: mine) {
            add("assign:\(me):\(stamp)", .assigned, s.authorLogin, now, "", s.url, silent: mine(s.authorLogin))
        }
        if isNew && !mine(s.authorLogin) && mentions(s.body, meLower) {
            add("body:\(s.id)", .mentioned, s.authorLogin, now, firstLine(s.body), s.url, silent: false)
        }

        // Roles: requested/assigned follow the snapshot, the rest only grow.
        pr.roles.subtract([.reviewRequested, .teamReviewRequested, .assigned])
        if mine(s.authorLogin) { pr.roles.insert(.author) }
        if isRequested { pr.roles.insert(.reviewRequested) } else if inRequestedSearch { pr.roles.insert(.teamReviewRequested) }  // teams can be invisible (no read:org)
        if s.assignees.contains(where: mine) { pr.roles.insert(.assigned) }
        if inReviewedSearch || s.reviewers.contains(where: { mine($0.login) && !$0.state.isEmpty }) { pr.roles.insert(.reviewer) }
        if s.timeline.contains(where: { $0.type == "IssueComment" && mine($0.actor) }) { pr.roles.insert(.commenter) }

        pr.accountID = accountID
        pr.isIssue = s.isIssue
        pr.stateReason = s.stateReason
        pr.repo = s.repo
        pr.number = s.number
        pr.title = s.title
        pr.url = s.url
        pr.authorLogin = s.authorLogin
        pr.isDraft = s.isDraft
        pr.state = s.state
        pr.reviewDecision = s.reviewDecision
        pr.mergeState = s.mergeState
        pr.ci = s.ci
        pr.checks = s.checks
        pr.headOID = s.headOID
        pr.reviewers = s.reviewers
        pr.requestedTeams = s.requestedTeams
        pr.assignees = s.assignees
        pr.updatedAt = s.updatedAt
        pr.closedAt = s.closedAt
        pr.lastSeenAt = ([pr.lastSeenAt, s.updatedAt] + nodes.map(\.at)).max()!
        pr.seenEventIDs = Array(pr.seenEventIDs.suffix(seenCap))
        pr.events = Array((pr.events + events).suffix(eventCap))
        return (pr, events)
    }

    /// `@login` as a whole word, case-insensitive (logins are letters, digits and hyphens).
    static func mentions(_ text: String, _ login: String) -> Bool {
        let pattern = "(?<![A-Za-z0-9_-])@" + NSRegularExpression.escapedPattern(for: login) + "(?![A-Za-z0-9_-])"
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// First non-empty line, trimmed, ≤ 120 chars, markdown kept raw.
    static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return String((line ?? "").prefix(120))
    }

    /// Review body; an empty body shows the first inline comment ("path: text (+N more)"), which is how a reply in a thread arrives.
    static func reviewSummary(_ node: TimelineNode) -> String {
        let body = firstLine(node.body)
        guard body.isEmpty, let path = node.commentPath else { return body }
        let more = node.commentCount > 1 ? " (+\(node.commentCount - 1) more)" : ""
        return "\(path): \(firstLine(node.commentBody ?? ""))".prefix(120 - more.count) + more
    }

    static func minute(_ date: Date) -> Int { Int(date.timeIntervalSince1970 / 60) }
}
