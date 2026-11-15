import Foundation

public struct PRStamp: Sendable, Equatable {
    public var id: String
    public var updatedAt: Date
    public var state: PRState
    public var inRequested = false
    public var inReviewed = false
    /// Found by the `involves` issue search (`SearchQueries.issues`).
    public var inIssues = false
    /// Position in the watched search (`IssueWatch.query`, newest first); nil = not found by it.
    public var watchedRank: Int?
}

public struct Discovered: Sendable, Equatable {
    public var login: String
    public var stamps: [String: PRStamp] = [:]
    public var involved = 0, requested = 0, reviewed = 0, issues = 0, watched = 0
    public var pages = 0
}

extension GitHubClient {
    static let maxPages = 5

    /// Open PRs from the three searches, plus open issues when `issues` is on and the `watched` search (`IssueWatch.query`)
    /// with them, up to 5 pages of 100 per search.
    public func discover(issues: Bool = true, watched: String? = nil) async throws -> Discovered {
        let data: DiscoverData = try await run(GraphQL.discover, [
            "involved": SearchQueries.involved, "requested": SearchQueries.requested, "reviewed": SearchQueries.reviewed,
            "issues": SearchQueries.issues, "withIssues": issues, "watched": watched ?? "", "withWatched": issues && watched != nil,
        ])
        var result = Discovered(login: data.viewer.login, involved: data.involved.issueCount ?? 0,
                                requested: data.requested.issueCount ?? 0, reviewed: data.reviewed.issueCount ?? 0,
                                issues: data.issues?.issueCount ?? 0, watched: data.watched?.issueCount ?? 0)
        let searches = [(data.involved, SearchQueries.involved), (data.requested, SearchQueries.requested), (data.reviewed, SearchQueries.reviewed)]
            + (data.issues.map { [($0, SearchQueries.issues)] } ?? []) + (data.watched.map { [($0, watched ?? "")] } ?? [])
        var rank = 0
        for (first, query) in searches {
            var page = first, count = 1
            while true {
                for node in page.items {
                    var stamp = result.stamps[node.id] ?? PRStamp(id: node.id, updatedAt: node.updatedAt, state: .open)
                    stamp.inRequested = stamp.inRequested || query == SearchQueries.requested
                    stamp.inReviewed = stamp.inReviewed || query == SearchQueries.reviewed
                    stamp.inIssues = stamp.inIssues || query == SearchQueries.issues
                    if query == watched && stamp.watchedRank == nil { (stamp.watchedRank, rank) = (rank, rank + 1) }
                    result.stamps[node.id] = stamp
                }
                result.pages += 1
                guard page.pageInfo.hasNextPage, count < Self.maxPages, let cursor = page.pageInfo.endCursor else { break }
                let next: PageData = try await run(GraphQL.page, ["q": query, "after": cursor])
                page = next.search
                count += 1
            }
        }
        return result
    }

    /// Stamps for tracked PRs the searches did not return, ≤ 100 ids per call; `dropped` = null nodes.
    public func stamps(_ ids: [String]) async throws -> (stamps: [PRStamp], dropped: [String]) {
        var stamps: [PRStamp] = [], dropped: [String] = []
        for batch in ids.chunked(100) {
            let data: NodesData<StampNode> = try await run(GraphQL.stamps, ["ids": batch])
            for (id, node) in zip(batch, data.nodes) {
                if let node {
                    stamps.append(PRStamp(id: node.id, updatedAt: node.updatedAt, state: PRState(rawValue: (node.state ?? node.issueState)?.lowercased() ?? "") ?? .open))
                } else {
                    dropped.append(id)
                }
            }
        }
        return (stamps, dropped)
    }
}
