import Foundation

extension GitHubClient {
    static let refreshBatch = 20
    static let maxTimelinePages = 10

    /// Full refresh of ≤ 20 PRs or issues (the caller batches); one with more timeline gets follow-up calls alone.
    /// Null nodes are skipped (the next `stamps` call drops them).
    public func refresh(_ ids: [String], since: Date?) async throws -> [PRSnapshot] {
        let since: Any = since?.ISO8601Format() ?? NSNull()
        let data: NodesData<RawPR> = try await run(GraphQL.refresh, ["ids": ids, "since": since])
        var result: [PRSnapshot] = []
        for raw in data.nodes.compactMap({ $0 }) {
            var snapshot = Self.snapshot(raw)
            var pageInfo = raw.timelineItems.pageInfo, pages = 1
            // shortcut: stops after 500 timeline items per PR per poll; raise maxTimelinePages if PRs get busier.
            while pageInfo.hasNextPage, let cursor = pageInfo.endCursor, pages < Self.maxTimelinePages {
                let more: NodesData<RawPR> = try await run(GraphQL.refresh, ["ids": [raw.id], "since": since, "after": cursor])
                guard let next = more.nodes.first ?? nil else { break }
                snapshot.timeline += Self.snapshot(next).timeline
                pageInfo = next.timelineItems.pageInfo
                pages += 1
            }
            result.append(snapshot)
        }
        return result
    }

    static func snapshot(_ raw: RawPR) -> PRSnapshot {
        var s = PRSnapshot(id: raw.id)
        s.repo = raw.repository.nameWithOwner
        s.number = raw.number
        s.title = raw.title
        s.url = raw.url
        s.authorLogin = raw.author?.login ?? "ghost"
        s.body = raw.body
        s.isIssue = raw.__typename == "Issue"
        s.isDraft = raw.isDraft ?? false
        s.state = raw.merged == true ? .merged : PRState(rawValue: (raw.state ?? raw.issueState ?? "").lowercased()) ?? .open
        s.stateReason = raw.stateReason
        s.reviewDecision = raw.reviewDecision
        s.mergeState = raw.mergeStateStatus ?? ""
        s.updatedAt = raw.updatedAt
        s.closedAt = raw.closedAt ?? raw.mergedAt
        s.createdAt = raw.createdAt
        s.headOID = raw.headRefOid ?? ""
        s.headRef = raw.headRefName
        let commit = raw.commits?.items.first?.commit
        s.headAuthorLogin = commit?.author?.user?.login ?? commit?.author?.name
        s.ci = CIState(rollup: commit?.statusCheckRollup?.state)
        s.checks = commit?.statusCheckRollup?.contexts.items.map { c in
            c.__typename == "CheckRun"
                ? CheckSummary(name: c.name ?? "", state: CIState(conclusion: c.conclusion), url: c.detailsUrl.flatMap(URL.init(string:)))
                : CheckSummary(name: c.context ?? "", state: CIState(rollup: c.state), url: c.targetUrl.flatMap(URL.init(string:)))
        } ?? []
        let requested = raw.reviewRequests?.items.compactMap(\.requestedReviewer) ?? []
        let requestedUsers = requested.compactMap(\.login)
        s.requestedTeams = requested.compactMap(\.slug)
        func summary(_ review: RawPR.Review) -> ReviewSummary? {
            review.author.map { ReviewSummary(login: $0.login, state: review.state, submittedAt: review.submittedAt,
                                              requested: requestedUsers.contains($0.login), commitOID: review.commit?.oid) }
        }
        // Deciding reviews first, as GitHub's reviewer list: a later comment-only review must not hide a change request.
        let opinionated = raw.latestOpinionatedReviews?.items ?? []
        s.reviewers = opinionated.compactMap(summary)
        s.reviewers += (raw.latestReviews?.items.compactMap(summary) ?? []).filter { r in !s.reviewers.contains { $0.login == r.login } }
        s.reviewers += requestedUsers.filter { login in !s.reviewers.contains { $0.login == login } }
            .map { ReviewSummary(login: $0, state: "", submittedAt: nil, requested: true) }
        // The viewer's own entry among the deciding reviews, else their latest review (a pending one doesn't count yet).
        if let viewer = raw.viewerLatestReview, let login = viewer.author?.login, login.lowercased() != s.authorLogin.lowercased() {
            let mine = opinionated.first { $0.author?.login == login } ?? (viewer.state == "PENDING" ? nil : viewer)
            s.myReview = mine.map { MyReview(state: $0.state, commitOID: $0.commit?.oid, submittedAt: $0.submittedAt) }
        }
        s.autoMerge = s.isIssue ? nil : raw.isInMergeQueue == true || raw.autoMergeRequest != nil
        s.assignees = raw.assignees.items.map(\.login)
        s.timeline = raw.timelineItems.nodes?.compactMap { $0.flatMap(timelineNode) } ?? []
        return s
    }

    /// Nil for nodes without an id or a date (a pending review has no `submittedAt`).
    static func timelineNode(_ item: RawPR.Item) -> TimelineNode? {
        guard let id = item.id, let at = item.createdAt ?? item.submittedAt else { return nil }
        let comment = item.comments?.nodes?.first ?? nil
        return TimelineNode(id: id, type: item.__typename, at: at, actor: (item.author ?? item.actor)?.login ?? "ghost",
                            body: item.body ?? "", url: item.url.flatMap(URL.init(string:)), reviewState: item.state,
                            commentCount: item.comments?.totalCount ?? 0, commentPath: comment?.path, commentBody: comment?.body,
                            detail: item.afterCommit?.abbreviatedOid ?? item.currentTitle ?? item.label?.name
                                ?? item.stateReason.map { $0.lowercased().replacingOccurrences(of: "_", with: " ") })
    }
}

extension CIState {
    /// `StatusCheckRollup.state` / `StatusContext.state`; nil rollup = no CI.
    init(rollup: String?) {
        switch rollup {
        case nil: self = .none
        case "SUCCESS": self = .success
        case "FAILURE", "ERROR": self = .failure
        default: self = .pending  // PENDING, EXPECTED
        }
    }

    /// `CheckRun.conclusion`; nil while the run is queued or in progress.
    init(conclusion: String?) {
        switch conclusion {
        case "SUCCESS", "NEUTRAL", "SKIPPED": self = .success
        case "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE": self = .failure
        default: self = .pending
        }
    }
}
