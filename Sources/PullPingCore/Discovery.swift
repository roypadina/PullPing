import Foundation

public struct PRStamp: Sendable, Equatable {
    public var id: String
    public var updatedAt: Date
    public var state: PRState
    public var inRequested = false
    public var inReviewed = false
}

public struct Discovered: Sendable, Equatable {
    public var login: String
    public var stamps: [String: PRStamp] = [:]
    public var involved = 0, requested = 0, reviewed = 0
    public var pages = 0
}

extension GitHubClient {
    static let maxPages = 5

    /// Open PRs from the three searches, up to 5 pages of 100 per search.
    public func discover() async throws -> Discovered {
        let data: DiscoverData = try await run(GraphQL.discover, [
            "involved": SearchQueries.involved, "requested": SearchQueries.requested, "reviewed": SearchQueries.reviewed,
        ])
        var result = Discovered(login: data.viewer.login, involved: data.involved.issueCount ?? 0,
                                requested: data.requested.issueCount ?? 0, reviewed: data.reviewed.issueCount ?? 0)
        for (first, query) in [(data.involved, SearchQueries.involved), (data.requested, SearchQueries.requested), (data.reviewed, SearchQueries.reviewed)] {
            var page = first, count = 1
            while true {
                for node in page.items {
                    var stamp = result.stamps[node.id] ?? PRStamp(id: node.id, updatedAt: node.updatedAt, state: .open)
                    stamp.inRequested = stamp.inRequested || query == SearchQueries.requested
                    stamp.inReviewed = stamp.inReviewed || query == SearchQueries.reviewed
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
                    stamps.append(PRStamp(id: node.id, updatedAt: node.updatedAt, state: PRState(rawValue: node.state?.lowercased() ?? "") ?? .open))
                } else {
                    dropped.append(id)
                }
            }
        }
        return (stamps, dropped)
    }
}
